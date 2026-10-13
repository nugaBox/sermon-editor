#!/bin/zsh
# SwiftPM 실행 파일 → SermonCut.app 번들 (Xcode 프로젝트 없이)
# 사용: scripts/build-app.sh [debug|release] [--install]   결과: build/SermonCut.app
#   --install: /Applications/SermonCut.app으로 옮겨 설치 (앱 목록에 SermonCut이 하나만 보이도록 build/ 사본은 남기지 않음)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="release"
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
  esac
done
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
swift build -c "$CONFIG" --product SermonCutApp
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SermonCutApp"
APP="build/SermonCut.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN" "$APP/Contents/MacOS/SermonCut"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 샌드박스 없음(SPEC §2). 서명:
#  - Apple Development 인증서가 있으면 그것으로 (서명이 빌드마다 같아서 Keychain '항상 허용'이 유지됨)
#  - 없거나 SIGN_IDENTITY=- 이면 임시(ad-hoc) 서명
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning -v 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')}"
if [[ -n "$IDENTITY" && "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$APP" >/dev/null
else
  codesign --force --sign - --options runtime "$APP" >/dev/null
fi
if (( INSTALL )); then
  DEST="/Applications/SermonCut.app"
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  "$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
  rm -rf "$APP"
  touch "$DEST"
  "$LSREGISTER" -f "$DEST"
  echo "$DEST"
else
  echo "$APP"
fi
