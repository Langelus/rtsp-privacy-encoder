# Single-image encoder + web UI
#
# Base: jrottenberg/ffmpeg (VAAPI build, Ubuntu 24.04)
# Adds:  VAAPI user-space drivers for AMD + Intel QuickSync
#        Python 3 + supervisor.py (camera lifecycle + Flask web UI)
#
# The host kernel driver (amdgpu / i915) is exposed via the passed-through
# /dev/dri node; this image supplies only the matching user-space library.
# One image serves both AMD iGPU and Intel QuickSync boxes.
ARG FFMPEG_BASE=jrottenberg/ffmpeg:8-vaapi
FROM ${FFMPEG_BASE}

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         mesa-libgallium \
         libva-drm2 \
         mesa-va-drivers \
         intel-media-va-driver \
         i965-va-driver \
         python3 \
         python3-pip \
         python3-venv \
    && python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir flask pillow waitress pyyaml \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 entrypoint.sh /entrypoint.sh
COPY supervisor.py /supervisor.py
COPY web/static/ /app/static/

VOLUME ["/config", "/overlays"]
EXPOSE 8090

ENTRYPOINT ["/opt/venv/bin/python3", "/supervisor.py"]
