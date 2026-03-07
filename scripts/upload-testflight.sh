#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="${PROJECT_PATH:-${ROOT_DIR}/ArducamBridge.xcodeproj}"
SCHEME="${SCHEME:-ArducamBridge}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_ROOT="${ARCHIVE_ROOT:-${ROOT_DIR}/build/testflight}"
ARCHIVE_PATH="${ARCHIVE_PATH:-${ARCHIVE_ROOT}/${SCHEME}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-${ARCHIVE_ROOT}/export}"
RESULT_BUNDLE_PATH="${RESULT_BUNDLE_PATH:-${ARCHIVE_ROOT}/${SCHEME}.xcresult}"
DESTINATION="${DESTINATION:-generic/platform=iOS}"
UPLOAD="${UPLOAD:-1}"
INTERNAL_ONLY="${INTERNAL_ONLY:-0}"

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "error: missing required command: $1" >&2
        exit 1
    fi
}

build_setting() {
    local key="$1"
    printf '%s\n' "${BUILD_SETTINGS}" | awk -F' = ' -v target="${key}" '$1 ~ ("^[[:space:]]*" target "$") { print $2; exit }'
}

require_command xcodebuild
require_command xcrun
require_command awk
require_command find

mkdir -p "${ARCHIVE_ROOT}"

BUILD_SETTINGS="$(
    xcodebuild \
        -project "${PROJECT_PATH}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -showBuildSettings
)"

DEFAULT_VERSION="$(build_setting MARKETING_VERSION)"
DEFAULT_TEAM_ID="$(build_setting DEVELOPMENT_TEAM)"
DEFAULT_BUNDLE_ID="$(build_setting PRODUCT_BUNDLE_IDENTIFIER)"

VERSION="${VERSION:-${DEFAULT_VERSION}}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
TEAM_ID="${TEAM_ID:-${DEFAULT_TEAM_ID}}"

if [[ -z "${TEAM_ID}" ]]; then
    echo "error: DEVELOPMENT_TEAM is not set for ${SCHEME}" >&2
    exit 1
fi

AUTH_BUILD_ARGS=()
AUTH_UPLOAD_ARGS=()

if [[ -n "${APP_STORE_CONNECT_API_KEY_ID:-}" || -n "${APP_STORE_CONNECT_API_ISSUER_ID:-}" || -n "${APP_STORE_CONNECT_API_KEY_PATH:-}" ]]; then
    : "${APP_STORE_CONNECT_API_KEY_ID:?Set APP_STORE_CONNECT_API_KEY_ID}"
    : "${APP_STORE_CONNECT_API_ISSUER_ID:?Set APP_STORE_CONNECT_API_ISSUER_ID}"
    : "${APP_STORE_CONNECT_API_KEY_PATH:?Set APP_STORE_CONNECT_API_KEY_PATH}"

    AUTH_BUILD_ARGS=(
        -authenticationKeyPath "${APP_STORE_CONNECT_API_KEY_PATH}"
        -authenticationKeyID "${APP_STORE_CONNECT_API_KEY_ID}"
        -authenticationKeyIssuerID "${APP_STORE_CONNECT_API_ISSUER_ID}"
    )
    AUTH_UPLOAD_ARGS=(
        --api-key "${APP_STORE_CONNECT_API_KEY_ID}"
        --api-issuer "${APP_STORE_CONNECT_API_ISSUER_ID}"
        --p8-file-path "${APP_STORE_CONNECT_API_KEY_PATH}"
    )
elif [[ -n "${APP_STORE_CONNECT_USERNAME:-}" ]]; then
    if [[ -n "${APP_STORE_CONNECT_PASSWORD_ITEM:-}" ]]; then
        AUTH_UPLOAD_ARGS=(
            -u "${APP_STORE_CONNECT_USERNAME}"
            -p "@keychain:${APP_STORE_CONNECT_PASSWORD_ITEM}"
        )
    elif [[ -n "${APP_STORE_CONNECT_APP_PASSWORD:-}" ]]; then
        AUTH_UPLOAD_ARGS=(
            -u "${APP_STORE_CONNECT_USERNAME}"
            -p "${APP_STORE_CONNECT_APP_PASSWORD}"
        )
    else
        echo "error: set APP_STORE_CONNECT_PASSWORD_ITEM or APP_STORE_CONNECT_APP_PASSWORD with APP_STORE_CONNECT_USERNAME" >&2
        exit 1
    fi
elif [[ "${UPLOAD}" == "1" ]]; then
    echo "error: upload requested, but no App Store Connect credentials were provided" >&2
    exit 1
fi

rm -rf "${ARCHIVE_PATH}" "${EXPORT_PATH}" "${RESULT_BUNDLE_PATH}"

EXPORT_OPTIONS_PLIST="$(mktemp "${TMPDIR:-/tmp}/arducambridge-export-options.XXXXXX.plist")"
cleanup() {
    rm -f "${EXPORT_OPTIONS_PLIST}"
}
trap cleanup EXIT

cat > "${EXPORT_OPTIONS_PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>destination</key>
    <string>export</string>
    <key>method</key>
    <string>app-store-connect</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>teamID</key>
    <string>${TEAM_ID}</string>
    <key>uploadSymbols</key>
    <true/>
EOF

if [[ "${INTERNAL_ONLY}" == "1" ]]; then
    cat >> "${EXPORT_OPTIONS_PLIST}" <<EOF
    <key>testFlightInternalTestingOnly</key>
    <true/>
EOF
fi

cat >> "${EXPORT_OPTIONS_PLIST}" <<EOF
</dict>
</plist>
EOF

echo "Archiving ${SCHEME} ${VERSION} (${BUILD_NUMBER}) for ${DESTINATION}"
ARCHIVE_CMD=(
    xcodebuild
    -project "${PROJECT_PATH}"
    -scheme "${SCHEME}"
    -configuration "${CONFIGURATION}"
    -destination "${DESTINATION}"
    -archivePath "${ARCHIVE_PATH}"
    -resultBundlePath "${RESULT_BUNDLE_PATH}"
    -allowProvisioningUpdates
)
if (( ${#AUTH_BUILD_ARGS[@]} > 0 )); then
    ARCHIVE_CMD+=("${AUTH_BUILD_ARGS[@]}")
fi
ARCHIVE_CMD+=(
    MARKETING_VERSION="${VERSION}"
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
    archive
)
"${ARCHIVE_CMD[@]}"

echo "Exporting App Store Connect package"
EXPORT_CMD=(
    xcodebuild
    -exportArchive
    -archivePath "${ARCHIVE_PATH}"
    -exportPath "${EXPORT_PATH}"
    -exportOptionsPlist "${EXPORT_OPTIONS_PLIST}"
    -allowProvisioningUpdates
)
if (( ${#AUTH_BUILD_ARGS[@]} > 0 )); then
    EXPORT_CMD+=("${AUTH_BUILD_ARGS[@]}")
fi
"${EXPORT_CMD[@]}"

IPA_PATH="$(find "${EXPORT_PATH}" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
if [[ -z "${IPA_PATH}" ]]; then
    echo "error: export did not produce an IPA in ${EXPORT_PATH}" >&2
    exit 1
fi

echo "Archive: ${ARCHIVE_PATH}"
echo "IPA: ${IPA_PATH}"
echo "Bundle ID: ${DEFAULT_BUNDLE_ID}"
echo "Version: ${VERSION}"
echo "Build: ${BUILD_NUMBER}"
echo "Mac testing: enable the iPhone/iPad app for Apple silicon Macs in App Store Connect to test this same build on macOS."

if [[ "${UPLOAD}" != "1" ]]; then
    exit 0
fi

echo "Uploading to App Store Connect"
UPLOAD_CMD=(
    xcrun altool
    --upload-app
    -f "${IPA_PATH}"
    --wait
    --output-format json
)
if (( ${#AUTH_UPLOAD_ARGS[@]} > 0 )); then
    UPLOAD_CMD+=("${AUTH_UPLOAD_ARGS[@]}")
fi
"${UPLOAD_CMD[@]}"
