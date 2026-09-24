#!/bin/zsh
# Archive a Release build and upload it to App Store Connect for TestFlight.
#   native/testflight.sh              archive + upload
#   native/testflight.sh --no-upload  archive + export a local .ipa only
#
# Needs DEVELOPMENT_TEAM (native/.env, same as deploy.sh) and an app record for
# dev.ericbetts.voxelnative in App Store Connect. Uploading uses the Apple ID
# signed in to Xcode, or an App Store Connect API key when ASC_KEY_ID,
# ASC_ISSUER_ID and ASC_KEY_PATH (the .p8 file) are set.
#
# The build number is the git commit count, so it only goes up. BUILD_NUMBER=...
# overrides it (App Store Connect refuses a number it has already seen).
set -eu
HERE=${0:A:h}
cd "$HERE"
[ -f "$HERE/.env" ] && set -a && . "$HERE/.env" && set +a
[ -n "${DEVELOPMENT_TEAM:-}" ] || { echo "set DEVELOPMENT_TEAM in native/.env"; exit 1; }

UPLOAD=1; [[ "${1:-}" == "--no-upload" ]] && UPLOAD=0
if [[ -n "$(git -C "$HERE" status --porcelain)" ]]; then
  echo "warning: uncommitted changes; the build is stamped with HEAD but includes them"
fi
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$HERE" rev-list --count HEAD)}"
GIT_HASH="$(git -C "$HERE" rev-parse --short HEAD)"
OUT="$HOME/Library/Developer/Xcode/DerivedData/voxelnative-cli/testflight"
ARCHIVE="$OUT/VoxelNative-$BUILD_NUMBER.xcarchive"
mkdir -p "$OUT"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

# Watchdog: kill the deadlocked clang version probe (swiftlang/swift-build#1315),
# as in deploy.sh.
( while true; do
    ps -axo pid,etime,command | grep '[c]lang -v -E -dM' | while read -r pid et rest; do
      s=$(echo "$et" | awk -F: '{if(NF==3)print $1*3600+$2*60+$3; else if(NF==2)print $1*60+$2; else print $1}')
      [[ "${s:-0}" -ge 20 ]] && kill -9 "$pid" 2>/dev/null
    done; sleep 5; done ) &
WD=$!; trap 'kill $WD 2>/dev/null' EXIT

AUTH=()
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" && -n "${ASC_KEY_PATH:-}" ]]; then
  AUTH=(-authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID" -authenticationKeyPath "$ASC_KEY_PATH")
fi

echo "archiving build $BUILD_NUMBER ($GIT_HASH)..."
rm -rf "$ARCHIVE"
xcodebuild -project VoxelNative.xcodeproj -scheme VoxelNative -configuration Release \
  -destination 'generic/platform=visionOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates "${AUTH[@]}" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" GIT_HASH="$GIT_HASH" archive 2>&1 \
  | grep -E 'error:|ARCHIVE' | tee "$OUT/archive.txt" || true
grep -q 'ARCHIVE SUCCEEDED' "$OUT/archive.txt" || { echo "archive FAILED (errors above)"; exit 1; }

# Apple rejects uploads whose required-reason APIs aren't declared; make sure
# the privacy manifest made it into the bundle.
[ -f "$ARCHIVE/Products/Applications/VoxelNative.app/PrivacyInfo.xcprivacy" ] \
  || { echo "PrivacyInfo.xcprivacy missing from the app bundle"; exit 1; }

DEST=export; (( UPLOAD )) && DEST=upload
OPTS="$OUT/ExportOptions.plist"
cat > "$OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

echo "${DEST}ing..."
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" \
  -exportPath "$OUT/export-$BUILD_NUMBER" -allowProvisioningUpdates "${AUTH[@]}" 2>&1 \
  | grep -E 'error:|EXPORT|Upload|upload' | tee "$OUT/export.txt" || true
grep -q 'EXPORT SUCCEEDED' "$OUT/export.txt" || { echo "export/upload FAILED (errors above)"; exit 1; }

if (( UPLOAD )); then
  echo "uploaded build $BUILD_NUMBER; it shows up in App Store Connect > TestFlight after processing"
else
  echo "exported: $OUT/export-$BUILD_NUMBER"
fi
