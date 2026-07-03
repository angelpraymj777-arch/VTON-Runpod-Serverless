# =============================================================================
# Dockerfile — Umbral VTO (CatVTON) con modelos PRE-CARGADOS en build time
# =============================================================================
# Estrategia "bake-in":
#   1. La imagen base `runpod-worker-comfy:3.6.0-base` ya trae ComfyUI + Python.
#   2. Bajamos los modelos pesados (SD inpainting 4.3GB + CatVTON repo ~1GB)
#      durante el `docker build` usando `huggingface-cli`.
#   3. Como `huggingface_hub.snapshot_download` reusa `/root/.cache/huggingface`,
#      el nodo CatVTON (que llama snapshot_download al primer uso) va a usar
#      los archivos ya bakeados sin volver a descargarlos.
#   4. El SD inpainting lo copiamos también a
#      `/workspace/ComfyUI/models/checkpoints/` para que ComfyUI lo encuentre
#      en su propio formato de discovery (no lee del cache HF directamente).
#
# Tamaño final estimado: ~10 GB (base ~6GB + modelos ~4GB).
# Cold start esperado: ~30-50s (solo arrancar ComfyUI y cargar a VRAM),
#   holgura suficiente para Execution Timeout de 120s.
# =============================================================================

FROM timpietruskyblibla/runpod-worker-comfy:3.6.0-base

# --- Variables de entorno ---
ENV PYTHONUNBUFFERED=1
# Cache persistente para huggingface_hub.snapshot_download
ENV HF_HOME=/root/.cache/huggingface
ENV HUGGINGFACE_HUB_CACHE=/root/.cache/huggingface/hub
# Desactivar telemetría HF
ENV HF_HUB_DISABLE_TELEMETRY=1

# --- 1. Dependencias del sistema ---
WORKDIR /workspace
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3-opencv \
    libgl1-mesa-glx \
    libglib2.0-0 \
    unzip \
    wget \
    git \
    && rm -rf /var/lib/apt/lists/*

# --- 2. Instalar huggingface-cli (vía pip, separado para cache de layers) ---
RUN pip install --no-cache-dir "huggingface_hub[cli]>=0.20.0"

# --- 3. Crear directorios que la imagen base espera ---
RUN mkdir -p /workspace/ComfyUI/custom_nodes \
    /workspace/ComfyUI/workflows \
    /workspace/ComfyUI/models/checkpoints \
    /workspace/ComfyUI/models/attention \
    /workspace/test_images

# --- 4. Bake-in del modelo SD 1.5 Inpainting (~4.3 GB) ---
# Se baja al cache HF y luego se copia al dir que usa ComfyUI.
# El flag --include limita a un solo archivo (más rápido, menos disk I/O).
RUN mkdir -p /root/.cache/huggingface && \
    huggingface-cli download runwayml/stable-diffusion-inpainting \
    --include "sd-v1-5-inpainting.ckpt" \
    --cache-dir /root/.cache/huggingface \
    --local-dir /tmp/sd-inpaint-dl && \
    cp /tmp/sd-inpaint-dl/sd-v1-5-inpainting.ckpt \
    /workspace/ComfyUI/models/checkpoints/sd-v1-5-inpainting.ckpt && \
    rm -rf /tmp/sd-inpaint-dl && \
    ls -lh /workspace/ComfyUI/models/checkpoints/

# --- 5. Bake-in del modelo CatVTON completo (~1 GB) ---
# El nodo ComfyUI-CatVTON llama snapshot_download(repo_id="zhengchong/CatVTON")
# al primer uso. Como ya tenemos el snapshot en HF_HOME, va a reusarlo.
# --local-dir hace que se baje a un path plano (más cómodo para verificar).
RUN huggingface-cli download zhengchong/CatVTON \
    --repo-type model \
    --cache-dir /root/.cache/huggingface && \
    echo "CatVTON repo OK en /root/.cache/huggingface" && \
    du -sh /root/.cache/huggingface

# --- 6. Instalar nodo ComfyUI-CatVTON + workflow ---
WORKDIR /workspace/ComfyUI/custom_nodes
RUN wget -q https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/ComfyUI-CatVTON.zip && \
    unzip -q ComfyUI-CatVTON.zip && \
    rm ComfyUI-CatVTON.zip && \
    if [ -f ComfyUI-CatVTON/requirements.txt ]; then \
    pip install --no-cache-dir -r ComfyUI-CatVTON/requirements.txt ; \
    fi

WORKDIR /workspace/ComfyUI/workflows
RUN wget -q -O catvton_workflow.json \
    https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/catvton_workflow.json

# --- 7. Dependencias Python extra + permisos ---
WORKDIR /workspace
RUN pip install --no-cache-dir pillow numpy requests
RUN chmod -R 755 /workspace/ComfyUI

# --- 8. Copiar cliente + handler custom de Umbral ---
COPY test.py /workspace/
COPY rp_handler.py /workspace/
RUN chmod +x /workspace/rp_handler.py

# --- 9. Healthcheck (ComfyUI responde en :8188) ---
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=5 \
    CMD curl --fail http://localhost:8188/system_stats || exit 1

# --- 10. start-runpod.sh (idempotente, downloads no-op) ---
COPY start-runpod.sh /workspace/
RUN chmod +x /workspace/start-runpod.sh

# --- 11. Entrypoint + CMD ---
# start-runpod.sh: arranca ComfyUI en background → luego exec el CMD
ENTRYPOINT ["/workspace/start-runpod.sh"]
CMD ["python", "/workspace/rp_handler.py"]
