# ArducamBridge

Native macOS viewer plus a lightweight Raspberry Pi MJPEG bridge for the Arducam 64MP OV64A40 on a Pi Zero 2 W.

## Working baseline

The Pi camera is working with this verified Bookworm-era configuration:

```ini
[all]
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
```

Verified on:

- Raspberry Pi Zero 2 W
- Raspberry Pi OS Lite 32-bit, kernel `6.12.47+rpt-rpi-v7`
- Arducam 64MP OV64A40

## TODO

1. Keep the Pi camera on the known-good `ov64a40` overlay.
2. Install the Pi-side MJPEG bridge service with the balanced default profile.
3. Confirm the stream works at `http://pi-zero-1.local:7123/stream.mjpg`.
4. Launch the packaged macOS viewer and point it at the Pi stream.
5. Use the in-app stream and focus controls to tune detail, latency, and lens behavior.

## Pi setup

Copy the working overlay into `/boot/firmware/config.txt`, then reboot:

```ini
[all]
camera_auto_detect=0
dtoverlay=ov64a40,link-frequency=360000000
```

Quick verification on the Pi:

```bash
rpicam-still --list-cameras
rpicam-still --nopreview --immediate --width 1280 --height 720 --output /tmp/test.jpg
```

Install the stream service from this repo:

```bash
PI_HOST=192.168.0.137 PI_USER=pi-zero-1 PI_PASS=8191 ./scripts/install-pi-streamer.sh
```

The installer copies the bridge server to the Pi, installs a `systemd` service, and starts it on port `7123`.

Default Pi profile after install:

```text
1280x720 @ 6 fps, MJPEG quality 65
```

Useful Pi endpoints:

- Stream: [http://pi-zero-1.local:7123/stream.mjpg](http://pi-zero-1.local:7123/stream.mjpg)
- Snapshot: [http://pi-zero-1.local:7123/snapshot.jpg](http://pi-zero-1.local:7123/snapshot.jpg)
- Health: [http://pi-zero-1.local:7123/healthz](http://pi-zero-1.local:7123/healthz)
- Settings API: [http://pi-zero-1.local:7123/settings](http://pi-zero-1.local:7123/settings)

## Mac viewer

Build and launch the native viewer:

```bash
swift run ArducamBridgeViewer
```

The app opens a macOS window with:

- Editable MJPEG URL
- Snapshot fallback URL
- Connect/reload and Pi sync controls
- Stream tuning presets: `Low Latency`, `Balanced`, `Detail`
- Autofocus or manual lens-position control
- Snapshot saving to a local `.jpg`
- Live status that switches between stream and fallback mode

Build a clickable `.app` bundle:

```bash
./scripts/build-mac-app.sh
open ./dist/ArducamBridgeViewer.app
```

Default stream URL:

```text
http://pi-zero-1.local:7123/stream.mjpg
```

Default snapshot fallback:

```text
http://pi-zero-1.local:7123/snapshot.jpg
```

## Repo layout

- `pi/bridge_streamer.py`: MJPEG bridge built on `rpicam-vid` and Python's stdlib HTTP server
- `pi/arducam-bridge.service`: `systemd` unit for the Pi
- `scripts/install-pi-streamer.sh`: local installer that pushes the Pi service over SSH
- `scripts/build-mac-app.sh`: release bundler that emits `dist/ArducamBridgeViewer.app`
- `Package.swift`: macOS Swift package
- `Sources/ArducamBridgeViewer/`: native SwiftUI viewer
