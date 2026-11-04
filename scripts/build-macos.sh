#!/usr/bin/env bash
# Builds a universal SuniCapture.app, runs the core checks in an isolated library,
# then packages dist/SuniCapture-<version>-macos-universal.dmg and SHA256SUMS-macos.txt.
#   --install     copy the app to /Applications (the library is stored separately and kept)
#   --skip-tests  rebuild only; checks are run separately
#   --ui-checks   also run interface, screen capture and real recording checks
#                 (interactive desktop and screen recording permission required)
# SUNICAPTURE_SIGN_IDENTITY selects the code signing identity (default: ad hoc "-").
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
package="$root/src/SuniCapture.macOS"
dist="$root/dist"
app="$dist/SuniCapture.app"
install=0 tests=1 ui=0
for option in "$@"; do
  case "$option" in
    --install) install=1 ;;
    --skip-tests) tests=0 ;;
    --ui-checks) ui=1 ;;
    *) echo "Unknown option: $option" >&2; exit 2 ;;
  esac
done
if [ $tests = 0 ] && [ $ui = 1 ]; then echo "--skip-tests cannot be combined with --ui-checks" >&2; exit 2; fi

version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$root/src/SuniCapture/SuniCapture.csproj")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version: $version" >&2; exit 1; }

python3 "$root/scripts/check-localization.py"
swift build --package-path "$package" -c release --arch arm64 --arch x86_64
binary="$(swift build --package-path "$package" -c release --arch arm64 --arch x86_64 --show-bin-path)/SuniCapture"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/SuniCapture"
sed "s/__VERSION__/$version/g" "$package/Info.plist" > "$app/Contents/Info.plist"
cp "$root/src/SuniCapture/Localization/strings.json" "$package/Resources/strings.macos.json" \
   "$root/assets/Brand/sunicapture-logo.png" "$root/assets/Brand/sunicapture-icon.png" \
   "$root/THIRD-PARTY-NOTICES.md" "$app/Contents/Resources/"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size "$root/assets/Brand/sunicapture-icon.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$root/assets/Brand/sunicapture-icon.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --options runtime --timestamp=none --sign "${SUNICAPTURE_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"

if [ $tests = 1 ]; then
  "$app/Contents/MacOS/SuniCapture" --self-test --data-dir "$root/artifacts/macos-checks/core-$(date +%Y%m%d-%H%M%S)"
fi
if [ $ui = 1 ]; then
  # Launched through LaunchServices so macOS attributes the screen recording permission to the app.
  checks="$root/artifacts/macos-checks/ui-$(date +%Y%m%d-%H%M%S)"
  open -W -n "$app" --args --ui-self-test --data-dir "$checks"
  grep -q '"success" : true' "$checks/latest-report.json" || { echo "Interface checks failed: $checks/latest-report.json" >&2; exit 1; }
  echo "Interface checks passed: $checks/latest-report.json"
fi

staging="$work/dmg"
mkdir -p "$staging"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
dmg="$dist/SuniCapture-$version-macos-universal.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "SuniCapture $version" -srcfolder "$staging" -ov -format UDZO "$dmg"
(cd "$dist" && shasum -a 256 "$(basename "$dmg")" > SHA256SUMS-macos.txt)
echo "Built $dmg"

if [ $install = 1 ]; then
  rm -rf /Applications/SuniCapture.app
  ditto "$app" /Applications/SuniCapture.app
  echo "Installed /Applications/SuniCapture.app"
fi
