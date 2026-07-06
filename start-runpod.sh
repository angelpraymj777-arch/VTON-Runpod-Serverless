#!/usr/bin/env bash
# start-runpod.sh — UMBRAL v2 (modelos PRE-CARGADOS en build time)
# -----------------------------------------------------------------------------
# Esta versión asume que los modelos grandes ya están bakeados en la imagen:
#   - SD 1.5 inpainting  -> /workspace/ComfyUI/models/checkpoints/sd-v1-5-inpainting.ckpt
#   - CatVTON (completo) -> /root/.cache/huggingface/hub/models--zhengchong--CatVTON/
# Como ya están, los `wget`/`huggingface-cli` que tenía la versión anterior
# ahora son NO-OP (sólo se ejecutan si por algún motivo faltaran).
#
# El cold start típico es ~30-50s (solo boot de ComfyUI + carga a VRAM),
# dentro del Execution Timeout de 120s del endpoint.
# -----------------------------------------------------------------------------
set -uo pipefail   # NO usamos -e: queremos que el handler arranque aunque ComfyUI tarde

COMFY_DIR="/comfyui"
COMFY_URL="http://127.0.0.1:8188"
COMFY_HEALTH_URL="${COMFY_URL}/system_stats"
COMFY_LOG="/tmp/comfyui.log"
WORKFLOW_DIR="${COMFY_DIR}/workflows"
CUSTOM_NODES_DIR="${COMFY_DIR}/custom_nodes"

mkdir -p "$WORKFLOW_DIR" "$CUSTOM_NODES_DIR" "${COMFY_DIR}/models" \
         "${COMFY_DIR}/output" "${COMFY_DIR}/input" "${COMFY_DIR}/temp" \
         /root/.cache/huggingface

# ---- Re-exportar env vars para que el handler herede el cache HF ----
export HF_HOME=/root/.cache/huggingface
export HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub
export HF_HUB_DISABLE_TELEMETRY=1

# ---- 1. Nodo ComfyUI-CatVTON (NO-OP si ya está instalado) ----
if [ ! -d "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON" ]; then
  echo "[start] Instalando nodo ComfyUI-CatVTON (una sola vez)..."
  cd "$CUSTOM_NODES_DIR"
  wget -q https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/ComfyUI-CatVTON.zip
  unzip -q ComfyUI-CatVTON.zip && rm ComfyUI-CatVTON.zip
  [ -f "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON/requirements.txt" ] && \
    pip install --no-cache-dir -r "${CUSTOM_NODES_DIR}/ComfyUI-CatVTON/requirements.txt" || true
fi

# ---- 2. Workflow JSON (NO-OP si ya existe) ----
if [ ! -f "${WORKFLOW_DIR}/catvton_workflow.json" ]; then
  echo "[start] Descargando catvton_workflow.json..."
  wget -q -O "${WORKFLOW_DIR}/catvton_workflow.json" \
    https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/catvton_workflow.json \
    || echo "[start] WARN: no pude bajar el workflow"
fi

# ---- 3. SD Inpainting model (NO-OP si ya está bakeado) ----
MODEL_DIR="${COMFY_DIR}/models/checkpoints"
INPAINT_MODEL="${MODEL_DIR}/sd-v1-5-inpainting.ckpt"
mkdir -p "$MODEL_DIR"
if [ ! -f "$INPAINT_MODEL" ]; then
  echo "[start] SD inpainting NO está bakeado, bajando ahora (raro, debería estarlo)..."
  huggingface-cli download runwayml/stable-diffusion-inpainting \
    --include "sd-v1-5-inpainting.ckpt" \
    --cache-dir /root/.cache/huggingface \
    --local-dir /tmp/sd-inpaint-dl || {
      echo "[start] ERROR: no pude bajar SD inpainting"
      exit 0   # seguir igual, el job va a fallar pero el handler arranca
    }
  cp /tmp/sd-inpaint-dl/sd-v1-5-inpainting.ckpt "$INPAINT_MODEL"
  rm -rf /tmp/sd-inpaint-dl
else
  echo "[start] SD inpainting ya bakeado ✓ ($(du -h "$INPAINT_MODEL" | cut -f1))"
fi

# ---- 4. CatVTON snapshot (NO-OP si ya está bakeado en cache HF) ----
if [ ! -d "/root/.cache/huggingface/hub/models--zhengchong--CatVTON" ]; then
  echo "[start] CatVTON NO está bakeado, bajando ahora (raro, debería estarlo)..."
  huggingface-cli download zhengchong/CatVTON --repo-type model \
    --cache-dir /root/.cache/huggingface || {
      echo "[start] ERROR: no pude bajar CatVTON repo"
    }
else
  echo "[start] CatVTON ya bakeado ✓ ($(du -sh /root/.cache/huggingface/hub/models--zhengchong--CatVTON | cut -f1))"
fi

# ---- 5. Arrancar ComfyUI en background ----
start_comfyui() {
  if curl -fsS "$COMFY_HEALTH_URL" >/dev/null 2>&1; then
    echo "[start] ComfyUI ya estaba corriendo"
    return 0
  fi

  echo "[start] Iniciando ComfyUI en background..."
  cd "$COMFY_DIR"
  # --lowvram: para no morir de OOM en GPUs chicas; con 24GB no molesta.
  # Si tenés A100/H100 80GB podés sacar este flag.
  nohup python main.py \
    --listen 0.0.0.0 \
    --port 8188 \
    --disable-auto-launch \
    --lowvram \
    >>"$COMFY_LOG" 2>&1 &

  COMFY_PID=$!
  echo "[start] ComfyUI PID=$COMFY_PID, log=$COMFY_LOG"

  # Esperar hasta 90s (debajo del Execution Timeout del endpoint = 120s)
  for i in $(seq 1 90); do
    if curl -fsS "$COMFY_HEALTH_URL" >/dev/null 2>&1; then
      echo "[start] ComfyUI listo tras ${i}s"
      return 0
    fi
    if [ "$((i % 15))" = "0" ]; then
      echo "[start] ComfyUI arrancando... ${i}s"
      tail -n 1 "$COMFY_LOG" 2>/dev/null | head -c 200 || true
      echo ""
    fi
    if ! kill -0 "$COMFY_PID" 2>/dev/null; then
      echo "[start] ERROR: ComfyUI murió. Log:"
      tail -n 200 "$COMFY_LOG"
      return 1
    fi
    sleep 1
  done

  echo "[start] ERROR: ComfyUI no arrancó en 90s. Log:"
  tail -n 200 "$COMFY_LOG"
  return 1
}

# Llamar a start_comfyui pero NO fallar si ComfyUI no arranca — el handler puede
# arrancar igual y dar un error claro en el primer job.
start_comfyui || echo "[start] WARN: ComfyUI no arrancó aún, pero seguimos. El handler dará error específico si se llama un job."

# ---- 6. Lanzar handler RunPod ----
echo "[start] Lanzando handler RunPod: $*"
exec "$@"
