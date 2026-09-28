#!/usr/bin/env python3
"""
Overlay admin web app for the RTSP privacy-encoder stack.

Endpoints:
  GET  /                            editor UI (static/index.html)
  GET  /api/health                  liveness probe
  GET  /api/cameras                 camera list + overlay metadata
  GET  /api/cameras/<name>/overlay  current overlay PNG
  POST /api/cameras/<name>/overlay  replace overlay PNG (raw PNG bytes in body)
  GET  /api/cameras/<name>/frame    grab a live frame from the camera (JPEG)
  GET  /api/cameras/<name>/size     probe the camera video size (W,H)
  POST /api/cameras/<name>/apply    restart the camera's encoder container

Config (env):
  OVERLAY_DIR  directory holding the overlay PNGs (default /overlays)
  CAMERAS      newline separated
               "name|overlay_file|container_name|source_url|output_url"
               (output_url is optional: the encoder's pushed stream on the
               bundled RTSP server, used to read the MAIN stream size while
               the camera's single main-session slot is held by the encoder)
  ADMIN_TOKEN  optional; if set, /api/* calls must send header X-Admin-Token
"""

import http.client
import io
import json
import os
import socket
import subprocess
import tempfile
import time
from pathlib import Path

from flask import Flask, abort, jsonify, request, send_file, send_from_directory
from werkzeug.exceptions import HTTPException
from PIL import Image

OVERLAY_DIR = Path(os.environ.get("OVERLAY_DIR", "/overlays"))
TOKEN = os.environ.get("ADMIN_TOKEN", "")
DOCKERSOCK = os.environ.get("DOCKER_SOCK", "/var/run/docker.sock")

app = Flask(__name__, static_folder="static", static_url_path="/")


# ---------------------------------------------------------------- cameras --
def cameras():
    out = []
    for line in os.environ.get("CAMERAS", "").splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split("|", 4)
        if len(parts) < 4:
            continue
        name, overlay_file, container, source_url = parts[:4]
        output_url = parts[4] if len(parts) > 4 else ""
        out.append({
            "name": name.strip(),
            "overlay_file": overlay_file.strip(),
            "container": container.strip(),
            "source_url": source_url.strip(),
            "output_url": output_url.strip(),
        })
    return out


def find_cam(name):
    for cam in cameras():
        if cam["name"] == name:
            return cam
    return None


def check_token():
    if not TOKEN:
        return
    # Liveness must stay open: the container's own healthcheck calls this
    # endpoint without any credential (it only returns ok=True, no secrets).
    if request.path == "/api/health":
        return
    # The static editor UI is open; only the API is gated.
    if not request.path.startswith("/api/"):
        return
    if request.headers.get("X-Admin-Token") != TOKEN:
        abort(401, description="missing or invalid X-Admin-Token header")


@app.before_request
def auth():
    check_token()


# Flask's built-in error pages are HTML, which the editor can't parse (it would
# show a useless "INTERNAL_SERVER_ERROR"). Return JSON for every error so the
# UI can display the actual message.
@app.errorhandler(HTTPException)
def http_error(exc):
    return jsonify(error=exc.description or exc.name), exc.code


@app.errorhandler(Exception)
def unhandled_error(exc):
    app.logger.exception("unhandled exception")
    return jsonify(error=f"internal error: {exc}"), 500


# ----------------------------------------------------------------- editor --
@app.get("/")
def index():
    # Flask's static handler serves /index.html but not "/" itself, so the
    # natural "open the editor" URL would 404. Serve the UI at the root.
    return send_from_directory(app.static_folder, "index.html")


# ------------------------------------------------------------------- API --
@app.get("/api/health")
def health():
    return jsonify(ok=True)


@app.get("/api/cameras")
def api_cameras():
    result = []
    for cam in cameras():
        png = OVERLAY_DIR / cam["overlay_file"]
        info = {
            "name": cam["name"],
            "container": cam["container"],
            "overlay_file": cam["overlay_file"],
            "has_overlay": png.exists(),
            "overlay_px": None,
            "has_frame_source": bool(cam["source_url"]),
        }
        if png.exists():
            try:
                with Image.open(png) as im:
                    info["overlay_px"] = {"w": im.width, "h": im.height}
            except Exception:
                pass
        result.append(info)
    return jsonify(result)


@app.get("/api/cameras/<name>/overlay")
def get_overlay(name):
    cam = find_cam(name) or abort(404, description="unknown camera")
    path = OVERLAY_DIR / cam["overlay_file"]
    if not path.exists():
        abort(404, description=f"no overlay for {name} yet")
    return send_file(path, mimetype="image/png")


@app.post("/api/cameras/<name>/overlay")
def save_overlay(name):
    cam = find_cam(name) or abort(404, description="unknown camera")
    data = request.get_data()
    if len(data) > 64 * 1024 * 1024:  # 64 MiB is absurdly more than any mask needs
        abort(413, description="overlay too large (max 64 MiB)")
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.load()
            w, h = im.size
    except Exception as exc:
        abort(400, description=f"body is not a valid image: {exc}")
    if w > 8192 or h > 8192:
        abort(400, description="overlay too large (max 8192x8192)")

    # normalise to a single RGBA PNG so ffmpeg always gets a predictable input
    buf = io.BytesIO()
    with Image.open(io.BytesIO(data)) as im:
        im.convert("RGBA").save(buf, format="PNG")

    target = OVERLAY_DIR / cam["overlay_file"]
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_bytes(buf.getvalue())
    os.replace(tmp, target)  # atomic: encoder always sees a complete file
    return jsonify(ok=True, width=w, height=h, saved=str(target))


def preview_url(cam):
    """URL of the camera's low-resolution substream, if we can derive it.

    These cameras limit the MAIN stream to one concurrent session — the
    always-on encoder holds that slot, so a parallel grab from stream1 fails
    with "Operation not permitted" (502 in the editor). The substream accepts
    concurrent sessions, so it is the preview source while the encoder runs.
    It is a clean, unmasked view (the sink's copy already has the mask baked
    in), which is exactly what a mask editor should draw on.

    Known schemes: Uniview /stream1 -> /stream2,
    Dahua realmonitor ...subtype=0 -> ...subtype=1.
    """
    url = cam["source_url"]
    if url.endswith("/stream1"):
        return url[: -len("stream1")] + "stream2"
    if "subtype=0" in url:
        return url.replace("subtype=0", "subtype=1", 1)
    return None


def _grab_one(url, tmp):
    try:
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-rtsp_transport", "tcp", "-timeout", "5000000",
                "-i", url,
                "-frames:v", "1", "-update", "1", "-q:v", "5",
                "-f", "image2", str(tmp),
            ],
            capture_output=True, timeout=15,
        )
    except subprocess.TimeoutExpired:
        pass
    return tmp.exists() and tmp.stat().st_size > 0


_FRAME_CACHE = {}  # name -> (timestamp, path)


@app.get("/api/cameras/<name>/frame")
def grab_frame(name):
    cam = find_cam(name) or abort(404, description="unknown camera")
    if not cam["source_url"]:
        abort(400, description="camera has no source URL configured")

    cached = _FRAME_CACHE.get(name)
    if cached and time.time() - cached[0] < 20 and Path(cached[1]).exists():
        return send_file(cached[1], mimetype="image/jpeg")

    if cached and Path(cached[1]).exists():
        Path(cached[1]).unlink(missing_ok=True)

    # Substream first (works in parallel with the encoder's main session);
    # the main stream still works as a fallback when no encoder holds it.
    candidates = [u for u in (preview_url(cam), cam["source_url"]) if u]
    for url in candidates:
        tmp = Path(tempfile.mktemp(prefix=f"frame_{name}_", suffix=".jpg"))
        if _grab_one(url, tmp):
            _FRAME_CACHE[name] = (time.time(), str(tmp))
            return send_file(str(tmp), mimetype="image/jpeg")
        tmp.unlink(missing_ok=True)
    abort(502, description="could not grab a live frame from the camera")


def _probe_one(url):
    """Return (width, height) of the first video stream at url, or None."""
    try:
        r = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-rtsp_transport", "tcp", "-timeout", "8000000",
                "-i", url,
                "-select_streams", "v:0",
                "-show_entries", "stream=width,height",
                "-of", "csv=p=0",
            ],
            capture_output=True, text=True, timeout=12,
        )
        w, h = r.stdout.strip().split(",")[:2]
        return int(w), int(h)
    except Exception:
        return None


@app.get("/api/cameras/<name>/size")
def probe_size(name):
    cam = find_cam(name) or abort(404, description="unknown camera")
    if not cam["source_url"]:
        abort(400, description="camera has no source URL configured")

    # The mask canvas must be MAIN-stream sized: the encoder places the overlay
    # at 0:0 at its native size (no scaling), so a sub-sized PNG would only
    # cover a corner of the real frame. Read the main size without touching
    # the camera's single main-session slot (held by the encoder):
    #   1. the encoder's own output on the bundled RTSP server (same resolution)
    #   2. the camera's main stream (works while no encoder holds the session)
    if cam["output_url"]:
        wh = _probe_one(cam["output_url"])
        if wh:
            return jsonify(width=wh[0], height=wh[1], source="encoder_output")
    wh = _probe_one(cam["source_url"])
    if wh:
        return jsonify(width=wh[0], height=wh[1], source="camera")
    abort(502, description="could not probe camera size "
           "(neither the encoder output nor the camera main stream was readable)")


class ContainerMissing(Exception):
    """The encoder container exists nowhere on this host (not even stopped)."""


def docker_restart(container, timeout=30):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(DOCKERSOCK)
    conn = http.client.HTTPConnection("docker", timeout=timeout)
    conn.sock = sock
    conn.request("POST", f"/containers/{container}/restart?t=10")
    resp = conn.getresponse()
    body = resp.read().decode("utf-8", "replace")
    if resp.status == 404 and "No such container" in body:
        raise ContainerMissing(container)
    if resp.status >= 300:
        raise RuntimeError(f"docker restart {container} failed: {resp.status} {body}")


@app.post("/api/cameras/<name>/apply")
def apply(name):
    cam = find_cam(name) or abort(404, description="unknown camera")
    try:
        docker_restart(cam["container"])
    except ContainerMissing:
        # Overlay is already saved — this just means the encoder isn't running
        # on THIS host (e.g. a dev box without the GPU). Say exactly that.
        return jsonify(
            ok=True,
            restarted=False,
            message=(f"overlay saved, but encoder container {cam['container']} is not "
                     f"running on this host — start it with: docker compose up -d {cam['name']}"),
        )
    except Exception as exc:
        abort(502, description=str(exc))
    return jsonify(ok=True, restarted=True,
                   message=f"{cam['container']} restarted — stream should be back within a few seconds")


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "80"))
    try:
        from waitress import serve
        serve(app, host="0.0.0.0", port=port, threads=8)
    except ImportError:
        # dev fallback when waitress isn't installed
        app.run(host="0.0.0.0", port=port, threaded=True)
