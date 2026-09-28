# RTSP Privacy Encoder

This is just a small personal project I created for myself as the NVR I'm using lacks the feature but decided to share it as it seems to be a widespread problem for countries with GDRP regulation prohibiting monitoring of areas considered public places (i.e. pavements etc).

The system puts a **privacy mask** over RTSP camera streams and re-encodes them to H.264 — GPU-accelerated with AMD/Intel VAAPI or NVIDIA NVENC. A browser-based editor lets you draw and edit masks over a live camera frame without touching the server.

This has been tested Intel/AMD through VAAPI encoder as well as Nvidia NVEC with TP-Link and Dahua cameras - as there's a infinite amount of combinations for hardware, cameras and settings this is free for you to play around with and no specific support is given.

Example performance during my testing with 3 streams at 2560x1440 and 1 stream at 4K:

Intel N100 mini PC:  around 40-50% CPU with a load average around 2

When tested were conducted on more capable systems the load was so small it was indistinguishable. 
If figures are way off, take a look so that the hardware offload is working on the system and it's not using CPU to encode/decode.

As the encoder needs a sink to push to - the excellent MediaMTX docker (https://github.com/bluenviron/mediamtx) is in the compose file but you may push to whatever RTSP sink you want/have.


```
camera ──RTSP──> [ encoder: overlay + H.264 ] ──push──> [ rtsp-server ] ──pull──>  NVR system
                       ▲                                   (bundled)
                  web editor UI
```

All cameras are managed from a single `cameras.yaml` file; no rebuild or compose edit is needed to add or remove a camera.

## Requirements

- Docker + Docker Compose
- One of:
  - **AMD iGPU / Intel QuickSync** — `/dev/dri` passed to the container (default)
  - **NVIDIA GPU** — [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed, use `Dockerfile.nvidia`
  - **No GPU** — set `encode: x264` in `cameras.yaml` for software encoding

## Quick start

**1. Clone and copy the example config:**
```bash
git clone <repo-url>
cd rtsp-privacy-encoder
cp cameras.yaml.example cameras.yaml
```

**2. Edit `cameras.yaml` — fill in your real camera URLs:**
```yaml
encode: vaapi       # vaapi | nvenc | x264

cameras:
  - name: front_door
    source_url: "rtsp://user:password@192.168.1.10/stream1"

  - name: backyard
    source_url: "rtsp://user:password@192.168.1.11/stream1"
```

Camera credentials live **only** in `cameras.yaml`

**3. Build and start:**
```bash
docker compose up -d --build
```

**4. Open the editor** at `http://<host>:8090`

Draw a mask over the live camera frame, then click **Save & Apply**. The masked stream is live within a few seconds at:
```
rtsp://<host>:8554/<camera-name>_masked
rtsp://<host>:8554/<camera-name>_masked_sub   # 640px-wide copy for NVR detect streams
```

## Web editor

| Tool | What it does |
|------|-------------|
| Rectangle / Line / Brush / Fill | Draw opaque mask regions |
| Eraser | Remove mask paint |
| Undo | Up to 25 steps |
| Upload | Load a PNG as a starting mask |
| Download | Save the current mask as a PNG |
| Save & Apply | Write the mask to disk and restart that camera's encoder |

The canvas is sized to the camera's native resolution. The live preview is fetched from the camera's substream (Uniview `/stream2`, Dahua `subtype=1`) so the encoder's hold on the main stream is never interrupted.

## cameras.yaml reference

Global settings apply to every camera. Any setting can be overridden per camera.

```yaml
# ── Encoder ─────────────────────────────────────────────────────────────────
encode: vaapi           # vaapi (AMD/Intel) | nvenc (NVIDIA) | x264 (CPU)
hwaccel: auto           # auto | vaapi | cuda | none — where decode runs
overlay_hwaccel: auto   # auto | vaapi | off  — GPU overlay compositor (VAAPI only)
vaapi_device: auto      # auto | renderD128 | /dev/dri/renderD128

# ── Quality ──────────────────────────────────────────────────────────────────
qp: 28                  # constant-QP quality (0=lossless, 51=worst); used when bitrate is empty
# bitrate: 2M           # switch to VBR; also set maxrate/bufsize if desired
# maxrate: 3M
# bufsize: 6M

# ── Frame rate / keyframes ───────────────────────────────────────────────────
fps: auto               # auto = probe the camera; or pin e.g. 15
gop: auto               # auto = 4×fps clamped to 30–120; or pin e.g. 60

# ── H.264 profile ────────────────────────────────────────────────────────────
profile: main           # main | high | baseline
level: auto
b_frames: 1

# ── Audio ────────────────────────────────────────────────────────────────────
audio_mode: aac         # aac | copy | none
audio_bitrate: 64k

# ── Sub stream (low-res copy for Frigate detect) ─────────────────────────────
sub_scale: "640:-2"     # W:H (-2 keeps aspect ratio); "off" to disable

# ── Stability ────────────────────────────────────────────────────────────────
watchdog_interval: 20   # seconds between output-stream probes
watchdog_fails: 3       # failed probes before force-kill
max_uptime_hours: 0     # 0 = off; set e.g. 8 for AMD iGPU (prevents VAAPI D-state hangs)

# ── RTSP relay (the bundled mediamtx service) ────────────────────────────────
rtsp_server: "rtsp://rtsp-server:8554"

cameras:
  - name: front_door
    source_url: "rtsp://user:pass@192.168.1.10/stream1"
    # Any global setting can be overridden here, e.g.:
    # qp: 24
    # max_uptime_hours: 8

  # Dahua cameras use subtype=0 for the main stream
  - name: backyard
    source_url: "rtsp://user:pass@192.168.1.11/cam/realmonitor?channel=1&subtype=0"
```

Hot-reload: the supervisor picks up any change to `cameras.yaml` within 5 seconds — no restart needed to add or remove a camera.

## GPU options

### AMD iGPU / Intel QuickSync (VAAPI) — default

No changes needed. The `/dev/dri` device is passed through in `docker-compose.yml`.

```yaml
# cameras.yaml
encode: vaapi
hwaccel: auto
```

Set `max_uptime_hours: 8` on AMD iGPU to prevent rare kernel-level VAAPI hangs after many hours of continuous use.

### NVIDIA NVENC

1. Install the [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) on the host.

2. In `docker-compose.yml`, switch the build and replace the `devices` block with the `deploy` block (both are shown as comments in the file).

3. Build with the NVIDIA Dockerfile:
   ```bash
   docker compose build --build-arg DOCKERFILE=Dockerfile.nvidia
   ```
   Or edit `docker-compose.yml` to set `dockerfile: Dockerfile.nvidia`.

4. In `cameras.yaml`:
   ```yaml
   encode: nvenc
   hwaccel: auto   # or: cuda to force GPU decode
   ```

### Software (x264 / CPU)

No GPU or special setup needed:

```yaml
# cameras.yaml
encode: x264
hwaccel: none
```

## Example of Frigate integration

Point Frigate at the masked streams — as you use both the main recording stream and detect stream here, privacy will not be an issue:

```yaml
cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://<host>:8554/front_door_masked
          roles: [record]
        - path: rtsp://<host>:8554/front_door_masked_sub
          roles: [detect]
    detect:
      width: 640
      height: 360
      fps: 5
```

## Optional settings

| Environment variable | Default | Description |
|---------------------|---------|-------------|
| `ADMIN_TOKEN` | empty | If set, all `/api/*` calls require `X-Admin-Token: <token>` header |
| `ADMIN_PORT` | `8090` | Web UI port (set in `docker-compose.yml`) |
| `RTSP_PORT` | `8554` | RTSP relay port (set in `docker-compose.yml`) |

Set `ADMIN_TOKEN` in `docker-compose.yml` (or a `.env` file) to secure the webinterface (optional).

## Security notes

- `/api/health` is always open even when a token is set (used by the container's own healthcheck).
- This docker is NOT intended to be exposed to the internet, it's only meant to be running locally alongside the NVR system in a controlled network.

## License

MIT — see [LICENSE](LICENSE).
