#!/usr/bin/env python3

import argparse
import json
import logging
import os
import signal
import subprocess
import threading
import time
from collections import deque
from dataclasses import asdict, dataclass, replace
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

JPEG_SOI = b"\xff\xd8"
JPEG_EOI = b"\xff\xd9"
FOCUS_MODES = {"auto", "continuous", "manual", "default"}
FOCUS_RANGES = {"normal", "macro", "full"}
FOCUS_SPEEDS = {"normal", "fast"}


@dataclass
class StreamConfig:
    width: int = 640
    height: int = 480
    framerate: float = 4.0
    quality: int = 70
    rotation: int = 0
    camera: int = 0
    autofocus_mode: str = "auto"
    autofocus_range: str = "normal"
    autofocus_speed: str = "normal"
    lens_position: float | None = None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Arducam OV64A40 MJPEG bridge")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7123)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--framerate", type=float, default=4.0)
    parser.add_argument("--quality", type=int, default=70)
    parser.add_argument("--rotation", type=int, choices=(0, 180), default=0)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--autofocus-mode", default="auto")
    parser.add_argument("--autofocus-range", default="normal")
    parser.add_argument("--autofocus-speed", default="normal")
    parser.add_argument("--lens-position", type=float)
    parser.add_argument("--verbose", action="store_true")
    return parser


def clamp_int(value: object, name: str, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def clamp_float(value: object, name: str, minimum: float, maximum: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be a number") from exc
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def normalize_choice(value: object, name: str, allowed: set[str]) -> str:
    text = str(value).strip().lower()
    if text not in allowed:
        raise ValueError(f"{name} must be one of: {', '.join(sorted(allowed))}")
    return text


def validate_config(config: StreamConfig) -> StreamConfig:
    width = clamp_int(config.width, "width", 320, 1920)
    height = clamp_int(config.height, "height", 240, 1080)
    framerate = clamp_float(config.framerate, "framerate", 1.0, 30.0)
    quality = clamp_int(config.quality, "quality", 30, 95)
    rotation = clamp_int(config.rotation, "rotation", 0, 180)
    if rotation not in (0, 180):
        raise ValueError("rotation must be 0 or 180")
    camera = clamp_int(config.camera, "camera", 0, 3)
    autofocus_mode = normalize_choice(config.autofocus_mode, "autofocus_mode", FOCUS_MODES)
    autofocus_range = normalize_choice(config.autofocus_range, "autofocus_range", FOCUS_RANGES)
    autofocus_speed = normalize_choice(config.autofocus_speed, "autofocus_speed", FOCUS_SPEEDS)

    lens_position = config.lens_position
    if autofocus_mode == "manual":
        if lens_position is None:
            lens_position = 0.0
        lens_position = clamp_float(lens_position, "lens_position", 0.0, 10.0)
    else:
        lens_position = None

    return StreamConfig(
        width=width,
        height=height,
        framerate=framerate,
        quality=quality,
        rotation=rotation,
        camera=camera,
        autofocus_mode=autofocus_mode,
        autofocus_range=autofocus_range,
        autofocus_speed=autofocus_speed,
        lens_position=lens_position,
    )


class FramePump:
    def __init__(self, config: StreamConfig, port: int) -> None:
        self.port = port
        self.condition = threading.Condition()
        self.config_lock = threading.Lock()
        self.process_lock = threading.Lock()
        self.process: subprocess.Popen[bytes] | None = None
        self.config = validate_config(config)
        self.restart_requested = False
        self.latest_frame: bytes | None = None
        self.latest_frame_at = 0.0
        self.frame_counter = 0
        self.error: str | None = None
        self.stderr_tail: deque[str] = deque(maxlen=30)
        self.running = True
        self.thread = threading.Thread(target=self._run, name="frame-pump", daemon=True)

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.running = False
        self._terminate_current_process()
        with self.condition:
            self.condition.notify_all()

    def snapshot_state(self) -> dict[str, object]:
        age = None
        if self.latest_frame_at:
            age = round(time.time() - self.latest_frame_at, 3)
        return {
            "running": self.running,
            "frame_counter": self.frame_counter,
            "last_frame_age_s": age,
            "error": self.error,
            "stderr_tail": list(self.stderr_tail),
            "stream_url": f"http://{self._lan_hint()}:{self.port}/stream.mjpg",
            "snapshot_url": f"http://{self._lan_hint()}:{self.port}/snapshot.jpg",
            "settings_url": f"http://{self._lan_hint()}:{self.port}/settings",
            "settings": self.current_config(),
        }

    def current_config(self) -> dict[str, object]:
        with self.config_lock:
            return asdict(self.config)

    def update_config(self, payload: dict[str, object]) -> dict[str, object]:
        with self.config_lock:
            next_config = replace(self.config)
            for key, value in payload.items():
                if not hasattr(next_config, key):
                    raise ValueError(f"unknown setting: {key}")
                setattr(next_config, key, value)
            validated = validate_config(next_config)
            changed = validated != self.config
            self.config = validated

        if changed:
            self.error = None
            self.restart_requested = True
            self._terminate_current_process()

        return self.current_config()

    def wait_for_frame(self, since_frame: int | None = None, timeout: float = 5.0) -> tuple[int, bytes | None]:
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.running:
                if self.latest_frame and (since_frame is None or self.frame_counter > since_frame):
                    return self.frame_counter, self.latest_frame
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return self.frame_counter, self.latest_frame
                self.condition.wait(remaining)
        return self.frame_counter, self.latest_frame

    def _lan_hint(self) -> str:
        return os.environ.get("ARDUCAM_BRIDGE_HOST_HINT", "pi-zero-1.local")

    def _camera_command(self) -> list[str]:
        with self.config_lock:
            config = replace(self.config)

        command = [
            "rpicam-vid",
            "--camera",
            str(config.camera),
            "--codec",
            "mjpeg",
            "--nopreview",
            "--width",
            str(config.width),
            "--height",
            str(config.height),
            "--framerate",
            str(config.framerate),
            "--quality",
            str(config.quality),
            "--autofocus-mode",
            config.autofocus_mode,
            "--autofocus-range",
            config.autofocus_range,
            "--autofocus-speed",
            config.autofocus_speed,
            "--timeout",
            "0",
            "--output",
            "-",
        ]
        if config.rotation:
            command.extend(["--rotation", str(config.rotation)])
        if config.autofocus_mode == "manual" and config.lens_position is not None:
            command.extend(["--lens-position", str(config.lens_position)])
        return command

    def _run(self) -> None:
        while self.running:
            self._read_from_camera()
            if self.running:
                time.sleep(0.5)

    def _read_from_camera(self) -> None:
        command = self._camera_command()
        logging.info("Starting camera process: %s", " ".join(command))
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        with self.process_lock:
            self.process = process
        stderr_thread = threading.Thread(target=self._drain_stderr, args=(process,), daemon=True)
        stderr_thread.start()

        buffer = bytearray()
        self.error = None
        try:
            while self.running:
                chunk = process.stdout.read(65536) if process.stdout else b""
                if not chunk:
                    break
                buffer.extend(chunk)
                self._extract_frames(buffer)
        except Exception as exc:
            self.error = f"camera read failed: {exc}"
            logging.exception("Camera read failed")
        finally:
            self._terminate_process(process)
            with self.process_lock:
                if self.process is process:
                    self.process = None
            stderr_thread.join(timeout=1.0)

        if self.restart_requested:
            self.restart_requested = False
            return
        if self.running and not self.error:
            self.error = f"camera process exited with code {process.returncode}"
            logging.warning(self.error)

    def _extract_frames(self, buffer: bytearray) -> None:
        while True:
            start = buffer.find(JPEG_SOI)
            if start < 0:
                if len(buffer) > 2 * 1024 * 1024:
                    del buffer[:-2]
                return
            if start > 0:
                del buffer[:start]

            end = buffer.find(JPEG_EOI, 2)
            if end < 0:
                if len(buffer) > 8 * 1024 * 1024:
                    del buffer[:start]
                return

            frame = bytes(buffer[: end + 2])
            del buffer[: end + 2]
            with self.condition:
                self.latest_frame = frame
                self.latest_frame_at = time.time()
                self.frame_counter += 1
                self.condition.notify_all()

    def _drain_stderr(self, process: subprocess.Popen[bytes]) -> None:
        if not process.stderr:
            return
        for raw_line in iter(process.stderr.readline, b""):
            if not raw_line:
                break
            line = raw_line.decode("utf-8", errors="replace").rstrip()
            self.stderr_tail.append(line)
            logging.info("rpicam-vid: %s", line)

    def _terminate_current_process(self) -> None:
        with self.process_lock:
            if self.process and self.process.poll() is None:
                self._terminate_process(self.process)

    @staticmethod
    def _terminate_process(process: subprocess.Popen[bytes]) -> None:
        if process.poll() is not None:
            return
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def make_handler(pump: FramePump):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ArducamBridge/0.2"

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path in ("/", "/index.html"):
                self._serve_index()
                return
            if parsed.path == "/healthz":
                self._serve_json(pump.snapshot_state())
                return
            if parsed.path == "/settings":
                self._serve_json({"settings": pump.current_config()})
                return
            if parsed.path == "/snapshot.jpg":
                self._serve_snapshot()
                return
            if parsed.path == "/stream.mjpg":
                self._serve_stream()
                return
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")

        def do_POST(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path != "/settings":
                self.send_error(HTTPStatus.NOT_FOUND, "Not Found")
                return

            try:
                payload = self._read_json()
                settings = pump.update_config(payload)
            except ValueError as exc:
                self._serve_json({"error": str(exc)}, status=HTTPStatus.BAD_REQUEST)
                return

            self._serve_json({"settings": settings, "restarting": True})

        def log_message(self, fmt: str, *args) -> None:
            logging.info("%s - %s", self.address_string(), fmt % args)

        def _serve_index(self) -> None:
            state = pump.snapshot_state()
            settings = state["settings"]
            html = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Arducam Bridge</title>
  <style>
    body {{ font-family: sans-serif; background: #111827; color: #f9fafb; margin: 0; padding: 2rem; }}
    main {{ max-width: 72rem; margin: 0 auto; }}
    .card {{ background: rgba(255,255,255,0.06); border: 1px solid rgba(255,255,255,0.12); border-radius: 16px; padding: 1rem; }}
    img {{ width: min(100%, 960px); display: block; border-radius: 12px; background: #000; }}
    code {{ color: #93c5fd; }}
  </style>
</head>
<body>
  <main>
    <h1>Arducam Bridge</h1>
    <p>Stream: <code>/stream.mjpg</code> Snapshot: <code>/snapshot.jpg</code> Settings: <code>/settings</code></p>
    <div class="card">
      <p>Frame counter: {state["frame_counter"]}</p>
      <p>Last frame age: {state["last_frame_age_s"]}</p>
      <p>Error: {state["error"] or "none"}</p>
      <p>Mode: {settings["width"]}x{settings["height"]} at {settings["framerate"]} fps, quality {settings["quality"]}, focus {settings["autofocus_mode"]}</p>
      <img src="/stream.mjpg" alt="Arducam stream">
    </div>
  </main>
</body>
</html>"""
            payload = html.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _serve_json(self, payload: dict[str, object], status: HTTPStatus = HTTPStatus.OK) -> None:
            body = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _serve_snapshot(self) -> None:
            _, frame = pump.wait_for_frame(timeout=8.0)
            if not frame:
                self.send_error(HTTPStatus.SERVICE_UNAVAILABLE, "No frame available")
                return
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Cache-Control", "no-store, max-age=0")
            self.send_header("Content-Length", str(len(frame)))
            self.end_headers()
            self.wfile.write(frame)

        def _serve_stream(self) -> None:
            boundary = "frame"
            self.send_response(HTTPStatus.OK)
            self.send_header("Age", "0")
            self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
            self.send_header("Pragma", "no-cache")
            self.send_header("Content-Type", f"multipart/x-mixed-replace; boundary={boundary}")
            self.end_headers()

            frame_id = None
            try:
                while True:
                    frame_id, frame = pump.wait_for_frame(frame_id, timeout=15.0)
                    if not frame:
                        continue
                    self.wfile.write(f"--{boundary}\r\n".encode("ascii"))
                    self.wfile.write(b"Content-Type: image/jpeg\r\n")
                    self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode("ascii"))
                    self.wfile.write(frame)
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                logging.info("Stream client disconnected")

        def _read_json(self) -> dict[str, object]:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0:
                raise ValueError("request body is required")
            raw_body = self.rfile.read(content_length)
            try:
                payload = json.loads(raw_body.decode("utf-8"))
            except json.JSONDecodeError as exc:
                raise ValueError("request body must be valid JSON") from exc
            if not isinstance(payload, dict):
                raise ValueError("request body must be a JSON object")
            return payload

    return Handler


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    config = StreamConfig(
        width=args.width,
        height=args.height,
        framerate=args.framerate,
        quality=args.quality,
        rotation=args.rotation,
        camera=args.camera,
        autofocus_mode=args.autofocus_mode,
        autofocus_range=args.autofocus_range,
        autofocus_speed=args.autofocus_speed,
        lens_position=args.lens_position,
    )
    pump = FramePump(config, port=args.port)
    pump.start()

    server = ThreadingHTTPServer((args.host, args.port), make_handler(pump))
    server.daemon_threads = True
    shutdown_started = False
    shutdown_lock = threading.Lock()

    def shutdown(_signum: int, _frame) -> None:
        nonlocal shutdown_started
        with shutdown_lock:
            if shutdown_started:
                return
            shutdown_started = True
        logging.info("Shutting down")
        pump.stop()
        threading.Thread(target=server.shutdown, name="http-shutdown", daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    logging.info("Serving on http://%s:%s", args.host, args.port)
    try:
        server.serve_forever()
    finally:
        pump.stop()
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
