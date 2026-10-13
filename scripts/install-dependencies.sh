#!/bin/zsh
# 누가의 Sermon Editor 필수 구성요소 설치 (다른 Mac에서 처음 한 번)
#  - Homebrew로 ffmpeg, whisper-cpp 설치
#  - whisper 모델 3개를 ~/Library/Application Support/SermonCut/models 에 내려받기 (약 3.2GB)
# 이미 있는 것은 건너뛴다. 다시 실행해도 안전하다.
set -euo pipefail

echo "== 누가의 Sermon Editor 필수 구성요소 설치 =="

if ! command -v brew >/dev/null 2>&1; then
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && eval "$("$b" shellenv)" && break
  done
fi
if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew가 없습니다. https://brew.sh 의 안내대로 먼저 설치한 뒤 다시 실행해 주세요."
  exit 1
fi

for pkg in ffmpeg whisper-cpp; do
  if brew list --formula "$pkg" >/dev/null 2>&1; then
    echo "✓ $pkg 이미 설치됨"
  else
    echo "→ $pkg 설치 중…"
    brew install "$pkg"
  fi
done

MODELS="$HOME/Library/Application Support/SermonCut/models"
mkdir -p "$MODELS"

download() {
  local name="$1" url="$2" size="$3"
  local dest="$MODELS/$name"
  if [[ -f "$dest" && "$(stat -f %z "$dest")" == "$size" ]]; then
    echo "✓ $name 이미 있음"
    return
  fi
  echo "→ $name 내려받는 중… ($((size / 1024 / 1024))MB)"
  curl -L --fail --progress-bar -C - -o "$dest.part" "$url"
  if [[ "$(stat -f %z "$dest.part")" != "$size" ]]; then
    echo "✗ $name 크기가 맞지 않습니다. 다시 실행해 주세요."
    exit 1
  fi
  mv "$dest.part" "$dest"
}

download ggml-large-v3.bin      https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin 3095033483
download ggml-base.bin          https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin      147951465
download ggml-silero-v5.1.2.bin https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin 885098

echo
echo "완료. 이제 누가의 Sermon Editor를 실행하세요."
echo "썸네일·인트로/아웃트로 템플릿은 기존 Mac의 ~/Library/Application Support/SermonCut/templates 폴더를 같은 위치로 복사하면 됩니다."
