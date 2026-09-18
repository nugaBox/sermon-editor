#!/bin/zsh
# SwiftPM 실행 파일 → SermonCut.app 번들 (Xcode 프로젝트 없이)
# 사용: scripts/build-app.sh [debug|release]   결과: build/SermonCut.app
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
swift build -c "$CONFIG" --product SermonCutApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SermonCutApp"
APP="build/SermonCut.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/SermonCut"
cp App/Info.plist "$APP/Contents/Info.plist"
# 샌드박스 없음(SPEC §2). 로컬 실행용 임시 서명
codesign --force --sign - --options runtime "$APP" >/dev/null
echo "$APP"
