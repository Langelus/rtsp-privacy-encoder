FROM python:3.12-slim

# ffmpeg/ffprobe: used to grab a live frame + probe camera size for the editor.
# (No GPU needed here — the encoder containers do the hardware work.)
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir flask pillow waitress

WORKDIR /app
COPY server.py /app/server.py
COPY static/ /app/static/

EXPOSE 80
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s \
  CMD python -c "import urllib.request;urllib.request.urlopen('http://127.0.0.1/api/health',timeout=5)"
CMD ["python", "server.py"]
