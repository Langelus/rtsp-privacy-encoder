#!/usr/bin/env python3
"""
RTSP Privacy Encoder — single-container supervisor.

Reads /config/cameras.yaml, keeps one entrypoint.sh subprocess per camera with
full watchdog / backoff / D-state recovery, and serves the mask editor web UI.

No Docker socket needed — camera processes are direct children of this process.
Credentials and camera URLs live only in cameras.yaml, never in the compose file.

Config (environment variables):
  CONFIG_FILE   path to cameras.yaml  (default /config/cameras.yaml)
  OVERLAY_DIR   path to overlay PNGs  (default /overlays)
  ADMIN_PORT    web UI port           (default 8090)
  ADMIN_TOKEN   optional API token; if set /api/* requires X-Admin-Token header
  ENTRYPOINT    path to entrypoint.sh (default /entrypoint.sh)
"""

import io
import logging
import os
import random
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Optional

import yaml
from flask import Flask, abort, jsonify, request, send_file, send_from_directory
from PIL import Image
from werkzeug.exceptions import HTTPException

# ---------------------------------------------------------------- constants --
CONFIG_FILE = Path(os.environ.get("CONFIG_FILE", "/config/cameras.yaml"))
OVERLAY_DIR = Path(os.environ.get("OVERLAY_DIR", "/overlays"))
ADMIN_PORT  = int(os.environ.get("ADMIN_PORT", "8090"))
TOKEN       = os.environ.get("ADMIN_TOKEN", "")
ENTRYPOINT  = Path(os.environ.get("ENTRYPOINT", "/entrypoint.sh"))

INITIAL_DELAY = 2
MAX_DELAY     = 60

# cameras.yaml key → entrypoint.sh environment variable
_YAML_TO_ENV: dict[str, str] = {
    "encode":                  "ENCODE",
    "hwaccel":                 "HWACCEL",
    "overlay_hwaccel":         "OVERLAY_HWACCEL",
    "overlay_vaapi_min_psnr":  "OVERLAY_VAAPI_MIN_PSNR",
    "vaapi_device":            "VAAPI_DEVICE",
    "fps":                     "FPS",
    "gop":                     "GOP",
    "qp":                      "QP",
    "bitrate":                 "BITRATE",
    "maxrate":                 "MAXRATE",
    "bufsize":                 "BUFSIZE",
    "audio_mode":              "AUDIO_MODE",
    "audio_bitrate":           "AUDIO_BITRATE",
    "sub_scale":               "SUB_SCALE",
    "scale":                   "SCALE",
    "overlay_pos":             "OVERLAY_POS",
    "profile":                 "PROFILE",
    "level":                   "LEVEL",
    "b_frames":                "B_FRAMES",
    "watchdog_interval":       "WATCHDOG_INTERVAL",
    "watchdog_fails":          "WATCHDOG_FAILS",
    "preflight":               "PREFLIGHT",
    "max_uptime_hours":        "MAX_UPTIME_HOURS",
}

# Mirrors entrypoint.sh defaults so omitting a key from cameras.yaml is safe.
_ENV_DEFAULTS: dict[str, str] = {
    "ENCODE":                  "vaapi",
    "HWACCEL":                 "auto",
    "OVERLAY_HWACCEL":         "auto",
    "OVERLAY_VAAPI_MIN_PSNR":  "40",
    "VAAPI_DEVICE":            "auto",
    "FPS":                     "auto",
    "GOP":                     "auto",
    "QP":                      "28",
    "BITRATE":                 "",
    "MAXRATE":                 "",
    "BUFSIZE":                 "",
    "AUDIO_MODE":              "aac",
    "AUDIO_BITRATE":           "64k",
    "SUB_SCALE":               "640:-2",
    "SCALE":                   "",
    "OVERLAY_POS":             "0:0",
    "PROFILE":                 "main",
    "LEVEL":                   "auto",
    "B_FRAMES":                "1",
    "WATCHDOG_INTERVAL":       "20",
    "WATCHDOG_FAILS":          "3",
    "PREFLIGHT":               "1",
    "MAX_UPTIME_HOURS":        "0",
    "RESTART_DELAY_INITIAL":   "2",
    "RESTART_DELAY_MAX":       "60",
}

log = logging.getLogger("supervisor")


# ---------------------------------------------------------- CameraManager --
class CameraManager:
    """Keeps one entrypoint.sh subprocess alive for a single camera.

    All mutable state (_cam_cfg, _global_cfg, _proc) is protected by _lock.
    The _run() thread holds _lock only for the brief env-build at each loop
    iteration so concurrent API calls never stall.
    """

    def __init__(self, name: str, cam_cfg: dict, global_cfg: dict) -> None:
        self.name        = name
        self._cam_cfg    = cam_cfg
        self._global_cfg = global_cfg
        self._lock       = threading.Lock()
        self._stop_event = threading.Event()
        self._proc: Optional[subprocess.Popen] = None
        self._thread: Optional[threading.Thread] = None
        self.state         = "stopped"
        self.restart_count = 0
        self.pid: Optional[int] = None
        self._log = logging.getLogger(f"cam.{name}")

    # ---- config helpers (called under self._lock) -------------------------

    def _merged(self) -> dict:
        return {**self._global_cfg, **self._cam_cfg}

    def _build_env(self) -> dict:
        """Build the env dict for entrypoint.sh.  Caller must hold self._lock."""
        cfg = self._merged()
        env: dict[str, str] = {**os.environ, **_ENV_DEFAULTS}

        # Apply every YAML setting that has a corresponding env var.
        # Skip None values (bare "key:" in YAML) so empty-string defaults apply.
        for yaml_key, env_key in _YAML_TO_ENV.items():
            if yaml_key in cfg and cfg[yaml_key] is not None:
                env[env_key] = str(cfg[yaml_key])

        rtsp_base = str(cfg.get("rtsp_server", "rtsp://rtsp-server:8554")).rstrip("/")
        name = self.name

        env["CAMERA_NAME"] = name
        env["SOURCE_URL"]  = str(cfg.get("source_url", ""))
        env["OUTPUT_URL"]  = str(cfg.get("output_url") or f"{rtsp_base}/{name}_masked")
        env["OVERLAY_FILE"] = str(cfg.get("overlay_file") or f"overlay_{name}.png")
        env["OVERLAY_DIR"]  = str(OVERLAY_DIR)

        # Sub stream: only pass the URL if sub_scale is not disabled.
        sub_scale = str(cfg.get("sub_scale", env.get("SUB_SCALE", "640:-2"))).lower()
        if sub_scale not in ("off", "none", ""):
            env["SUB_OUTPUT_URL"] = str(
                cfg.get("sub_output_url") or f"{rtsp_base}/{name}_masked_sub"
            )
        else:
            env["SUB_OUTPUT_URL"] = ""

        return env

    # ---- properties (acquire lock, delegate to _build_env) ---------------

    @property
    def source_url(self) -> str:
        with self._lock:
            return str(self._cam_cfg.get("source_url", ""))

    @property
    def output_url(self) -> str:
        with self._lock:
            return self._build_env()["OUTPUT_URL"]

    @property
    def overlay_file(self) -> str:
        with self._lock:
            cfg = self._merged()
            return str(cfg.get("overlay_file") or f"overlay_{self.name}.png")

    # ---- lifecycle --------------------------------------------------------

    def update_config(self, cam_cfg: dict, global_cfg: dict) -> None:
        with self._lock:
            self._cam_cfg    = cam_cfg
            self._global_cfg = global_cfg

    def start(self) -> None:
        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._run, daemon=True, name=f"cam-{self.name}"
        )
        self._thread.start()

    def _kill_group(self, sig: signal.Signals) -> None:
        with self._lock:
            proc = self._proc
        if proc is None:
            return
        try:
            os.killpg(os.getpgid(proc.pid), sig)
        except (ProcessLookupError, OSError):
            pass

    def stop(self, timeout: float = 15) -> None:
        """Signal stop; SIGTERM the process group; wait; SIGKILL if needed."""
        self._stop_event.set()
        self._kill_group(signal.SIGTERM)
        if self._thread:
            self._thread.join(timeout=timeout)
        self._kill_group(signal.SIGKILL)

    def restart(self) -> None:
        """SIGTERM the running entrypoint.sh; the _run loop restarts it."""
        self._kill_group(signal.SIGTERM)

    # ---- main thread ------------------------------------------------------

    def _run(self) -> None:
        delay = float(INITIAL_DELAY)

        while not self._stop_event.is_set():
            with self._lock:
                env = self._build_env()

            if not env.get("SOURCE_URL"):
                self._log.error(
                    "SOURCE_URL not set in cameras.yaml — skipping (will retry in 30s)"
                )
                self._stop_event.wait(30)
                continue

            self._log.info("starting encoder")
            self.state   = "starting"
            started      = time.monotonic()

            try:
                proc = subprocess.Popen(
                    [str(ENTRYPOINT)],
                    env=env,
                    preexec_fn=os.setsid,   # new process group — SIGTERM/KILL the whole group cleanly
                    stdin=subprocess.DEVNULL,
                )
            except Exception as exc:
                self._log.error("failed to launch %s: %s", ENTRYPOINT, exc)
                self.state = "restarting"
                self._stop_event.wait(delay)
                delay = min(delay * 2, MAX_DELAY)
                continue

            with self._lock:
                self._proc = proc
            self.pid   = proc.pid
            self.state = "running"

            # Block until entrypoint.sh exits for any reason.
            # If ffmpeg enters D-state the watchdog inside entrypoint.sh sends
            # SIGKILL to the bash process (MAIN_PID), which is killable because
            # only ffmpeg is in D-state. The bash process exits, proc.wait()
            # returns here, the D-state ffmpeg becomes an orphan reaped by tini
            # (init: true in compose), and we restart fresh below.
            rc = proc.wait()

            with self._lock:
                self._proc = None
            self.pid = None

            elapsed = time.monotonic() - started

            if self._stop_event.is_set():
                break

            # Long-lived runs reset the backoff (intentional stop/apply, not a crash loop).
            if elapsed >= 60:
                delay = INITIAL_DELAY

            self.restart_count += 1
            jitter = random.randint(0, 2)
            self._log.info(
                "exited rc=%s after %.0fs — restarting in %.0fs",
                rc, elapsed, delay + jitter,
            )
            self.state = "restarting"
            self._stop_event.wait(delay + jitter)
            delay = min(delay * 2, MAX_DELAY)

        self.state = "stopped"

    def status_dict(self) -> dict:
        return {
            "name":          self.name,
            "state":         self.state,
            "restart_count": self.restart_count,
            "pid":           self.pid,
            "overlay_file":  self.overlay_file,
        }


# ------------------------------------------------------------ Supervisor --
class Supervisor:
    """Manages the full set of CameraManagers; hot-reloads cameras.yaml."""

    def __init__(self) -> None:
        self._cameras:    dict[str, CameraManager] = {}
        self._lock        = threading.Lock()
        self._global_cfg: dict = {}

    def load(self, cfg: dict) -> None:
        """Diff old vs new camera list; add/update/remove as needed."""
        cameras_cfg: list[dict] = cfg.get("cameras") or []
        global_cfg  = {k: v for k, v in cfg.items() if k != "cameras"}
        new_by_name = {c["name"]: c for c in cameras_cfg if c.get("name")}

        with self._lock:
            old_names = set(self._cameras.keys())
            self._global_cfg = global_cfg

        # Remove cameras that disappeared from the config.
        for name in old_names - new_by_name.keys():
            with self._lock:
                mgr = self._cameras.pop(name, None)
            if mgr:
                log.info("removing camera %s", name)
                mgr.stop()

        # Add new cameras; update existing ones.
        for name, cam_cfg in new_by_name.items():
            with self._lock:
                existing = self._cameras.get(name)
            if existing:
                existing.update_config(cam_cfg, global_cfg)
                log.debug("updated config for camera %s", name)
            else:
                mgr = CameraManager(name, cam_cfg, global_cfg)
                with self._lock:
                    self._cameras[name] = mgr
                log.info("adding camera %s", name)
                mgr.start()

    def get(self, name: str) -> Optional[CameraManager]:
        with self._lock:
            return self._cameras.get(name)

    def all(self) -> list[CameraManager]:
        with self._lock:
            return list(self._cameras.values())

    def stop_all(self, timeout: float = 15) -> None:
        with self._lock:
            mgrs = list(self._cameras.values())
        for mgr in mgrs:
            mgr._stop_event.set()
            mgr._kill_group(signal.SIGTERM)
        deadline = time.monotonic() + timeout
        for mgr in mgrs:
            remaining = max(0.0, deadline - time.monotonic())
            if mgr._thread:
                mgr._thread.join(timeout=remaining)
        for mgr in mgrs:
            mgr._kill_group(signal.SIGKILL)


# -------------------------------------------------------- config watcher --
def _watch_config(supervisor: Supervisor, path: Path) -> None:
    last_mtime: Optional[float] = None
    wlog = logging.getLogger("config")
    while True:
        try:
            mtime = path.stat().st_mtime
            if mtime != last_mtime:
                last_mtime = mtime
                with open(path) as f:
                    cfg = yaml.safe_load(f) or {}
                supervisor.load(cfg)
                wlog.info("reloaded %s", path)
        except FileNotFoundError:
            pass
        except Exception as exc:
            wlog.warning("reload failed: %s", exc)
        time.sleep(5)


# -------------------------------------------------------------- Flask app --
_supervisor: Optional[Supervisor] = None
_FRAME_CACHE: dict[str, tuple] = {}   # name -> (timestamp, path)

app = Flask(__name__, static_folder="/app/static", static_url_path="/")


def _check_token() -> None:
    if not TOKEN:
        return
    if request.path == "/api/health":
        return
    if not request.path.startswith("/api/"):
        return
    if request.headers.get("X-Admin-Token") != TOKEN:
        abort(401, description="missing or invalid X-Admin-Token header")


@app.before_request
def _auth() -> None:
    _check_token()


@app.errorhandler(HTTPException)
def _http_error(exc: HTTPException):
    return jsonify(error=exc.description or exc.name), exc.code


@app.errorhandler(Exception)
def _unhandled_error(exc: Exception):
    app.logger.exception("unhandled exception")
    return jsonify(error=f"internal error: {exc}"), 500


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/health")
def health():
    return jsonify(ok=True)


@app.get("/api/cameras")
def api_cameras():
    result = []
    for mgr in _supervisor.all():
        overlay_file = mgr.overlay_file
        png  = OVERLAY_DIR / overlay_file
        info = {
            "name":             mgr.name,
            "state":            mgr.state,
            "overlay_file":     overlay_file,
            "has_overlay":      png.exists(),
            "overlay_px":       None,
            "has_frame_source": bool(mgr.source_url),
        }
        if png.exists():
            try:
                with Image.open(png) as im:
                    info["overlay_px"] = {"w": im.width, "h": im.height}
            except Exception:
                pass
        result.append(info)
    return jsonify(result)


def _find_mgr(name: str) -> CameraManager:
    mgr = _supervisor.get(name)
    if mgr is None:
        abort(404, description="unknown camera")
    return mgr


@app.get("/api/cameras/<name>/overlay")
def get_overlay(name: str):
    mgr  = _find_mgr(name)
    path = OVERLAY_DIR / mgr.overlay_file
    if not path.exists():
        abort(404, description=f"no overlay for {name} yet")
    return send_file(path, mimetype="image/png")


@app.post("/api/cameras/<name>/overlay")
def save_overlay(name: str):
    mgr  = _find_mgr(name)
    data = request.get_data()
    if len(data) > 64 * 1024 * 1024:
        abort(413, description="overlay too large (max 64 MiB)")
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.load()
            w, h = im.size
    except Exception as exc:
        abort(400, description=f"body is not a valid image: {exc}")
    if w > 8192 or h > 8192:
        abort(400, description="overlay too large (max 8192×8192)")

    buf = io.BytesIO()
    with Image.open(io.BytesIO(data)) as im:
        im.convert("RGBA").save(buf, format="PNG")

    target = OVERLAY_DIR / mgr.overlay_file
    tmp    = target.with_name(target.name + ".tmp")
    tmp.write_bytes(buf.getvalue())
    os.replace(tmp, target)   # atomic: encoder always sees a complete file
    return jsonify(ok=True, width=w, height=h, saved=str(target))


def _preview_url(source_url: str) -> Optional[str]:
    """Derive the camera's substream URL from its main-stream URL.

    The cameras cap the MAIN stream at one concurrent session (the encoder
    holds it). The substream accepts parallel sessions and is safe to grab
    for editor previews.  Known schemes: Uniview /stream1→/stream2,
    Dahua realmonitor subtype=0→subtype=1.
    """
    if source_url.endswith("/stream1"):
        return source_url[: -len("stream1")] + "stream2"
    if "subtype=0" in source_url:
        return source_url.replace("subtype=0", "subtype=1", 1)
    return None


def _grab_one(url: str, tmp: Path) -> bool:
    try:
        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error",
                "-rtsp_transport", "tcp", "-timeout", "5000000",
                "-i", url,
                "-frames:v", "1", "-update", "1", "-q:v", "5",
                "-f", "image2", str(tmp),
            ],
            capture_output=True,
            timeout=15,
        )
    except subprocess.TimeoutExpired:
        pass
    return tmp.exists() and tmp.stat().st_size > 0


@app.get("/api/cameras/<name>/frame")
def grab_frame(name: str):
    mgr        = _find_mgr(name)
    source_url = mgr.source_url
    if not source_url:
        abort(400, description="camera has no source URL configured")

    cached = _FRAME_CACHE.get(name)
    if cached and time.time() - cached[0] < 20 and Path(cached[1]).exists():
        return send_file(cached[1], mimetype="image/jpeg")
    if cached and Path(cached[1]).exists():
        Path(cached[1]).unlink(missing_ok=True)

    candidates = [u for u in (_preview_url(source_url), source_url) if u]
    for url in candidates:
        tmp = Path(tempfile.mktemp(prefix=f"frame_{name}_", suffix=".jpg"))
        if _grab_one(url, tmp):
            _FRAME_CACHE[name] = (time.time(), str(tmp))
            return send_file(str(tmp), mimetype="image/jpeg")
        tmp.unlink(missing_ok=True)
    abort(502, description="could not grab a live frame from the camera")


def _probe_one(url: str) -> Optional[tuple[int, int]]:
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
            capture_output=True,
            text=True,
            timeout=12,
        )
        w, h = r.stdout.strip().split(",")[:2]
        return int(w), int(h)
    except Exception:
        return None


@app.get("/api/cameras/<name>/size")
def probe_size(name: str):
    mgr        = _find_mgr(name)
    source_url = mgr.source_url
    if not source_url:
        abort(400, description="camera has no source URL configured")

    # Prefer the encoder's own output (same resolution as the main stream,
    # but readable while the encoder holds the camera's single main session).
    out_url = mgr.output_url
    if out_url:
        wh = _probe_one(out_url)
        if wh:
            return jsonify(width=wh[0], height=wh[1], source="encoder_output")

    wh = _probe_one(source_url)
    if wh:
        return jsonify(width=wh[0], height=wh[1], source="camera")
    abort(
        502,
        description=(
            "could not probe camera size "
            "(neither the encoder output nor the camera main stream was readable)"
        ),
    )


@app.post("/api/cameras/<name>/apply")
def apply(name: str):
    mgr = _find_mgr(name)
    mgr.restart()
    return jsonify(
        ok=True,
        restarted=True,
        message=f"{name} encoder restarted — stream should be back within a few seconds",
    )


# ------------------------------------------------------------------- main --
def main() -> None:
    global _supervisor

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(name)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )

    if not ENTRYPOINT.exists():
        log.error("entrypoint not found: %s — cannot start", ENTRYPOINT)
        sys.exit(1)

    OVERLAY_DIR.mkdir(parents=True, exist_ok=True)

    _supervisor = Supervisor()

    if CONFIG_FILE.exists():
        try:
            with open(CONFIG_FILE) as f:
                cfg = yaml.safe_load(f) or {}
            _supervisor.load(cfg)
        except Exception as exc:
            log.error("failed to load %s: %s", CONFIG_FILE, exc)
    else:
        log.warning(
            "config file not found: %s — mount cameras.yaml and it will be picked up within 5s",
            CONFIG_FILE,
        )

    threading.Thread(
        target=_watch_config,
        args=(_supervisor, CONFIG_FILE),
        daemon=True,
        name="config-watcher",
    ).start()

    stop_event = threading.Event()

    def _handle_signal(sig: int, _frame) -> None:
        log.info("received signal %d — initiating shutdown", sig)
        stop_event.set()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT,  _handle_signal)

    def _run_web() -> None:
        try:
            from waitress import serve
            log.info("web UI listening on :%d (waitress)", ADMIN_PORT)
            serve(app, host="0.0.0.0", port=ADMIN_PORT, threads=8)
        except ImportError:
            log.info("web UI listening on :%d (flask dev server)", ADMIN_PORT)
            app.run(host="0.0.0.0", port=ADMIN_PORT, threaded=True)

    threading.Thread(target=_run_web, daemon=True, name="web").start()

    log.info(
        "supervisor ready — cameras: %d, web: :%d, config: %s",
        len(_supervisor.all()), ADMIN_PORT, CONFIG_FILE,
    )

    stop_event.wait()

    log.info("shutting down all cameras…")
    _supervisor.stop_all(timeout=15)
    log.info("shutdown complete")
    sys.exit(0)


if __name__ == "__main__":
    main()
