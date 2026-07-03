FROM timpietruskyblibla/runpod-worker-comfy:3.6.0-base

ENV PYTHONUNBUFFERED=1
ENV COMFY_URL=http://127.0.0.1:8188
ENV RUNPOD_TIMEOUT=300
ENV DEBUG=1

# La imagen base ya trae: PyTorch + CUDA + ComfyUI + diffusers + transformers + runpod.
# NO reinstalamos nada de eso (destruye el cold-start).
# Sólo lo que el handler Umbral necesita y NO trae la imagen base:

RUN pip install --no-cache-dir \
        websocket-client \
        requests \
        pillow \
        numpy

# Healthcheck desactivado (lo maneja RunPod nativamente via /ping del handler)
HEALTHCHECK NONE

# Copiar handler y orquestador
COPY rp_handler.py     /workspace/rp_handler.py
COPY start-runpod.sh   /workspace/start-runpod.sh

# El handler Umbral está en /workspace/rp_handler.py y se carga automáticamente
# si está nombrado así (convención del runpod-worker-comfy base).
# También lo copiamos como rp_handler.py en la raíz por seguridad.
RUN cp /workspace/rp_handler.py /rp_handler.py 2>/dev/null || true
RUN chmod +x /workspace/start-runpod.sh

WORKDIR /workspace

# runpod-worker-comfy es el entrypoint de la imagen base; lo dejamos como CMD
# El start-runpod.sh orquesta ComfyUI en background, y el CMD final es
# runpod-worker-comfy que importa rp_handler.py automáticamente.
ENTRYPOINT ["/workspace/start-runpod.sh"]
CMD ["runpod-worker-comfy"]
