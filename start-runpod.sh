#!/usr/bin/env bash
set -euo pipefail

COMFY_DIR="/workspace/ComfyUI"
COMFY_URL="http://127.0.0.1:8188/system_stats"
COMFY_LOG="/tmp/comfyui.log"

start_comfyui() {
  if curl -fsS "$COMFY_URL" >/dev/null 2>&1; then
    echo "[entrypoint] ComfyUI already up"
    return
  fi

  echo "[entrypoint] Starting ComfyUI..."
  cd "$COMFY_DIR"
  nohup python main.py --listen 0.0.0.0 --port 8188 --disable-auto-launch >"$COMFY_LOG" 2>&1 &

  for _ in $(seq 1 180); do
    if curl -fsS "$COMFY_URL" >/dev/null 2>&1; then
      echo "[entrypoint] ComfyUI ready"
      return
    fi
    sleep 1
  done

  echo "[entrypoint] ComfyUI failed to start in time"
  if [ -f "$COMFY_LOG" ]; then
    tail -n 200 "$COMFY_LOG" || true
  fi
  exit 127
}

start_comfyui

echo "[entrypoint] Launching $*"
exec "$@"
