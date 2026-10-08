#!/bin/zsh
set -eu
project_dir="${0:A:h:h}"
case "${1:-}" in
  "") ;;
  *) print -u2 'Usage: zsh scripts/build.sh'; exit 2 ;;
esac
cd "$project_dir"
swift build -c release
# iCloud-synced folders (Desktop & Documents) re-attach Finder metadata that breaks codesign.
# Build the bundle outside them by default; COMPUTAH_APP_DIR overrides the location.
app_dir="${COMPUTAH_APP_DIR:-/Applications/Computah.app}"
# Replace generated resources so files from older builds cannot survive a rebuild.
rm -rf "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp .build/release/Computah "$app_dir/Contents/MacOS/Computah"
ditto .build/release/Computah_ComputahCore.bundle "$app_dir/Contents/Resources/Computah_ComputahCore.bundle"
ditto .build/release/Computah_Computah.bundle "$app_dir/Contents/Resources/Computah_Computah.bundle"
# App icon from the project logo (cached in .build).
icon=".build/AppIcon.icns"
if [[ ! -f "$icon" || docs/images/computah.png -nt "$icon" ]]; then
  iconset="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size docs/images/computah.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) docs/images/computah.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$icon"
fi
cp "$icon" "$app_dir/Contents/Resources/AppIcon.icns"
python3 - "$app_dir/Contents/Info.plist" "$project_dir" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as output:
    plistlib.dump({
        'CFBundleIdentifier': 'local.computah.v3',
        'CFBundleName': 'Computah',
        'CFBundleDisplayName': 'Computah',
        'CFBundleExecutable': 'Computah',
        'CFBundleIconFile': 'AppIcon',
        'CFBundlePackageType': 'APPL',
        'LSUIElement': True,
        'NSHighResolutionCapable': True,
        'NSPrefersDisplaySafeAreaCompatibilityMode': False,
        'LSEnvironment': {'COMPUTAH_PROJECT_ROOT': sys.argv[2]},
        'NSMicrophoneUsageDescription': 'Computah transcribes your voice on this Mac with a local speech model while listening is on.',
    }, output)
PY
# Retain the existing app identity so a rename does not intentionally reset macOS permissions.
# A stable certificate keeps Accessibility and Microphone grants across rebuilds; ad-hoc
# signatures change every build. Prefer an explicit identity, then a "Computah Dev" certificate.
signing_identity="${COMPUTAH_CODESIGN_IDENTITY:-}"
if [[ -z "$signing_identity" ]] && security find-identity -p codesigning | grep -q '"Computah Dev"'; then
  signing_identity="Computah Dev"
fi
if [[ -z "$signing_identity" ]]; then
  signing_identity="-"
  print -u2 'Signing ad-hoc: macOS may ask again for Accessibility and Microphone after this build.'
fi
xattr -cr "$app_dir"
codesign --force --sign "$signing_identity" --timestamp=none "$app_dir"
codesign --verify --strict "$app_dir"
print "Built $app_dir"
