#!/bin/zsh
# 배포용 DMG 만들기: 앱 + 응용 프로그램 바로가기 + 필수 구성요소 설치 스크립트
# 사용: scripts/make-dmg.sh   결과: build/SermonEditor-<버전>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="누가의 Sermon Editor"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' App/Info.plist)"
scripts/build-app.sh release >/dev/null

STAGE="build/dmg"
DMG="build/SermonEditor-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "build/$APP_NAME.app" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
cp scripts/install-dependencies.sh "$STAGE/필수 구성요소 설치.command"
chmod +x "$STAGE/필수 구성요소 설치.command"

hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
# 임시 사본들이 앱 목록에 여러 번 보이지 않도록 등록 해제 후 삭제
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for copy in "$PWD/$STAGE/$APP_NAME.app" "$PWD/build/$APP_NAME.app"; do
  "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
rm -rf "$STAGE" "build/$APP_NAME.app"
echo "$DMG"
