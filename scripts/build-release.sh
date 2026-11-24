#!/bin/bash
# Builds a Release Fontory.app (Apple Silicon, ad-hoc signed) and packages it as a .zip and a .dmg in dist/.
#
#   scripts/build-release.sh            version from project.yml
#   scripts/build-release.sh 0.3.1      version 0.3.1 (a leading "v" is dropped, so a git tag works too)
#
# Needs Xcode and XcodeGen (brew install xcodegen). Used by .github/workflows/release.yml as well.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
VERSION="${1:-}"
VERSION="${VERSION#v}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
DERIVED="$ROOT/build/release"
DIST="$ROOT/dist"

xcodegen generate --quiet

args=(-project Fontory.xcodeproj -scheme Fontory -configuration Release -derivedDataPath "$DERIVED" -destination "generic/platform=macOS"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
if [[ -n "$VERSION" ]]; then args+=(MARKETING_VERSION="$VERSION"); fi

xcodebuild "${args[@]}" clean build | grep -E "error:|warning: .*Fontory/|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/Release/Fontory.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="Fontory-$SHORT"
rm -rf "$DIST" && mkdir -p "$DIST"

ditto -c -k --keepParent "$APP" "$DIST/$NAME.zip"

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Fontory $SHORT" -srcfolder "$STAGE" -format UDZO -ov "$DIST/$NAME.dmg"
rm -rf "$STAGE"

(cd "$DIST" && shasum -a 256 "$NAME.zip" "$NAME.dmg" > SHA256SUMS.txt)
echo "Built Fontory $SHORT ($BUILD_NUMBER):"
ls -lh "$DIST"
