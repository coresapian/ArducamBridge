# ArducamBridge

Native macOS viewer plus a lightweight Raspberry Pi MJPEG bridge for the Arducam 64MP OV64A40 on a Pi Zero 2 W.

![Arducam Bridge viewer](assets/arducam-bridge-viewer.png)

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
4. Launch the packaged macOS viewer.
5. Use `Raw Pi`, `Detection`, and `Capture` modes inside the app.
6. Save labeled product samples into the built-in YOLO dataset layout.
7. Train a product detector from the app, then restart detection with the new weights.

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
- `Raw Pi`, `Detection`, and `Capture` preview modes
- Local detector controls: backend, weights, confidence, classes of interest, start/stop, log tail, and health summary
- Product capture tools: freeze frame, draw boxes, save YOLO labels, and track dataset counts
- Local training controls: backend, base weights, epochs, image size, batch size, run name, log tail, and reuse-latest-model shortcut
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

### In-app workflow

1. Leave the Pi URLs pointed at the raw bridge stream.
2. In `Detection`, start the local detector. The app writes `configs/vending.generated.yaml` and launches the Mac-side service.
3. Switch to `Capture`, freeze a product frame, draw one or more boxes, and save the sample.
4. The app writes images into `datasets/vending/images/{train,val}` and YOLO labels into `datasets/vending/labels/{train,val}`.
5. Start training from the `Training` card.
6. When training completes, use `Use Latest Model` and restart the detector.

## Detection and tracking

Run detection on the Mac, not on the Pi Zero 2 W. The Pi only streams frames. Inference and tracking run locally against the MJPEG feed.

Default stack in this repo:

- Detector: Ultralytics `yolo26n.pt`
- Tracker: `supervision.ByteTrack`
- Input: Pi stream at `http://pi-zero-1.local:7123/stream.mjpg`
- Output: local annotated stream at `http://127.0.0.1:9134/annotated.mjpg`

Why this is the default:

- `YOLO26` is the safer default for this repo because Ultralytics supports tracking workflows around YOLO models directly.
- `RT-DETR` can still be used by switching `model.backend` to `rtdetr` in the config, but it is not the default choice here for vending because the official Ultralytics RT-DETR docs do not position it as the primary tracking path.
- `supervision.ByteTrack` gives explicit control over stable IDs and zone-crossing events, which is more useful than raw detector output for vending logic.

Run the detector service:

```bash
./scripts/run-vending-detector.sh ./configs/vending.example.yaml
```

Or start it from the app in the `Detection` card. The app writes the generated runtime config to `configs/vending.generated.yaml` and launches the same service locally.

Useful detector endpoints:

- Annotated stream: [http://127.0.0.1:9134/annotated.mjpg](http://127.0.0.1:9134/annotated.mjpg)
- Annotated snapshot: [http://127.0.0.1:9134/snapshot.jpg](http://127.0.0.1:9134/snapshot.jpg)
- Health: [http://127.0.0.1:9134/healthz](http://127.0.0.1:9134/healthz)
- Events: [http://127.0.0.1:9134/events](http://127.0.0.1:9134/events)

Point the Mac viewer at the annotated stream if you want to watch detections instead of the raw Pi feed:

```text
http://127.0.0.1:9134/annotated.mjpg
```

Detector config lives in [configs/vending.example.yaml](configs/vending.example.yaml). The most important fields are:

- `model.weights`: replace `yolo26n.pt` with your trained vending-product checkpoint
- `model.classes_of_interest`: limit tracking to product classes you care about
- `inventory.zones`: normalized polygons that represent shelf regions

## Product capture and training

The app writes a YOLO-style dataset rooted at `datasets/vending`:

- `images/train`
- `images/val`
- `labels/train`
- `labels/val`
- `classes.json`
- `data.yaml`

Validation images are assigned automatically at roughly a `4:1` train-to-val split as you save samples.

You can also validate or launch training outside the app:

```bash
./scripts/train-vending-model.sh ./datasets/vending yolo yolo26n.pt 40 960 8 vending-products ./runs/vending-training auto
```

Use `1` as the last argument to run dataset validation only:

```bash
./scripts/train-vending-model.sh ./datasets/vending yolo yolo26n.pt 40 960 8 vending-products ./runs/vending-training auto 1
```

Current event semantics:

- `removed_candidate`: a tracked object was stable inside a shelf zone, then stably moved outside it
- `returned_candidate`: a tracked object was stable outside a shelf zone, then stably moved back inside it

This is a prototype for vending telemetry, not a billing-grade decision engine. Do not auto-charge customers from the generic `yolo26n.pt` model or from zone transitions alone. For production you need:

- A custom-trained SKU model for every vendable product
- Shelf-specific zones per row or per slot
- Session logic that ties removals to a customer interaction window
- Reconciliation rules for occlusion, returns, and multi-item grabs
- A commercial-license review for any third-party model stack you deploy in a product

## Repo layout

- `pi/bridge_streamer.py`: MJPEG bridge built on `rpicam-vid` and Python's stdlib HTTP server
- `pi/arducam-bridge.service`: `systemd` unit for the Pi
- `scripts/install-pi-streamer.sh`: local installer that pushes the Pi service over SSH
- `scripts/build-mac-app.sh`: release bundler that emits `dist/ArducamBridgeViewer.app`
- `scripts/run-vending-detector.sh`: Mac-side detector service launcher
- `scripts/train-vending-model.sh`: Mac-side training launcher for labeled product datasets
- `vision/train_vending_model.py`: Ultralytics training entrypoint used by the app and shell script
- `vision/vending_tracker_service.py`: object detection, tracking, zone transitions, and annotated stream service
- `configs/vending.example.yaml`: detector and shelf-zone configuration template
- `configs/vending.generated.yaml`: runtime detector config written by the app
- `Package.swift`: macOS Swift package
- `Sources/ArducamBridgeViewer/`: native SwiftUI viewer
