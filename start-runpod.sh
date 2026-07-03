#!/usr/bin/env bash
# start-runpod.sh — FINAL (Umbral VTO)
# Arranca ComfyUI en background, espera a que esté 100% listo (incluyendo carga de modelos),
# y luego exec el handler de RunPod.
set -uo pipefail   # NO usamos -e: queremos que el handler arranque aunque ComfyUI tarde

COMFY_DIR="/workspace/ComfyUI"
COMFY_URL="http://127.0.0.1:8188"
COMFY_HEALTH_URL="${COMFY_URL}/system_stats"
COMFY_LOG="/tmp/comfyui.log"
WORKFLOW_DIR="${COMFY_DIR}/workflows"
CUSTOM_NODES_DIR="${COMFY_DIR}/custom_nodes"

mkdir -p "$WORKFLOW_DIR" "$CUSTOM_NODES_DIR" "${COMFY_DIR}/models" "${COMFY_DIR}/output" "${COMFY_DIR}/input" "${COMFY_DIR}/temp"

# ---- 1. Instalar nodo CatVTON (idempotente, sólo si falta) ----
if [ ! -d "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON" ]; then
  echo "[start] Instalando nodo ComfyUI-CatVTON (una sola vez)..."
  cd "$CUSTOM_NODES_DIR"
  if wget -q https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/ComfyUI-CatVTON.zip; then
    if unzip -q ComfyUI-CatVTON.zip && rm ComfyUI-CatVTON.zip; then
      if [ -f "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON/requirements.txt" ]; then
        pip install --no-cache-dir -r "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON/requirements.txt" || true
      fi
      echo "[start] CatVTON node instalado OK"
    else
      echo "[start] WARN: unzip falló, pero seguimos (puede que el nodo ya esté)"
    fi
  else
    echo "[start] WARN: wget falló al bajar CatVTON, seguimos (puede estar offline)"
  fi
fi

# ---- 2. Descargar workflow JSON (idempotente) ----
if [ ! -f "${WORKFLOW_DIR}/catvton_workflow.json" ]; then
  echo "[start] Descargando catvton_workflow.json..."
  wget -q -O "${WORKFLOW_DIR}/catvton_workflow.json" \
    https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/catvton_workflow.json \
    || echo "[start] WARN: no pude bajar el workflow del repo upstream (sigue, lo cargará el handler)"
fi

# ---- 3. Descargar modelos si faltan ----
# El handler CatVTON necesita 2 modelos grandes (~5GB total). Si no están, los baja.
MODEL_DIR="${COMFY_DIR}/models/checkpoints"
INPAINT_MODEL="${MODEL_DIR}/sd-v1-5-inpainting.ckpt"
CATVTON_MODEL="${MODEL_DIR}/catvton_v1.5_fp16.safetensors"
mkdir -p "$MODEL_DIR"

if [ ! -f "$INPAINT_MODEL" ]; then
  echo "[start] Descargando stable-diffusion-inpainting (~5GB, ~5-10 min)..."
  wget -q --show-progress -O "$INPAINT_MODEL" \
    https://huggingface.co/runwayml/stable-diffusion-inpainting/resolve/main/sd-v1-5-inpainting.ckpt \
    && echo "[start] Inpainting model OK" \
    || echo "[start] WARN: no pude bajar el modelo inpainting (sigue, el job fallará)"
fi

# (CatVTON model lo baja el propio nodo CatVTON al primer uso; no hace falta aquí.)

# ---- 4. Arrancar ComfyUI en background ----
start_comfyui() {
  if curl -fsS "$COMFY_HEALTH_URL" >/dev/null 2>&1; then
    echo "[start] ComfyUI ya estaba corriendo"
    return 0
  fi

  echo "[start] Iniciando ComfyUI en background..."
  cd "$COMFY_DIR"
  # Flags:
  #   --listen 0.0.0.0    → accesible desde el handler (aunque sea localhost)
  #   --port 8188         → puerto por defecto
  #   --disable-auto-launch  → no abre browser (es headless)
  #   --lowvram           → usa menos VRAM (para GPUs <16GB; comentar si tenés A100/H100 40GB+)
  nohup python main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --disable-auto-launch \
    --lowvram \
    >>"$COMFY_LOG" 2>&1 &

  COMFY_PID=$!
  echo "[start] ComfyUI PID=$COMFY_PID, log=$COMFY_LOG"

  # Esperar hasta 300s (5 min) — incluye carga de modelos pesados
  for i in $(seq 1 300); do
    if curl -fsS "$COMFY_HEALTH_URL" >/dev/null 2>&1; then
      echo "[start] ComfyUI listo tras ${i}s"
      return 0
    fi
    # Cada 30s, mostrar progreso
    if [ "$((i % 30))" = "0" ]; then
      echo "[start] ComfyUI arrancando... ${i}s elapsed (última línea del log:)"
      tail -n 1 "$COMFY_LOG" 2>/dev/null | head -c 200 || true
      echo ""
    fi
    # Si el proceso murió, salir
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
      echo "[start] ERROR: ComfyUI murió. Log:"
      tail -n 200 "$COMFY_LOG"
      return 1
    fi
    sleep 1
  done

  echo "[start] ERROR: ComfyUI no arrancó en 300s. Log:"
  tail -n 200 "$COMFY_LOG"
  return 1
}

# Llamar a start_comfyui pero NO fallar si ComfyUI no arranca — el handler puede
# arrancar igual y dar un error claro en el primer job.
start_comfyui || echo "[start] WARN: ComfyUI no arrancó aún, pero seguimos. El handler dará error específico si se llama un job."

# ---- 5. Lanzar handler RunPod ----
# El CMD original ("runpod-worker-comfy") es lo que se va a ejecutar.
# Ese binario ya está en PATH en la imagen base y se conecta con RunPod,
# usando /workspace/rp_handler.py como handler (lo detecta por convención).
echo "[start] Lanzando handler RunPod: $*"
exec "$@"
