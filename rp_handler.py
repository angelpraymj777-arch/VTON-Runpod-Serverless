#!/usr/bin/env python3
"""
rp_handler.py — Umbral VTO RunPod Serverless Handler (ROBUSTO v3 - 2026-07-03)
=============================================================================
Recibe:
  {
    "input": {
      "model_image": "https://...",          # URL o data URI de la persona
      "product_image": "https://...",        # URL o data URI de la prenda
      "human_img": "https://...",            # alias
      "garment_image": "https://...",        # alias
      "workflow": {...},                     # Workflow JSON completo (opcional)
      "images": [{"name": "...", "image": "..."}, ...]  # alias para upload
    }
  }

Devuelve:
  {"image_url": "https://...", "images": [...], "elapsed_sec": N}

COMPATIBLE con el payload de umbral-vto-test.php en su forma ACTUAL.
"""

import os
import sys
import json
import time
import base64
import uuid
import logging
import urllib.request
import urllib.parse
import urllib.error

import runpod

# ============================================================
# CONFIG
# ============================================================
COMFY_URL  = os.environ.get("COMFY_URL",  "http://127.0.0.1:8188")
TIMEOUT_S  = int(os.environ.get("RUNPOD_TIMEOUT", "300"))
DEBUG      = os.environ.get("DEBUG", "1") == "1"

logging.basicConfig(
    level=logging.DEBUG if DEBUG else logging.INFO,
    format="%(asctime)s [handler] %(levelname)s: %(message)s",
    stream=sys.stdout,  # CRÍTICO: forzar stdout para que aparezca en logs RunPod
    force=True,
)
log = logging.getLogger("umbral-vto")


# ============================================================
# UTILS HTTP
# ============================================================
def http_get_json(url, timeout=30):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def http_post_json(url, payload, timeout=30):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


def http_post_multipart(url, file_bytes, filename, timeout=120):
    """POST multipart/form-data a /upload/image de ComfyUI."""
    import io
    boundary = "----umbral" + uuid.uuid4().hex
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="image"; filename="{filename}"\r\n'
        f"Content-Type: application/octet-stream\r\n\r\n"
    ).encode("utf-8") + file_bytes + f"\r\n--{boundary}--\r\n".encode("utf-8")

    req = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8", errors="replace"))


# ============================================================
# COMFYUI HEALTH
# ============================================================
def wait_comfy_ready(max_wait=85):
    """Espera a que ComfyUI responda /system_stats (incluye carga de modelos)."""
    log.info(f"Esperando ComfyUI en {COMFY_URL} (max {max_wait}s)...")
    t0 = time.time()
    last_err = None
    while time.time() - t0 < max_wait:
        try:
            stats = http_get_json(f"{COMFY_URL}/system_stats", timeout=3)
            v = stats.get("system", {}).get("comfyui_version", "?")
            log.info(f"✅ ComfyUI listo: v={v}, elapsed={time.time()-t0:.1f}s")
            return True
        except Exception as e:
            last_err = e
            elapsed = int(time.time() - t0)
            # Mostrar progreso cada 15s con el último log de ComfyUI si está disponible
            if elapsed % 15 == 0 and elapsed > 0:
                log.info(f"  ...{elapsed}s esperando ComfyUI. Last: {str(last_err)[:100]}")
                # Intentar leer log de ComfyUI para diagnosticar
                try:
                    if os.path.isfile("/tmp/comfyui.log"):
                        with open("/tmp/comfyui.log", "r", errors="ignore") as f:
                            tail = f.readlines()[-3:]
                            for line in tail:
                                log.info(f"    [comfyui] {line.rstrip()[:200]}")
                except Exception:
                    pass
            time.sleep(2)
    raise RuntimeError(f"ComfyUI no arrancó en {max_wait}s. Last error: {last_err}. "
                       f"Probable: el Execution Timeout del endpoint es < {max_wait}s. "
                       f"Subilo a 600s en RunPod Console → endpoint → Configuration.")


# ============================================================
# IMAGE UPLOAD
# ============================================================
def fetch_image_bytes(url_or_b64: str) -> bytes:
    """Decodifica URL http(s) o data URI base64 a bytes."""
    if not url_or_b64:
        raise ValueError("URL/base64 vacío")
    if url_or_b64.startswith("data:"):
        b64 = url_or_b64.split(",", 1)[1]
        return base64.b64decode(b64)
    if url_or_b64.startswith("http://") or url_or_b64.startswith("https://"):
        with urllib.request.urlopen(url_or_b64, timeout=120) as r:
            return r.read()
    if os.path.isfile(url_or_b64):
        with open(url_or_b64, "rb") as f:
            return f.read()
    raise ValueError(f"Formato de imagen no soportado (primeros 50 chars): {url_or_b64[:50]}")


def upload_to_comfy(name: str, url_or_b64: str) -> str:
    """Sube imagen a ComfyUI /upload/image. Devuelve filename guardado."""
    log.info(f"Subiendo '{name}' desde {url_or_b64[:60]}...")
    img_bytes = fetch_image_bytes(url_or_b64)
    log.info(f"  '{name}': {len(img_bytes)} bytes leídos")
    resp = http_post_multipart(f"{COMFY_URL}/upload/image", img_bytes, name)
    saved_name = resp.get("name", name)
    log.info(f"  '{name}' → ComfyUI guardó como '{saved_name}'")
    return saved_name


# ============================================================
# WORKFLOW EXECUTION
# ============================================================
def queue_prompt(workflow: dict, client_id: str) -> str:
    payload = {"prompt": workflow, "client_id": client_id}
    log.info(f"Encolando workflow ({len(workflow)} nodos)...")
    resp = http_post_json(f"{COMFY_URL}/prompt", payload, timeout=30)
    if "prompt_id" not in resp:
        raise RuntimeError(f"ComfyUI rechazó el workflow: {json.dumps(resp)[:500]}")
    pid = resp["prompt_id"]
    log.info(f"✅ Workflow encolado: prompt_id={pid}")
    return pid


def get_history(prompt_id: str) -> dict:
    try:
        return http_get_json(f"{COMFY_URL}/history/{prompt_id}", timeout=10)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return {}
        raise


def wait_prompt_done(prompt_id: str, max_wait=240) -> dict:
    """
    Espera a que el workflow termine via /history polling.
    (Sin WebSocket para máxima compatibilidad; el handler del worker base
    no siempre tiene websocket-client instalado correctamente.)
    """
    log.info(f"Esperando resultado del workflow (polling /history, max {max_wait}s)...")
    t0 = time.time()
    last_log = 0
    while time.time() - t0 < max_wait:
        try:
            h = get_history(prompt_id)
            if prompt_id in h and h[prompt_id].get("outputs"):
                log.info(f"✅ Workflow {prompt_id} terminó en {time.time()-t0:.1f}s")
                return h[prompt_id]
        except Exception as e:
            log.debug(f"history poll error: {e}")

        # Log cada 10s
        elapsed = int(time.time() - t0)
        if elapsed - last_log >= 10:
            last_log = elapsed
            log.info(f"  ...{elapsed}s esperando workflow {prompt_id}")
        time.sleep(2)

    raise RuntimeError(f"Workflow {prompt_id} no terminó en {max_wait}s")


def extract_output_urls(history_entry: dict) -> list:
    """Extrae todas las URLs output del workflow."""
    outputs = history_entry.get("outputs", {}) or {}
    urls = []
    for node_id, node_out in outputs.items():
        if not isinstance(node_out, dict):
            continue
        # Imágenes
        for img in node_out.get("images", []) or []:
            fn = img.get("filename", "")
            if not fn:
                continue
            sub = img.get("subfolder", "") or ""
            q = urllib.parse.urlencode({
                "filename": fn,
                "type": img.get("type", "output"),
                "subfolder": sub,
            })
            urls.append(f"{COMFY_URL}/view?{q}")
        # Videos / gifs
        for k in ("gifs", "videos"):
            for v in node_out.get(k, []) or []:
                fn = v.get("filename", "")
                if fn:
                    q = urllib.parse.urlencode({
                        "filename": fn,
                        "type": v.get("type", "output"),
                        "subfolder": v.get("subfolder", "") or "",
                    })
                    urls.append(f"{COMFY_URL}/view?{q}")
    return urls


# ============================================================
# HANDLER PRINCIPAL
# ============================================================
def handler(event):
    """
    Handler RunPod principal.
    Espera: {"input": {"model_image": "...", "product_image": "...", "workflow": {...}}}
    Devuelve: {"image_url": "...", "images": [...], "elapsed_sec": N, ...}
    """
    t0 = time.time()
    job_input = event.get("input", {}) or {}

    # Extraer campos con TODOS los alias posibles
    model_image   = (
        job_input.get("model_image")
        or job_input.get("human_img")
        or job_input.get("human_image")
        or job_input.get("user_image")
        or job_input.get("person_image")
        or ""
    )
    product_image = (
        job_input.get("product_image")
        or job_input.get("garment_image")
        or job_input.get("garment_img")
        or job_input.get("cloth_image")
        or ""
    )
    workflow      = job_input.get("workflow")
    images_array  = job_input.get("images", []) or []

    log.info("=" * 60)
    log.info(f"NUEVO JOB  model_image={'SÍ' if model_image else 'NO'}  "
             f"product_image={'SÍ' if product_image else 'NO'}  "
             f"workflow={'SÍ ('+str(len(workflow))+' nodos)' if workflow else 'NO'}  "
             f"images_array={len(images_array)}")
    log.info("=" * 60)

    # ------------------ 1. Validar input ------------------
    if not workflow and not model_image:
        return {
            "error": "Faltan datos: necesito al menos 'workflow' o 'model_image' en input",
            "received_keys": list(job_input.keys()),
        }

    # ------------------ 2. Esperar ComfyUI ------------------
    try:
        wait_comfy_ready(max_wait=85)
    except Exception as e:
        log.exception("ComfyUI no responde")
        return {"error": f"ComfyUI no responde: {e}", "elapsed_sec": round(time.time() - t0, 1)}

    # ------------------ 3. Subir imágenes ------------------
    uploaded = {}

    # Estrategia A: subir las imágenes desde el array "images" (data URI) si vino
    if images_array:
        for i, img in enumerate(images_array):
            try:
                name = img.get("name") or f"image_{i}.jpg"
                url_or_b64 = img.get("image", "")
                if url_or_b64:
                    saved = upload_to_comfy(name, url_or_b64)
                    uploaded[name] = saved
            except Exception as e:
                log.warning(f"No pude subir imagen {i} desde array: {e}")

    # Estrategia B: si NO se subió ninguna imagen pero hay model/product, subirlas
    if not uploaded:
        if model_image:
            try:
                saved = upload_to_comfy("person.jpg", model_image)
                uploaded["person.jpg"] = saved
            except Exception as e:
                log.warning(f"No pude subir model_image: {e}")
        if product_image:
            try:
                saved = upload_to_comfy("garment.jpg", product_image)
                uploaded["garment.jpg"] = saved
            except Exception as e:
                log.warning(f"No pude subir product_image: {e}")

    if not uploaded:
        log.warning("⚠️  No se subió ninguna imagen. El workflow puede fallar al cargar LoadImage.")

    # Si no hay workflow pero hay imágenes, el job es inválido (necesitamos workflow)
    if not workflow:
        return {
            "error": "Falta 'workflow' en input. Sin workflow no puedo procesar.",
            "uploaded": uploaded,
            "elapsed_sec": round(time.time() - t0, 1),
        }

    # ------------------ 4. Encolar + esperar ------------------
    client_id = str(uuid.uuid4())
    try:
        prompt_id = queue_prompt(workflow, client_id)
        history_entry = wait_prompt_done(prompt_id, max_wait=TIMEOUT_S)
    except Exception as e:
        log.exception("Error en workflow")
        return {
            "error": str(e),
            "elapsed_sec": round(time.time() - t0, 1),
            "uploaded": uploaded,
        }

    # ------------------ 5. Extraer outputs ------------------
    output_urls = extract_output_urls(history_entry)
    elapsed = round(time.time() - t0, 1)
    log.info(f"📦 {len(output_urls)} imagen(es) generada(s) en {elapsed}s: {output_urls[:2]}")

    if not output_urls:
        return {
            "error": "Workflow terminó pero sin imágenes output. Verifica el workflow.",
            "history_outputs": list(history_entry.get("outputs", {}).keys()),
            "workflow_status": history_entry.get("status", "?"),
            "elapsed_sec": elapsed,
            "uploaded": uploaded,
        }

    return {
        "image_url":   output_urls[0],
        "images":      output_urls,
        "prompt_id":   prompt_id,
        "elapsed_sec": elapsed,
        "uploaded":    uploaded,
        "ok":          True,
    }


# ============================================================
# HEALTHCHECK & STARTUP
# ============================================================
def healthcheck_handler(event):
    """Handler para /health (no requiere input)."""
    try:
        wait_comfy_ready(max_wait=3)
        return {"status": "ok", "comfyui": "ready"}
    except Exception as e:
        return {"status": "busy", "comfyui": "starting", "error": str(e)}


# ============================================================
# RUNPOD BOOTSTRAP
# ============================================================
if __name__ == "__main__":
    log.info("=" * 60)
    log.info("Umbral VTO RunPod Handler v3 (2026-07-03)")
    log.info(f"  COMFY_URL = {COMFY_URL}")
    log.info(f"  TIMEOUT_S = {TIMEOUT_S}")
    log.info(f"  DEBUG     = {DEBUG}")
    log.info("=" * 60)

    # Arrancar con healthcheck + handler
    runpod.serverless.start({
        "handler": handler,
        "health": healthcheck_handler,
    })
