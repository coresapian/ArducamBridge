# Apple TestFlight Release

This repo currently ships one iPhone/iPad app target in [ArducamBridge.xcodeproj](/Users/core/Documents/GitHub/ArducamBridge/ArducamBridge.xcodeproj). That same iOS build can be tested on Apple silicon Macs through TestFlight when the app is available on Mac in App Store Connect. There is not a separate native macOS `.pkg` or Mac Catalyst target in this project today.

## TODO

1. Open [ArducamBridge.xcodeproj](/Users/core/Documents/GitHub/ArducamBridge/ArducamBridge.xcodeproj) and confirm the `ArducamBridge` target signs with your Apple Developer team.
2. Confirm or replace `com.mldelaurier.arducambridge` with a bundle identifier that exists in your Apple Developer account.
3. Create the app record in App Store Connect before the first upload.
4. If you want TestFlight installs on Apple silicon Macs, make the iPhone/iPad app available on Mac in App Store Connect.
5. Export App Store Connect credentials for the upload script.
6. Run the upload script to archive, export, and upload the build.
7. Wait for processing, then add internal or external testers in TestFlight.

## Scripted Upload

The repo includes [scripts/upload-testflight.sh](/Users/core/Documents/GitHub/ArducamBridge/scripts/upload-testflight.sh), which:

1. archives the `ArducamBridge` scheme for `generic/platform=iOS`
2. exports an App Store Connect IPA
3. uploads the IPA to TestFlight

Preferred authentication uses an App Store Connect API key:

```bash
export APP_STORE_CONNECT_API_KEY_ID=YOUR_KEY_ID
export APP_STORE_CONNECT_API_ISSUER_ID=YOUR_ISSUER_ID
export APP_STORE_CONNECT_API_KEY_PATH=/absolute/path/to/AuthKey_YOUR_KEY_ID.p8
./scripts/upload-testflight.sh
```

Optional overrides:

```bash
VERSION=1.0.1 BUILD_NUMBER=202603052130 ./scripts/upload-testflight.sh
INTERNAL_ONLY=1 ./scripts/upload-testflight.sh
UPLOAD=0 ./scripts/upload-testflight.sh
```

Environment variables:

- `VERSION`: overrides `MARKETING_VERSION` for the archive
- `BUILD_NUMBER`: overrides `CURRENT_PROJECT_VERSION`; defaults to a timestamp so each upload is unique
- `INTERNAL_ONLY=1`: marks the export for internal TestFlight testing only
- `UPLOAD=0`: archives and exports locally without uploading

## Notes

- The app now reads `CFBundleShortVersionString` and `CFBundleVersion` from Xcode build settings, so TestFlight uploads can advance without editing the plist manually.
- The app uses plain HTTP on the local network to reach the Raspberry Pi bridge. The local-network privacy string is already in [Info.plist](/Users/core/Documents/GitHub/ArducamBridge/App/ArducamBridge/Resources/Info.plist).
- If you need a separate native macOS TestFlight build, this repo still needs a Mac Catalyst or AppKit target. The current TestFlight flow covers iPhone, iPad, and Apple silicon Mac testing from the same iOS upload.
