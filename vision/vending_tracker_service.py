#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import logging
import signal
import threading
import time
from collections import Counter, deque
from dataclasses import dataclass, field
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import cv2
import numpy as np
import supervision as sv
import yaml
from ultralytics import RTDETR, YOLO


@dataclass
class ZoneConfig:
    name: str
    polygon: list[list[float]]


@dataclass
class ModelConfig:
    backend: str
    weights: str
    imgsz: int
    confidence: float
    classes_of_interest: list[str]


@dataclass
class TrackingConfig:
    track_activation_threshold: float
    lost_track_buffer: int
    minimum_matching_threshold: float
    minimum_consecutive_frames: int


@dataclass
class InventoryConfig:
    stabilization_frames: int
    transition_confirmation_frames: int
    stale_track_frames: int
    zones: list[ZoneConfig]


@dataclass
class ServerConfig:
    host: str
    port: int
    jpeg_quality: int
    recent_event_limit: int


@dataclass
class ServiceConfig:
    stream_url: str
    snapshot_url: str
    model: ModelConfig
    tracking: TrackingConfig
    inventory: InventoryConfig
    server: ServerConfig


@dataclass
class ZoneState:
    stable: str | None = None
    pending: str | None = None
    pending_since_frame: int = 0


@dataclass
class TrackRecord:
    track_id: int
    class_id: int
    class_name: str
    first_seen_frame: int
    last_seen_frame: int
    last_confidence: float = 0.0
    last_center: tuple[float, float] = (0.0, 0.0)
    zone_states: dict[str, ZoneState] = field(default_factory=dict)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vending detector and tracker service")
    parser.add_argument("--config", required=True, help="Path to YAML config")
    parser.add_argument("--validate-config", action="store_true", help="Validate config and exit")
    parser.add_argument("--max-frames", type=int, default=0, help="Stop after processing this many frames")
    return parser.parse_args()


def clamp_int(value: Any, name: str, minimum: int, maximum: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def clamp_float(value: Any, name: str, minimum: float, maximum: float) -> float:
    try:
        number = float(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{name} must be numeric") from exc
    if number < minimum or number > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return number


def load_config(path: Path) -> ServiceConfig:
    data = yaml.safe_load(path.read_text()) or {}

    source = data.get("source", {})
    model = data.get("model", {})
    tracking = data.get("tracking", {})
    inventory = data.get("inventory", {})
    server = data.get("server", {})

    zones = []
    for raw_zone in inventory.get("zones", []):
        name = str(raw_zone["name"]).strip()
        polygon = raw_zone["polygon"]
        if len(polygon) < 3:
            raise ValueError(f"zone {name!r} must have at least three points")
        for point in polygon:
            if len(point) != 2:
                raise ValueError(f"zone {name!r} contains an invalid point")
        zones.append(ZoneConfig(name=name, polygon=polygon))

    if not zones:
        raise ValueError("at least one inventory zone is required")

    backend = str(model.get("backend", "yolo")).strip().lower()
    if backend not in {"yolo", "rtdetr"}:
        raise ValueError("model.backend must be 'yolo' or 'rtdetr'")

    config = ServiceConfig(
        stream_url=str(source.get("stream_url", "")).strip(),
        snapshot_url=str(source.get("snapshot_url", "")).strip(),
        model=ModelConfig(
            backend=backend,
            weights=str(model.get("weights", "yolo26n.pt")).strip(),
            imgsz=clamp_int(model.get("imgsz", 960), "model.imgsz", 320, 2048),
            confidence=clamp_float(model.get("confidence", 0.35), "model.confidence", 0.01, 0.99),
            classes_of_interest=[str(item) for item in model.get("classes_of_interest", [])],
        ),
        tracking=TrackingConfig(
            track_activation_threshold=clamp_float(
                tracking.get("track_activation_threshold", 0.25),
                "tracking.track_activation_threshold",
                0.01,
                0.99,
            ),
            lost_track_buffer=clamp_int(
                tracking.get("lost_track_buffer", 24),
                "tracking.lost_track_buffer",
                1,
                300,
            ),
            minimum_matching_threshold=clamp_float(
                tracking.get("minimum_matching_threshold", 0.8),
                "tracking.minimum_matching_threshold",
                0.01,
                0.99,
            ),
            minimum_consecutive_frames=clamp_int(
                tracking.get("minimum_consecutive_frames", 2),
                "tracking.minimum_consecutive_frames",
                1,
                30,
            ),
        ),
        inventory=InventoryConfig(
            stabilization_frames=clamp_int(
                inventory.get("stabilization_frames", 4),
                "inventory.stabilization_frames",
                1,
                60,
            ),
            transition_confirmation_frames=clamp_int(
                inventory.get("transition_confirmation_frames", 4),
                "inventory.transition_confirmation_frames",
                1,
                120,
            ),
            stale_track_frames=clamp_int(
                inventory.get("stale_track_frames", 48),
                "inventory.stale_track_frames",
                1,
                600,
            ),
            zones=zones,
        ),
        server=ServerConfig(
            host=str(server.get("host", "127.0.0.1")).strip(),
            port=clamp_int(server.get("port", 9134), "server.port", 1024, 65535),
            jpeg_quality=clamp_int(server.get("jpeg_quality", 80), "server.jpeg_quality", 30, 95),
            recent_event_limit=clamp_int(server.get("recent_event_limit", 200), "server.recent_event_limit", 10, 5000),
        ),
    )

    if not config.stream_url:
        raise ValueError("source.stream_url is required")
    if not config.snapshot_url:
        raise ValueError("source.snapshot_url is required")

    return config


class VendingTrackingService:
    def __init__(self, config: ServiceConfig, max_frames: int = 0) -> None:
        self.config = config
        self.max_frames = max_frames
        self.running = True
        self.frame_lock = threading.Condition()
        self.latest_jpeg: bytes | None = None
        self.latest_event_image: np.ndarray | None = None
        self.latest_health: dict[str, Any] = {}
        self.latest_tracks: list[dict[str, Any]] = []
        self.recent_events: deque[dict[str, Any]] = deque(maxlen=config.server.recent_event_limit)
        self.inventory_delta: Counter[str] = Counter()
        self.tracks: dict[int, TrackRecord] = {}
        self.frame_index = 0
        self.processed_frames = 0
        self.process_started_at = time.monotonic()
        self.loop_thread = threading.Thread(target=self._run, name="vending-tracker", daemon=True)
        self.capture: cv2.VideoCapture | None = None
        self.model = self._load_model()
        self.tracker = sv.ByteTrack(
            track_activation_threshold=config.tracking.track_activation_threshold,
            lost_track_buffer=config.tracking.lost_track_buffer,
            minimum_matching_threshold=config.tracking.minimum_matching_threshold,
            frame_rate=max(1, int(round(self._configured_frame_rate()))),
            minimum_consecutive_frames=config.tracking.minimum_consecutive_frames,
        )

    def start(self) -> None:
        self.loop_thread.start()

    def stop(self) -> None:
        self.running = False
        if self.capture is not None:
            self.capture.release()
        with self.frame_lock:
            self.frame_lock.notify_all()

    def wait_for_frame(self, previous_index: int | None = None, timeout: float = 5.0) -> tuple[int, bytes | None]:
        deadline = time.monotonic() + timeout
        with self.frame_lock:
            while self.running:
                if self.latest_jpeg and (previous_index is None or self.frame_index > previous_index):
                    return self.frame_index, self.latest_jpeg
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return self.frame_index, self.latest_jpeg
                self.frame_lock.wait(remaining)
        return self.frame_index, self.latest_jpeg

    def health(self) -> dict[str, Any]:
        return {
            "running": self.running,
            "source_stream_url": self.config.stream_url,
            "annotated_stream_url": f"http://{self.config.server.host}:{self.config.server.port}/annotated.mjpg",
            "snapshot_url": f"http://{self.config.server.host}:{self.config.server.port}/snapshot.jpg",
            "events_url": f"http://{self.config.server.host}:{self.config.server.port}/events",
            "processed_frames": self.processed_frames,
            "current_frame_index": self.frame_index,
            "processing_fps": round(self._processing_fps(), 2),
            "inventory_delta": dict(self.inventory_delta),
            "tracks": self.latest_tracks,
            "recent_events": list(self.recent_events),
            "model": {
                "backend": self.config.model.backend,
                "weights": self.config.model.weights,
                "imgsz": self.config.model.imgsz,
                "confidence": self.config.model.confidence,
            },
            "latest": self.latest_health,
        }

    def _configured_frame_rate(self) -> float:
        if self.latest_health.get("frame_rate"):
            return float(self.latest_health["frame_rate"])
        return 6.0

    def _processing_fps(self) -> float:
        elapsed = max(0.001, time.monotonic() - self.process_started_at)
        return self.processed_frames / elapsed

    def _load_model(self):
        weights = self.config.model.weights
        if self.config.model.backend == "yolo":
            return YOLO(weights)
        return RTDETR(weights)

    def _open_capture(self) -> cv2.VideoCapture:
        capture = cv2.VideoCapture(self.config.stream_url)
        capture.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        return capture

    def _run(self) -> None:
        while self.running:
            try:
                self.capture = self._open_capture()
                if not self.capture.isOpened():
                    raise RuntimeError(f"unable to open stream {self.config.stream_url}")

                while self.running:
                    ok, frame = self.capture.read()
                    if not ok or frame is None:
                        raise RuntimeError("failed to read frame from stream")

                    self.frame_index += 1
                    self._process_frame(frame)

                    if self.max_frames and self.processed_frames >= self.max_frames:
                        self.running = False
                        break
            except Exception as exc:  # pragma: no cover - runtime recovery path
                logging.exception("tracker loop error: %s", exc)
                self.latest_health = {
                    "status": "error",
                    "message": str(exc),
                }
                time.sleep(1.0)
            finally:
                if self.capture is not None:
                    self.capture.release()
                    self.capture = None

    def _process_frame(self, frame: np.ndarray) -> None:
        results = self.model.predict(
            frame,
            imgsz=self.config.model.imgsz,
            conf=self.config.model.confidence,
            verbose=False,
        )[0]
        detections = sv.Detections.from_ultralytics(results)

        if self.config.model.classes_of_interest and len(detections) > 0:
            allowed = set(self.config.model.classes_of_interest)
            names = results.names
            mask = np.array(
                [self._class_name(int(class_id), names) in allowed for class_id in detections.class_id],
                dtype=bool,
            )
            detections = detections[mask]

        tracked = self.tracker.update_with_detections(detections)
        zone_polygons = self._scaled_polygons(frame)
        self._update_tracks(tracked, results.names, zone_polygons)
        annotated = self._annotate_frame(frame, tracked, results.names, zone_polygons)
        encoded, buffer = cv2.imencode(
            ".jpg",
            annotated,
            [int(cv2.IMWRITE_JPEG_QUALITY), self.config.server.jpeg_quality],
        )
        if not encoded:
            raise RuntimeError("failed to encode annotated frame")

        self.processed_frames += 1
        self.latest_tracks = self._serialize_tracks()
        self.latest_health = {
            "status": "ok",
            "frame_rate": self._configured_frame_rate(),
            "zone_count": len(self.config.inventory.zones),
        }

        with self.frame_lock:
            self.latest_event_image = annotated
            self.latest_jpeg = buffer.tobytes()
            self.frame_lock.notify_all()

    def _scaled_polygons(self, frame: np.ndarray) -> dict[str, np.ndarray]:
        height, width = frame.shape[:2]
        polygons: dict[str, np.ndarray] = {}
        for zone in self.config.inventory.zones:
            points = np.array(
                [[int(point[0] * width), int(point[1] * height)] for point in zone.polygon],
                dtype=np.int32,
            )
            polygons[zone.name] = points
        return polygons

    def _update_tracks(self, tracked: sv.Detections, names: Any, zone_polygons: dict[str, np.ndarray]) -> None:
        active_ids: set[int] = set()
        tracker_ids = tracked.tracker_id if tracked.tracker_id is not None else []

        for index in range(len(tracked)):
            if tracked.tracker_id is None or tracker_ids[index] is None:
                continue
            track_id = int(tracker_ids[index])
            active_ids.add(track_id)

            class_id = int(tracked.class_id[index]) if tracked.class_id is not None else -1
            class_name = self._class_name(class_id, names)
            confidence = float(tracked.confidence[index]) if tracked.confidence is not None else 0.0
            xyxy = tracked.xyxy[index]
            center = (float((xyxy[0] + xyxy[2]) / 2.0), float((xyxy[1] + xyxy[3]) / 2.0))

            record = self.tracks.get(track_id)
            if record is None:
                record = TrackRecord(
                    track_id=track_id,
                    class_id=class_id,
                    class_name=class_name,
                    first_seen_frame=self.frame_index,
                    last_seen_frame=self.frame_index,
                )
                self.tracks[track_id] = record

            record.class_id = class_id
            record.class_name = class_name
            record.last_seen_frame = self.frame_index
            record.last_confidence = confidence
            record.last_center = center

            for zone in self.config.inventory.zones:
                polygon = zone_polygons[zone.name]
                inside = cv2.pointPolygonTest(polygon.astype(np.float32), center, False) >= 0
                self._advance_zone_state(record, zone.name, inside)

        stale_after = self.config.inventory.stale_track_frames
        stale_ids = [
            track_id
            for track_id, record in self.tracks.items()
            if track_id not in active_ids and self.frame_index - record.last_seen_frame > stale_after
        ]
        for track_id in stale_ids:
            del self.tracks[track_id]

    def _advance_zone_state(self, record: TrackRecord, zone_name: str, inside: bool) -> None:
        zone_state = record.zone_states.setdefault(zone_name, ZoneState())
        current_state = "inside" if inside else "outside"
        stabilize_after = self.config.inventory.stabilization_frames
        confirm_after = self.config.inventory.transition_confirmation_frames

        if zone_state.stable is None:
            if zone_state.pending != current_state:
                zone_state.pending = current_state
                zone_state.pending_since_frame = self.frame_index
                return
            if self.frame_index - zone_state.pending_since_frame + 1 >= stabilize_after:
                zone_state.stable = current_state
                zone_state.pending = None
            return

        if current_state == zone_state.stable:
            zone_state.pending = None
            return

        if zone_state.pending != current_state:
            zone_state.pending = current_state
            zone_state.pending_since_frame = self.frame_index
            return

        if self.frame_index - zone_state.pending_since_frame + 1 < confirm_after:
            return

        previous_state = zone_state.stable
        zone_state.stable = current_state
        zone_state.pending = None

        if previous_state == "inside" and current_state == "outside":
            self._emit_event(record, zone_name, "removed_candidate", -1)
        elif previous_state == "outside" and current_state == "inside":
            self._emit_event(record, zone_name, "returned_candidate", 1)

    def _emit_event(self, record: TrackRecord, zone_name: str, event_type: str, inventory_delta: int) -> None:
        event = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "frame_index": self.frame_index,
            "event_type": event_type,
            "zone": zone_name,
            "track_id": record.track_id,
            "class_id": record.class_id,
            "class_name": record.class_name,
            "confidence": round(record.last_confidence, 4),
            "center": [round(record.last_center[0], 2), round(record.last_center[1], 2)],
            "inventory_delta": inventory_delta,
        }
        self.recent_events.appendleft(event)
        summary_key = f"{zone_name}:{record.class_name}"
        self.inventory_delta[summary_key] += inventory_delta
        logging.info("event=%s", json.dumps(event))

    def _annotate_frame(
        self,
        frame: np.ndarray,
        tracked: sv.Detections,
        names: Any,
        zone_polygons: dict[str, np.ndarray],
    ) -> np.ndarray:
        annotated = frame.copy()

        for zone_name, polygon in zone_polygons.items():
            cv2.polylines(annotated, [polygon], isClosed=True, color=(0, 196, 255), thickness=2)
            anchor = tuple(polygon[0].tolist())
            cv2.putText(
                annotated,
                zone_name,
                (anchor[0] + 6, anchor[1] - 8),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.7,
                (0, 196, 255),
                2,
                cv2.LINE_AA,
            )

        tracker_ids = tracked.tracker_id if tracked.tracker_id is not None else []
        for index in range(len(tracked)):
            xyxy = tracked.xyxy[index].astype(int)
            class_id = int(tracked.class_id[index]) if tracked.class_id is not None else -1
            class_name = self._class_name(class_id, names)
            confidence = float(tracked.confidence[index]) if tracked.confidence is not None else 0.0
            track_id = int(tracker_ids[index]) if tracked.tracker_id is not None and tracker_ids[index] is not None else -1

            color = (80, 220, 120)
            cv2.rectangle(annotated, (xyxy[0], xyxy[1]), (xyxy[2], xyxy[3]), color, 2)
            label = f"{class_name} #{track_id} {confidence:.2f}"
            cv2.putText(
                annotated,
                label,
                (xyxy[0], max(20, xyxy[1] - 10)),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.55,
                color,
                2,
                cv2.LINE_AA,
            )

        overlay_lines = [
            f"{self.config.model.backend}:{self.config.model.weights}",
            f"fps {self._processing_fps():.1f}",
            f"tracks {len(self.tracks)}",
            f"events {len(self.recent_events)}",
        ]
        y = 28
        for line in overlay_lines:
            cv2.putText(
                annotated,
                line,
                (14, y),
                cv2.FONT_HERSHEY_SIMPLEX,
                0.65,
                (255, 255, 255),
                2,
                cv2.LINE_AA,
            )
            y += 26

        return annotated

    def _serialize_tracks(self) -> list[dict[str, Any]]:
        items = []
        for record in sorted(self.tracks.values(), key=lambda item: item.track_id):
            items.append(
                {
                    "track_id": record.track_id,
                    "class_id": record.class_id,
                    "class_name": record.class_name,
                    "last_seen_frame": record.last_seen_frame,
                    "confidence": round(record.last_confidence, 4),
                    "center": [round(record.last_center[0], 2), round(record.last_center[1], 2)],
                    "zones": {
                        zone_name: {
                            "stable": zone_state.stable,
                            "pending": zone_state.pending,
                        }
                        for zone_name, zone_state in record.zone_states.items()
                    },
                }
            )
        return items

    @staticmethod
    def _class_name(class_id: int, names: Any) -> str:
        if class_id < 0:
            return "unknown"
        if isinstance(names, dict):
            return str(names.get(class_id, class_id))
        if isinstance(names, list) and class_id < len(names):
            return str(names[class_id])
        return str(class_id)


def make_handler(service: VendingTrackingService):
    class Handler(BaseHTTPRequestHandler):
        server_version = "ArducamBridgeVision/0.1"

        def do_GET(self) -> None:
            parsed = urlparse(self.path)
            if parsed.path in {"/", "/index.html"}:
                self._serve_index()
                return
            if parsed.path == "/healthz":
                self._serve_json(service.health())
                return
            if parsed.path == "/events":
                self._serve_json(
                    {
                        "inventory_delta": dict(service.inventory_delta),
                        "recent_events": list(service.recent_events),
                    }
                )
                return
            if parsed.path == "/snapshot.jpg":
                self._serve_snapshot()
                return
            if parsed.path == "/annotated.mjpg":
                self._serve_stream()
                return
            self.send_error(HTTPStatus.NOT_FOUND, "Not Found")

        def log_message(self, fmt: str, *args) -> None:
            logging.info("%s - %s", self.address_string(), fmt % args)

        def _serve_index(self) -> None:
            health = service.health()
            payload = f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ArducamBridge Vision</title>
  <style>
    body {{ margin: 0; font-family: sans-serif; background: #09111b; color: #f8fafc; padding: 2rem; }}
    main {{ max-width: 1200px; margin: 0 auto; }}
    img {{ width: 100%; border-radius: 16px; border: 1px solid rgba(255,255,255,0.12); }}
    pre {{ background: rgba(255,255,255,0.06); padding: 1rem; border-radius: 16px; overflow: auto; }}
  </style>
</head>
<body>
  <main>
    <h1>ArducamBridge Vision</h1>
    <p>Annotated stream: <code>/annotated.mjpg</code> Events: <code>/events</code></p>
    <img src="/annotated.mjpg" alt="annotated stream">
    <pre>{json.dumps(health, indent=2)}</pre>
  </main>
</body>
</html>""".encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _serve_json(self, payload: dict[str, Any]) -> None:
            body = json.dumps(payload, indent=2).encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _serve_snapshot(self) -> None:
            _, frame = service.wait_for_frame(timeout=8.0)
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

            frame_index = None
            try:
                while True:
                    frame_index, frame = service.wait_for_frame(frame_index, timeout=15.0)
                    if not frame:
                        continue
                    self.wfile.write(f"--{boundary}\r\n".encode("ascii"))
                    self.wfile.write(b"Content-Type: image/jpeg\r\n")
                    self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode("ascii"))
                    self.wfile.write(frame)
                    self.wfile.write(b"\r\n")
            except (BrokenPipeError, ConnectionResetError):
                logging.info("annotated stream client disconnected")

    return Handler


def main() -> int:
    args = parse_args()
    config = load_config(Path(args.config))

    if args.validate_config:
        print(json.dumps(
            {
                "stream_url": config.stream_url,
                "snapshot_url": config.snapshot_url,
                "model_backend": config.model.backend,
                "model_weights": config.model.weights,
                "zones": [zone.name for zone in config.inventory.zones],
                "server_port": config.server.port,
            },
            indent=2,
        ))
        return 0

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )

    service = VendingTrackingService(config, max_frames=args.max_frames)
    service.start()

    server = ThreadingHTTPServer((config.server.host, config.server.port), make_handler(service))
    server.daemon_threads = True
    shutdown_started = False
    shutdown_lock = threading.Lock()

    def shutdown(_signum: int, _frame) -> None:
        nonlocal shutdown_started
        with shutdown_lock:
            if shutdown_started:
                return
            shutdown_started = True
        logging.info("shutting down vision service")
        service.stop()
        threading.Thread(target=server.shutdown, name="vision-http-shutdown", daemon=True).start()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    def monitor_completion() -> None:
        service.loop_thread.join()
        shutdown(None, None)

    threading.Thread(target=monitor_completion, name="vision-monitor", daemon=True).start()

    logging.info("vision service listening on http://%s:%s", config.server.host, config.server.port)
    try:
        server.serve_forever()
    finally:
        service.stop()
        server.server_close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
