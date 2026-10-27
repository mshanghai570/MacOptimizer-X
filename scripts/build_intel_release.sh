#!/bin/bash

set -euo pipefail

APP_NAME="Mac优化大师"
EXECUTABLE_NAME="AppUninstaller"
SOURCE_DIR="AppUninstaller"
BUILD_DIR="build_intel"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
DMG_STAGE="${BUILD_DIR}/dmg"
DMG_PATH="${BUILD_DIR}/MacOptimizer-Intel.dmg"

SWIFT_FILES=()
while IFS= read -r -d '' source_file; do
    SWIFT_FILES+=("${source_file}")
done < <(find "${SOURCE_DIR}" -type f -name '*.swift' -print0)
if [[ ${#SWIFT_FILES[@]} -eq 0 ]]; then
    echo "No Swift source files found" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "${SOURCE_DIR}/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
if compgen -G "${SOURCE_DIR}/Localizations/*.lproj" > /dev/null; then
    cp -R "${SOURCE_DIR}/Localizations/"*.lproj "${APP_BUNDLE}/Contents/Resources/"
fi

find "${SOURCE_DIR}" -maxdepth 1 -type f \
    ! -name '*.swift' \
    ! -name 'Info.plist' \
    ! -name 'compile_errors.txt' \
    -exec cp {} "${APP_BUNDLE}/Contents/Resources/" \;

SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -O \
    -target x86_64-apple-macos12.0 \
    -sdk "${SDK_PATH}" \
    -parse-as-library \
    -o "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}" \
    "${SWIFT_FILES[@]}"

ARCHITECTURES="$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/${EXECUTABLE_NAME}")"
if [[ "${ARCHITECTURES}" != "x86_64" ]]; then
    echo "Expected an x86_64 executable, got: ${ARCHITECTURES}" >&2
    exit 1
fi

codesign --force --deep --sign - "${APP_BUNDLE}"
codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}"

mkdir -p "${DMG_STAGE}"
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"
hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${DMG_STAGE}" \
    -format UDZO \
    -ov \
    "${DMG_PATH}"

shasum -a 256 "${DMG_PATH}" > "${DMG_PATH}.sha256"
echo "Intel release created at ${DMG_PATH}"
