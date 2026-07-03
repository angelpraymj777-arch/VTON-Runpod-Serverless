FROM timpietruskyblibla/runpod-worker-comfy:3.6.0-base

# Set environment variables
ENV PYTHONUNBUFFERED=1

# Install dependencies for CatVTON including unzip
WORKDIR /workspace
RUN apt-get update && apt-get install -y \
    python3-opencv \
    libgl1-mesa-glx \
    libglib2.0-0 \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Create directory for custom nodes if it doesn't exist
WORKDIR /workspace/ComfyUI/custom_nodes
RUN mkdir -p /workspace/ComfyUI/custom_nodes

# Download and extract ComfyUI-CatVTON
RUN wget https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/ComfyUI-CatVTON.zip && \
    unzip ComfyUI-CatVTON.zip && \
    rm ComfyUI-CatVTON.zip

# Create workflows directory if it doesn't exist
RUN mkdir -p /workspace/ComfyUI/workflows

# Download workflow file
WORKDIR /workspace/ComfyUI/workflows
RUN wget https://github.com/Zheng-Chong/CatVTON/releases/download/ComfyUI/catvton_workflow.json

# Install Python requirements for CatVTON
WORKDIR /workspace/ComfyUI/custom_nodes/ComfyUI-CatVTON
RUN if [ -f requirements.txt ]; then pip install -r requirements.txt; fi

# Install additional pip packages to handle image processing
RUN pip install pillow numpy requests

# Fix any potential permissions issues
WORKDIR /workspace
RUN chmod -R 755 /workspace/ComfyUI
RUN chmod -R 755 /workspace/ComfyUI/custom_nodes/ComfyUI-CatVTON

# Copy the client script into the container
COPY test.py /workspace/

# Create a directory for test images
RUN mkdir -p /workspace/test_images

# Return to workspace directory
WORKDIR /workspace

# Add healthcheck
HEALTHCHECK --interval=30s --timeout=30s --start-period=60s --retries=3 \
  CMD curl --fail http://localhost:8188/system_stats || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
