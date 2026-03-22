#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_LOGO="$ROOT_DIR/assets/icons/iris_logo.png"
APP_ICON="$ROOT_DIR/assets/icons/app_icon.png"
ADAPTIVE_ICON="$ROOT_DIR/assets/icons/app_icon_adaptive.png"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg is required to generate icon sources." >&2
  exit 1
fi

if ! command -v dart >/dev/null 2>&1; then
  echo "dart is required to regenerate launcher icons." >&2
  exit 1
fi

ffmpeg -loglevel error -y \
  -i "$SOURCE_LOGO" \
  -f lavfi -i "color=c=black:s=1024x1024" \
  -filter_complex "[0:v]scale=780:780:flags=lanczos[logo];[1:v][logo]overlay=(W-w)/2:(H-h)/2:format=auto,format=rgba" \
  -frames:v 1 -update 1 "$APP_ICON"

ffmpeg -loglevel error -y \
  -f lavfi -i "color=c=black@0.0:s=1024x1024,format=rgba" \
  -i "$SOURCE_LOGO" \
  -filter_complex "[1:v]scale=680:680:flags=lanczos[logo];[0:v][logo]overlay=(W-w)/2:(H-h)/2:format=auto,format=rgba" \
  -frames:v 1 -update 1 "$ADAPTIVE_ICON"

(
  cd "$ROOT_DIR"
  dart run flutter_launcher_icons
  dart run flutter_native_splash:create
)
