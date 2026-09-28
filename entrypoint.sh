#!/bin/bash
#
# RTSP privacy-mask encoder — container entrypoint.
#
# Keeps one camera stream alive, forever:
#   camera RTSP -> overlay (privacy mask) -> H.264 via VAAPI (iGPU) -> RTSP push
#
#   - restarts ffmpeg on any failure with capped exponential backoff + jitter
#   - watchdog: if the *pushed* stream stops being readable while ffmpeg is
#     still alive (zombie encoder, RTSP server died, half-dead connection),
#     the watchdog force-kills ffmpeg so the supervisor loop restarts it.
#     Docker's healthcheck only *reports* — the watchdog is what self-heals.
#   - auto-detects the VAAPI render node (renderD128 first, then first
#     renderD*) unless you pin one via VAAPI_DEVICE
#   - runs a short test encode at startup so a broken VAAPI driver announces
#     itself immediately instead of being discovered a hundred times over
#   - shuts ffmpeg down cleanly on SIGTERM (docker stop / restart)
#
# All configuration is via environment variables (defaults below, see README.md).

set -euo pipefail

# ---------------------------------------------------------------- settings --
: "${CAMERA_NAME:=camera}"
: "${SOURCE_URL:?SOURCE_URL is required: rtsp://user:pass@host/stream1}"
: "${OUTPUT_URL:?OUTPUT_URL is required: rtsp://host:8554/streamname}"
: "${OVERLAY_FILE:=overlay.png}"

# Overlay placement (ffmpeg overlay filter x:y expression).
#   "0:0"               -> overlay PNG is full-frame sized (from the web editor)
#   "W-w-10:H-h-10"     -> small overlay PNG anchored 10px from bottom-right
#                          (legacy behaviour)
: "${OVERLAY_POS:=W-w-10:H-h-10}"

# Optional downscale of the source before overlay/encode, e.g. "1920:1080":
# cuts encode work, bandwidth and downstream decode. Empty = native resolution.
: "${SCALE:=}"

# Encoding (defaults mirror the legacy setup)
: "${FPS:=auto}"      # auto (default) = probe the camera's native rate (cameras differ: 15, 25, ...);
                      # or pin a value, e.g. 15 or 30000/1001
: "${GOP:=auto}"      # auto (default) = 4x the final FPS (clamped 30..120); or pin a value, e.g. 60
: "${B_FRAMES:=1}"
: "${PROFILE:=main}"
# auto (default) = let the encoder pick the lowest level that fits the stream
# (1440p@15fps -> 5.0, 4K@15fps -> 5.1). The old pinned "4.0" default made
# x264 print "frame MB size / DPB size / MB rate > level limit" warnings for
# every camera (1440p AND 4K exceed it) and tagged the SPS below what the
# stream actually carries. Pin a value (e.g. "5.1") to force a level.
: "${LEVEL:=auto}"
: "${QP:=28}"            # constant-QP mode (used when BITRATE is empty)
: "${BITRATE:=}"         # e.g. "2M" -> switches the encoder to VBR
: "${MAXRATE:=}"         # e.g. "3M" (VBR mode only)
: "${BUFSIZE:=}"         # e.g. "6M" (VBR mode only)
: "${AUDIO_MODE:=aac}"   # copy | aac | none
: "${AUDIO_BITRATE:=64k}"  # aac mode only

# Optional second, low-resolution copy of the SAME masked picture (e.g. for
# Frigate's detect role), pushed to SUB_OUTPUT_URL by the same ffmpeg — the
# cameras allow one main-stream session, so it can't be a separate process.
: "${SUB_OUTPUT_URL:=}"      # empty = no sub stream
: "${SUB_SCALE:=640:-2}"     # W:H; H of -1/-2 = keep the camera's aspect ratio; off = no sub stream

# (Defined before the validation cases below — their error paths call log().)
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$CAMERA_NAME" "$*"; }
mask_url() { printf '%s\n' "${1:-}" | sed -E 's#(rtsp://)[^:@/]+:[^:@/]+@#\1user:****@#'; }

# Encoder selection.
#   vaapi (default) -> GPU H.264 encode via VAAPI (AMD iGPU / Intel QuickSync)
#   x264            -> software fallback: dev boxes without a GPU, or rescue
#                      when the GPU/driver is unavailable. Slower and CPU-bound.
: "${ENCODE:=vaapi}"
case "$ENCODE" in
    vaapi|nvenc|x264) ;;
    *) log "ERROR: ENCODE must be 'vaapi', 'nvenc' or 'x264' (got '$ENCODE')"; exit 1 ;;
esac

# Decode — where the real CPU cost of high-res/HEVC sources lives (a 4K HEVC
# source decoded in software eats several cores).
#   auto (default) -> when ENCODE=vaapi: verify the GPU can decode the source
#                     at startup; if it can't, fall back to software decode
#   vaapi          -> force GPU decode; exit if the GPU can't decode the source
#   none           -> always software decode (CPU)
: "${HWACCEL:=auto}"
case "$HWACCEL" in
    auto|vaapi|cuda|none) ;;
    *) log "ERROR: HWACCEL must be 'auto', 'vaapi', 'cuda' or 'none' (got '$HWACCEL')"; exit 1 ;;
esac
if [ "$ENCODE" = "vaapi" ] && [ "$HWACCEL" = "cuda" ]; then
    log "ERROR: HWACCEL=cuda requires ENCODE=nvenc"; exit 1
fi
if [ "$ENCODE" = "nvenc" ] && [ "$HWACCEL" = "vaapi" ]; then
    log "ERROR: HWACCEL=vaapi requires ENCODE=vaapi"; exit 1
fi

# GPU overlay — when GPU decode is active, use overlay_vaapi so frames never
# leave the GPU for compositing (no hwdownload/hwupload roundtrip for video).
#   auto (default) -> pixel-check overlay_vaapi against the CPU overlay at
#                     startup; use it only if its output is correct
#   vaapi          -> force GPU overlay without the check
#   off            -> always composite on CPU
# Only applies when ENCODE=vaapi AND GPU decode is active AND OVERLAY_POS=0:0.
: "${OVERLAY_HWACCEL:=auto}"
case "$OVERLAY_HWACCEL" in
    auto|vaapi|off) ;;
    *) log "ERROR: OVERLAY_HWACCEL must be 'auto', 'vaapi', or 'off' (got '$OVERLAY_HWACCEL')"; exit 1 ;;
esac
# Minimum PSNR (dB) of the GPU overlay vs the CPU overlay outside the mask.
# Correct output scores >= ~47; garbled colours (range mix-up) score ~33.
: "${OVERLAY_VAAPI_MIN_PSNR:=40}"

# VAAPI render node.
#   auto (default)   -> renderD128 if present, else the first renderD* node
#   renderD129 etc.  -> pinned; the container exits if it is missing
#   /abs/path        -> used as-is (advanced / testing)
VAAPI_DEVICE="${VAAPI_DEVICE:-auto}"

# Watchdog: every WATCHDOG_INTERVAL seconds, try to read OUTPUT_URL.
# WATCHDOG_FAILS consecutive failed reads with ffmpeg still alive -> kill it
# so the supervisor loop restarts it.
: "${WATCHDOG_INTERVAL:=20}"
: "${WATCHDOG_FAILS:=3}"

# Startup self-test: encode 1s of testsrc with the VAAPI encoder.
# Log-only — a failure does not block startup (the loop will retry anyway),
# but it turns "driver missing" into one loud line instead of a retry storm.
: "${PREFLIGHT:=1}"
: "${PREFLIGHT_TIMEOUT:=20}"

# Resilience
: "${RESTART_DELAY_INITIAL:=2}"
: "${RESTART_DELAY_MAX:=60}"
: "${MAX_UPTIME_HOURS:=0}"  # 0 = off; otherwise restart after one run lasts this long

OVERLAY_PATH="/overlays/${OVERLAY_FILE}"
PID_FILE="/tmp/encoder-ffmpeg.pid"   # lets the watchdog subshell see the live pid

# ------------------------------------------------------------------ checks --
[ -f "$OVERLAY_PATH" ] || { log "ERROR: overlay file missing: $OVERLAY_PATH"; exit 1; }

VAAPI_PATH=""
if [ "$ENCODE" = "x264" ]; then
    log "encode mode: software (libx264) — no GPU needed"
elif [ "$ENCODE" = "nvenc" ]; then
    log "encode mode: hardware (h264_nvenc, NVIDIA NVENC) — VAAPI not used"
elif [ "$VAAPI_DEVICE" = "auto" ]; then
    if [ -e /dev/dri/renderD128 ]; then
        VAAPI_DEVICE="renderD128"
    else
        first=$(ls /dev/dri 2>/dev/null | grep -E '^renderD[0-9]+$' | sed 's/^renderD//' | sort -n | head -n 1 || true)
        [ -n "$first" ] || { log "ERROR: no VAAPI render node found under /dev/dri — is /dev/dri passed to the container? (or set VAAPI_DEVICE)"; exit 1; }
        VAAPI_DEVICE="renderD$first"
        log "auto-detected VAAPI device: $VAAPI_DEVICE"
    fi
fi
if [ "$ENCODE" = "vaapi" ]; then
case "$VAAPI_DEVICE" in
    /*) VAAPI_PATH="$VAAPI_DEVICE" ;;
    *)  VAAPI_PATH="/dev/dri/${VAAPI_DEVICE}" ;;
esac
[ -e "$VAAPI_PATH" ] || { log "ERROR: VAAPI device missing: $VAAPI_PATH (pass /dev/dri into the container, or set VAAPI_DEVICE)"; exit 1; }
fi

# ----------------------------------------------------------- mask analysis --
# The mask never changes while we run, so it is analysed ONCE here: find the
# bounding box of its non-transparent pixels. Only that box is composited per
# frame (masks typically cover 3-35% of the frame), and a fully transparent
# mask needs no compositing at all. Fails closed: a mask we cannot read stops
# the container instead of being mistaken for "nothing to hide".
MASK_EMPTY=""
MASK_PRE=""              # filter chain that crops the mask input to its box
MASK_LBL="[1:v]"         # graph label of the (possibly cropped) mask
MASK_XY="$OVERLAY_POS"   # where the (possibly cropped) mask is placed
MASK_NOTE="positioned at $OVERLAY_POS"
if [ "$OVERLAY_POS" = "0:0" ]; then
    MASK_DIM=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height \
               -of csv=p=0:s=x "$OVERLAY_PATH" 2>/dev/null || true)
    MASK_W=${MASK_DIM%x*}; MASK_H=${MASK_DIM#*x}
    if ! [[ "$MASK_W" =~ ^[0-9]+$ && "$MASK_H" =~ ^[0-9]+$ ]]; then
        log "ERROR: cannot read the size of overlay mask $OVERLAY_PATH (got '${MASK_DIM}')"
        exit 1
    fi
    if ! BBOX_OUT=$(ffmpeg -hide_banner -nostats -nostdin -i "$OVERLAY_PATH" \
            -vf "format=rgba,alphaextract,bbox=min_val=0" -f null - </dev/null 2>&1); then
        log "ERROR: cannot analyse overlay mask $OVERLAY_PATH ($(printf '%s' "$BBOX_OUT" | tail -n 1))"
        exit 1
    fi
    bbox=$(printf '%s\n' "$BBOX_OUT" | grep -o 'x1:[0-9]* x2:[0-9]* y1:[0-9]* y2:[0-9]*' | head -n 1 || true)
    if [ -z "$bbox" ]; then
        MASK_EMPTY=1
    else
        read -r bx1 bx2 by1 by2 <<< "$(printf '%s' "$bbox" | sed -E 's/[xy][12]://g')"
        # Even box edges keep the 4:2:0 chroma planes aligned.
        mx=$(( bx1 & ~1 )); my=$(( by1 & ~1 ))
        ex=$(( (bx2 + 2) & ~1 )); ey=$(( (by2 + 2) & ~1 ))
        if [ "$ex" -gt "$MASK_W" ]; then ex=$MASK_W; fi
        if [ "$ey" -gt "$MASK_H" ]; then ey=$MASK_H; fi
    fi
fi

# ------------------------------------------------- VAAPI decode (hwaccel) --
# If we encode on the GPU, let it DECODE too. With overlay_vaapi (see below),
# frames stay on the GPU the entire time. Without it, they briefly visit CPU
# for the overlay blend (hwdownload → CPU overlay → hwupload) then return.
# auto = a 1s test read verifies the GPU can decode THIS source (profile/level
# support varies per chip) and falls back to software decode if it can't.
HWACCEL_USE=""
if [ "$ENCODE" = "vaapi" ] && [ "$HWACCEL" != "none" ]; then
    # stderr is captured (not discarded) so a failure says WHY — same rule as
    # the watchdog's "probe said:" logs.
    # hwdownload makes the test fail when ffmpeg silently falls back to
    # software decoding (it does that when the GPU rejects the stream's
    # profile) — without it the test passed on CPU-decoded frames.
    if HW_TEST_ERR=$(timeout 10 ffmpeg -hide_banner -loglevel error -nostdin \
            -rtsp_transport tcp -timeout 5000000 \
            -hwaccel vaapi -hwaccel_device "$VAAPI_PATH" -hwaccel_output_format vaapi \
            -t 1 -i "$SOURCE_URL" -map 0:v:0 -vf hwdownload,format=nv12 -f null - \
            </dev/null 2>&1 >/dev/null); then
        HWACCEL_USE=1
        log "hwaccel: GPU decode of source verified (VAAPI on $VAAPI_DEVICE)"
    else
        hw_test_line=$(printf '%s' "${HW_TEST_ERR:-}" | tail -n 1)
        if [ "$HWACCEL" = "vaapi" ]; then
            log "ERROR: VAAPI decode of source failed (${hw_test_line:-timed out}) — unsupported profile/level, or camera unreachable?"
            exit 1
        fi
        log "hwaccel: GPU decode test failed (${hw_test_line:-timed out}) — falling back to software decode (CPU)"
    fi
elif [ "$ENCODE" = "nvenc" ] && [ "$HWACCEL" != "none" ]; then
    # -hwaccel_output_format cuda ensures the test actually uses the GPU;
    # without it ffmpeg silently falls back to CPU when the GPU rejects the profile.
    if HW_TEST_ERR=$(timeout 10 ffmpeg -hide_banner -loglevel error -nostdin \
            -rtsp_transport tcp -timeout 5000000 \
            -hwaccel cuda -hwaccel_output_format cuda \
            -t 1 -i "$SOURCE_URL" -map 0:v:0 -vf hwdownload,format=nv12 -f null - \
            </dev/null 2>&1 >/dev/null); then
        HWACCEL_USE=1
        log "hwaccel: GPU decode of source verified (CUDA/cuvid)"
    else
        hw_test_line=$(printf '%s' "${HW_TEST_ERR:-}" | tail -n 1)
        if [ "$HWACCEL" = "cuda" ]; then
            log "ERROR: CUDA decode of source failed (${hw_test_line:-timed out}) — unsupported format, or no NVIDIA GPU visible in the container?"
            exit 1
        fi
        log "hwaccel: CUDA decode test failed (${hw_test_line:-timed out}) — falling back to software decode (CPU)"
    fi
fi

# ------------------------------------------------------------ source probe --
# One ffprobe of the camera for everything needed below — the cameras allow a
# single main-stream session, so don't open more than necessary: frame rate
# (FPS=auto), frame size (mask sanity check) and colour tags (GPU overlay).
SRC_PROBE=$(timeout 10 ffprobe -v error -rw_timeout 5000000 -rtsp_transport tcp \
           -select_streams v:0 \
           -show_entries stream=avg_frame_rate,width,height,color_range,color_space,color_primaries,color_transfer \
           -of default=noprint_wrappers=1 "$SOURCE_URL" 2>/dev/null || true)
src_prop() { printf '%s\n' "$SRC_PROBE" | sed -n "s/^$1=//p" | head -n 1; }
SRC_W=$(src_prop width); SRC_H=$(src_prop height)

# ------------------------------------------------------- mask finalisation --
if [ "$OVERLAY_POS" = "0:0" ] && [ -z "$MASK_EMPTY" ]; then
    if [[ "$SRC_W" =~ ^[0-9]+$ && "$SRC_H" =~ ^[0-9]+$ ]]; then
        if [ "$SRC_W" != "$MASK_W" ] || [ "$SRC_H" != "$MASK_H" ]; then
            log "WARNING: mask is ${MASK_W}x${MASK_H} but the camera sends ${SRC_W}x${SRC_H} — the mask is placed unscaled at 0:0, so masked areas are MISPLACED. Redraw the mask in the editor."
        fi
        # The part of the box outside the camera frame can't hide anything.
        if [ "$ex" -gt "$SRC_W" ]; then ex=$(( SRC_W & ~1 )); fi
        if [ "$ey" -gt "$SRC_H" ]; then ey=$(( SRC_H & ~1 )); fi
    fi
    if [ "$ex" -le "$mx" ] || [ "$ey" -le "$my" ]; then
        MASK_EMPTY=1
        MASK_NOTE="opaque region lies entirely outside the ${SRC_W}x${SRC_H} camera frame — nothing to hide, compositing skipped"
    else
        mw=$(( ex - mx )); mh=$(( ey - my ))
        # lutrgb: every painted pixel becomes fully opaque, so a mask saved
        # semi-transparent (older editor versions had an opacity slider) can't
        # leave the scene visible. Runs once — the mask is a single frame.
        MASK_PRE="[1:v]crop=${mw}:${mh}:${mx}:${my},format=rgba,lutrgb=a='gt(val,0)*255'[mk];"
        MASK_LBL="[mk]"
        MASK_XY="${mx}:${my}"
        MASK_NOTE="opaque region ${mw}x${mh} at ${mx},${my} ($(( mw * mh * 100 / (MASK_W * MASK_H) ))% of ${MASK_W}x${MASK_H}) — only this area is composited"
    fi
elif [ -n "$MASK_EMPTY" ]; then
    MASK_NOTE="fully transparent — nothing to hide, compositing skipped"
fi
log "mask: $MASK_NOTE"

# ----------------------------------------- GPU overlay (overlay_vaapi) --
# When GPU decode is active the mask can be composited on the GPU too, so
# video frames never visit the CPU.
# Requires: ENCODE=vaapi + HWACCEL_USE (GPU decode verified) + OVERLAY_POS=0:0.
#
# The compositor converts colours using the frames' colour tags. IP cameras
# often leave them unset and the driver then guesses, so they are pinned: the
# camera's declared values where valid, else limited-range BT.709 (the IP
# camera norm). Same tags in and out = camera pixels pass through unchanged.
OVERLAY_VAAPI_USE=""
SRC_TAGS=""
if [ -n "$HWACCEL_USE" ] && [ "$ENCODE" = "vaapi" ] && [ "$OVERLAY_HWACCEL" != "off" ] \
        && [ "$OVERLAY_POS" = "0:0" ] && [ -z "$MASK_EMPTY" ]; then
    r_range=$(src_prop color_range); r_space=$(src_prop color_space)
    r_prim=$(src_prop color_primaries); r_trc=$(src_prop color_transfer)
    case "$r_range" in pc) c_range=pc ;; *) c_range=tv ;; esac
    case "$r_space" in bt709|smpte170m|bt470bg|smpte240m) c_space=$r_space ;; *) c_space=bt709 ;; esac
    case "$r_prim"  in bt709|smpte170m|bt470bg|smpte240m) c_prim=$r_prim ;;   *) c_prim=bt709 ;; esac
    case "$r_trc"   in bt709|smpte170m|bt470bg|smpte240m) c_trc=$r_trc ;;     *) c_trc=bt709 ;; esac
    SRC_TAGS="setparams=range=${c_range}:colorspace=${c_space}:color_primaries=${c_prim}:color_trc=${c_trc}"
    log "source colour tags: range=${r_range:-unset} space=${r_space:-unset} primaries=${r_prim:-unset} trc=${r_trc:-unset} -> pinned ${c_range}/${c_space}/${c_prim}/${c_trc}"

    if [ "$OVERLAY_HWACCEL" = "vaapi" ]; then
        OVERLAY_VAAPI_USE=1
        log "overlay: GPU (overlay_vaapi, forced — pixel check skipped)"
    else
        # PIXEL check, not just "does it run" — a run-only test passed on the
        # Intel N100 (iHD) while the live stream came out with garbled colours.
        # Composite the real mask on the GPU exactly like the live chain (one
        # mask frame, cropped, colour tags pinned) and on the CPU as the
        # reference, then compare with PSNR:
        #   outside the mask: camera pixels must pass through unchanged
        #   inside the mask:  the mask must actually cover the picture
        # Calibrated with simulated faults (outside/inside dB): identical 99/99,
        # 1:1 softening 76/47, BT.601-vs-709 50/55, black level 0-vs-16 99/32,
        # range mix-up ("vivid") 33/28, mask missing 99/13. The picture is a
        # smooth gradient so harmless softening by the GPU scaler doesn't read
        # as an error (hard-edged testsrc2 drops to ~39 dB for that).
        OV_DIR=$(mktemp -d)
        box="x=${mx}:y=${my}:w=${mw}:h=${mh}"
        # Both branches must carry identical colour tags: ffmpeg negotiates a
        # common colour range for psnr's inputs and would otherwise silently
        # range-convert one branch, failing a correct GPU (measured: 31.6 dB).
        G="[0:v]format=nv12,${SRC_TAGS},split[s1][s2];${MASK_PRE}${MASK_LBL}split[m1][m2];"
        G+="[s1]hwupload,${SRC_TAGS}[b];[m1]format=rgba,hwupload[hm];[b][hm]overlay_vaapi=x=${mx}:y=${my},hwdownload,format=nv12[gpu];"
        G+="[s2][m2]overlay=${MASK_XY},format=nv12[cpu];"
        G+="[gpu]format=yuv420p,split[g1][g2];[cpu]format=yuv420p,split[c1][c2];"
        G+="[g1]drawbox=${box}:color=black:t=fill[go];[c1]drawbox=${box}:color=black:t=fill[co];[go][co]psnr=stats_file=${OV_DIR}/out.log[p1];"
        G+="[g2]crop=${mw}:${mh}:${mx}:${my}[gi];[c2]crop=${mw}:${mh}:${mx}:${my}[ci];[gi][ci]psnr=stats_file=${OV_DIR}/in.log[p2]"
        psnr_min() { awk '{for(i=1;i<=NF;i++) if($i ~ /^psnr_avg:/){v=substr($i,10); if(v=="inf")v=99; if(m==""||v+0<m)m=v+0}} END{print m}' "$1" 2>/dev/null || true; }
        if OV_TEST_ERR=$(timeout 30 ffmpeg -hide_banner -loglevel error -nostdin \
                -init_hw_device "vaapi=va:${VAAPI_PATH}" -filter_hw_device va \
                -f lavfi -i "gradients=size=${MASK_W}x${MASK_H}:rate=5:duration=1:speed=0.02:nb_colors=4:c0=0xE05050:c1=0x50C0E0:c2=0xE0E060:c3=0x70E070" \
                -i "$OVERLAY_PATH" \
                -filter_complex "$G" \
                -map "[p1]" -f null - -map "[p2]" -f null - \
                </dev/null 2>&1 >/dev/null); then
            out_db=$(psnr_min "$OV_DIR/out.log"); in_db=$(psnr_min "$OV_DIR/in.log")
            frames=$(wc -l 2>/dev/null < "$OV_DIR/out.log" || echo 0)
            if awk -v o="${out_db:-0}" -v i="${in_db:-0}" -v f="${frames:-0}" -v t="$OVERLAY_VAAPI_MIN_PSNR" \
                    'BEGIN { exit !(f >= 3 && o >= t && i >= 20) }'; then
                OVERLAY_VAAPI_USE=1
                log "overlay: GPU (overlay_vaapi pixel check passed on $VAAPI_DEVICE: outside mask ${out_db} dB, inside ${in_db} dB)"
            else
                log "overlay: overlay_vaapi runs but produces WRONG pixels on this driver (outside mask ${out_db:-?} dB, need >= ${OVERLAY_VAAPI_MIN_PSNR}; inside ${in_db:-?} dB, need >= 20; ${frames:-0} frames) — using CPU overlay"
            fi
        else
            ov_err_line=$(printf '%s' "${OV_TEST_ERR:-}" | tail -n 1)
            log "overlay: overlay_vaapi not usable (${ov_err_line:-timed out}) — using CPU overlay"
        fi
        rm -rf "$OV_DIR"
    fi
fi

# ------------------------------------------------- dynamic FPS / GOP ------
# FPS=auto: match the camera's native rate — different cameras run different
# rates (15 here, 25 on others), and encoding slower than the source just
# adds dropped-motion judder. A pinned FPS still works as an override.
if [ "$FPS" = "auto" ]; then
    SRC_RATE=$(src_prop avg_frame_rate)
    if printf '%s' "$SRC_RATE" | grep -Eq '^[1-9][0-9]*$|^[1-9][0-9]*/[1-9][0-9]*$'; then
        FPS=$SRC_RATE
        log "source frame rate: $SRC_RATE (matched)"
    else
        FPS=10
        log "WARN: could not determine source frame rate (got: '${SRC_RATE:-empty}') — using 10fps fallback"
    fi
fi
# GOP=auto: ~4s of frames at the final rate (clamped 30..120) — a 6s GOP at
# 10fps is slow to recover from lost packets on lossy (UDP) viewer legs.
if [ "$GOP" = "auto" ]; then
    FPS_INT=$(awk -F/ '{v=($2 ? $1/$2 : $1); printf "%d", v+0.5}' <<< "$FPS")
    [ "$FPS_INT" -ge 1 ] 2>/dev/null || FPS_INT=10
    GOP=$(( FPS_INT * 4 ))
    [ "$GOP" -lt 30 ] && GOP=30
    [ "$GOP" -gt 120 ] && GOP=120
    log "GOP: auto -> $GOP (4x${FPS_INT}fps)"
fi

# -------------------------------------------------------------- sub stream --
# Sizes are resolved here to exact even numbers (the sub stream shares the
# main stream's ffmpeg, so a bad size must disable the sub, never break the
# main stream).
SUB_W=""; SUB_H=""
case "${SUB_SCALE,,}" in off|none|"") SUB_OUTPUT_URL="" ;; esac
if [ -n "$SUB_OUTPUT_URL" ]; then
    sub_w=${SUB_SCALE%%:*}; sub_h=${SUB_SCALE##*:}
    ref_w=$SRC_W; ref_h=$SRC_H
    if ! [[ "$ref_w" =~ ^[0-9]+$ && "$ref_h" =~ ^[0-9]+$ ]]; then ref_w=${MASK_W:-}; ref_h=${MASK_H:-}; fi
    if ! [[ "$sub_w" =~ ^[0-9]+$ ]] || [ "$sub_w" -lt 16 ] || [ "$sub_w" = "$SUB_SCALE" ]; then
        log "WARNING: SUB_SCALE='$SUB_SCALE' is not W:H — sub stream disabled"
    elif [[ "$sub_h" =~ ^[0-9]+$ ]] && [ "$sub_h" -ge 16 ]; then
        SUB_W=$(( sub_w & ~1 )); SUB_H=$(( sub_h & ~1 ))
    elif [ "$sub_h" = "-1" ] || [ "$sub_h" = "-2" ]; then
        if [[ "$ref_w" =~ ^[1-9][0-9]*$ && "$ref_h" =~ ^[1-9][0-9]*$ ]]; then
            SUB_W=$(( sub_w & ~1 )); SUB_H=$(( (sub_w * ref_h / ref_w + 1) & ~1 ))
        else
            log "WARNING: camera frame size unknown (probe failed), can't keep the aspect ratio for SUB_SCALE=$SUB_SCALE — sub stream disabled this run"
        fi
    else
        log "WARNING: SUB_SCALE='$SUB_SCALE' is not W:H — sub stream disabled"
    fi
    if [ -n "$SUB_W" ]; then
        log "sub stream: ${SUB_W}x${SUB_H} copy of the masked picture -> $(mask_url "$SUB_OUTPUT_URL")"
    fi
fi

# ------------------------------------------------------------- ffmpeg args --
# Filter chain ([0:v] = source video, [1:v] = mask PNG, [mk] = mask cropped
# to its opaque box, placed at X:Y):
#
#   Full GPU   : [mk]format=rgba,hwupload[mask];[0:v]setparams=..[base];[base][mask]overlay_vaapi=x=X:y=Y[,scale_vaapi=W:H] -> [vout]
#   GPU decode : [0:v][mk]overlay=X:Y,format=nv12,hwupload[,scale_vaapi] -> [vout]   (decoder returns CPU frames)
#   CPU decode : [0:v][mk]overlay=X:Y,... -> [vout]
#   Empty mask : no compositing at all
#
# The mask is ONE frame (no -loop): both overlay filters repeat the last mask
# frame for the whole stream (eof_action=repeat, their default). With -loop 1
# ffmpeg re-decoded and re-converted the full-size PNG ~25x/s — measured
# 11.5s CPU per 10s of 1440p vs 0.6s now (+ a 14.7MB upload per frame on the
# GPU path), which is what overloaded the N100. Pixel-identical output verified.
#
# Hard-won constraints (all pixel-verified 2026-09-26 against a known-ink mask):
#   1. CPU overlay is a TWO-input filter — main first, mask second, BOTH
#      explicitly labeled. Placing [1:v] inline mid-chain silently SWAPS the
#      inputs (mask invisible, gotcha #16). Hand-off must end its own ';' chain.
#   2. A label-only chain is invalid ("No such filter: ''"), so the CPU-decode
#      path (no source filters) keeps the legacy label-free form.
#   3. The mask is native-frame sized (editor canvas = main stream size), so
#      composite BEFORE any scale — scale only the source misaligns the mask.
#   4. With GPU decode + scale: use scale_vaapi after hwupload so the GPU does
#      the resize; CPU overlay + scale_vaapi: format=nv12,hwupload,scale_vaapi.
#   5. hwupload (ffmpeg 7.x) takes no device arg — derives from the encoder.
# Each path sets HEAD (graph up to the finished, masked frame, no output
# label), MAIN_TAIL (filters to the main encoder, may be empty) and SUB_TAIL
# (filters to the sub encoder). GPU-side paths scale on the GPU.
if [ "$ENCODE" = "nvenc" ]; then
    GPU_MAIN="${SCALE:+scale_cuda=${SCALE}}"
    GPU_SUB="scale_cuda=${SUB_W}:${SUB_H}"
else
    GPU_MAIN="${SCALE:+scale_vaapi=${SCALE}}"
    GPU_SUB="scale_vaapi=${SUB_W}:${SUB_H}"
fi
CPU_MAIN=""
if [ -n "$SCALE" ]; then CPU_MAIN="scale=${SCALE}:flags=lanczos,format=nv12"; fi
CPU_SUB="scale=${SUB_W}:${SUB_H}:flags=bicubic,format=nv12"
if [ "$ENCODE" = "vaapi" ]; then
    CPU_MAIN="${CPU_MAIN:+${CPU_MAIN},}hwupload"
    CPU_SUB="${CPU_SUB},hwupload"
fi
if [ -n "$MASK_EMPTY" ]; then
    # Nothing to hide: decode -> (scale) -> encode. With GPU decode the frames
    # never leave the GPU.
    if [ -n "$HWACCEL_USE" ]; then
        HEAD="[0:v]"; MAIN_TAIL=$GPU_MAIN; SUB_TAIL=$GPU_SUB
    elif [ "$ENCODE" = "nvenc" ]; then
        # CPU frames need uploading to CUDA before the encoder can accept them.
        HEAD="[0:v]format=nv12,hwupload_cuda"; MAIN_TAIL=$GPU_MAIN; SUB_TAIL=$GPU_SUB
    else
        HEAD="[0:v]format=nv12"; MAIN_TAIL=$CPU_MAIN; SUB_TAIL=$CPU_SUB
    fi
elif [ -n "$OVERLAY_VAAPI_USE" ]; then
    # Full GPU path: decoded VAAPI surface + RGBA mask → GPU compositor → h264_vaapi.
    # The mask is uploaded once; the video stays on the GPU the whole time.
    HEAD="${MASK_PRE}${MASK_LBL}format=rgba,hwupload[mask];[0:v]${SRC_TAGS}[base];[base][mask]overlay_vaapi=x=${MASK_XY%%:*}:y=${MASK_XY##*:}"
    MAIN_TAIL=$GPU_MAIN; SUB_TAIL=$GPU_SUB
elif [ "$ENCODE" = "nvenc" ]; then
    # NVENC always uses CPU overlay: whether CUDA or CPU decoded, frames arrive
    # on the CPU here (no -hwaccel_output_format cuda), overlay happens on CPU,
    # then hwupload_cuda sends them to the GPU for NVENC. Both CUDA-decode and
    # CPU-decode paths produce the same filter graph.
    HEAD="${MASK_PRE}[0:v]${MASK_LBL}overlay=${MASK_XY},format=nv12,hwupload_cuda"
    MAIN_TAIL=$GPU_MAIN; SUB_TAIL=$GPU_SUB
elif [ -n "$HWACCEL_USE" ]; then
    # VAAPI: GPU decode, CPU overlay, GPU encode. The decoder hands over CPU frames
    # itself (no -hwaccel_output_format vaapi, see below) instead of a
    # hwdownload in the graph: with hwdownload, a source whose height isn't a
    # multiple of 16 (Dahua 2880x1620, decoded as 1632 + crop) failed at
    # hwupload ("Failed to upload frame: -22") once overlay was in the chain.
    # Verified on the N100: that graph fails, this one runs.
    # Uploaded once; main/sub scaling then happens on the GPU.
    HEAD="${MASK_PRE}[0:v]${MASK_LBL}overlay=${MASK_XY},format=nv12,hwupload"
    MAIN_TAIL=$GPU_MAIN; SUB_TAIL=$GPU_SUB
else
    # CPU decode + CPU overlay + CPU scale (if set). hwupload at the end for VAAPI encode.
    HEAD="${MASK_PRE}[0:v]${MASK_LBL}overlay=${MASK_XY},format=nv12"
    MAIN_TAIL=$CPU_MAIN; SUB_TAIL=$CPU_SUB
fi
# HEAD is either a bare label ("[0:v]") or ends in a filter.
if [[ "$HEAD" == *"]" ]]; then sep=""; else sep=","; fi
if [ -n "$SUB_W" ]; then
    FILTER="${HEAD}${sep}split[vm][vs];[vm]${MAIN_TAIL:-null}[vout];[vs]${SUB_TAIL}[vsub]"
elif [ -z "$sep" ]; then
    FILTER="${HEAD}${MAIN_TAIL:-null}[vout]"
else
    FILTER="${HEAD}${MAIN_TAIL:+,${MAIN_TAIL}}[vout]"
fi

ffmpeg_args=(
    -hide_banner
    -nostdin
    -loglevel warning
    # --- robust input ------------------------------------------------------
    -rtsp_transport tcp
    -timeout 5000000             # 5s socket I/O timeout: dead camera -> exit -> restart (ffmpeg 7.x name of -stimeout)
    -max_delay 500000            # cap input buffering at 500ms
    -thread_queue_size 512
    -err_detect ignore_err
    -fflags +discardcorrupt
)
# GPU decode (input options, must precede -i): the GPU decodes, the CPU doesn't.
# -init_hw_device creates ONE named VAAPI context shared by the decoder
# (-hwaccel_device va), the filter graph (-filter_hw_device va), and the
# encoder (-vaapi_device va below). Without this, ffmpeg creates separate
# device contexts for decode and encode, leading to "2 hardware devices"
# warnings and preventing overlay_vaapi from compositing on the correct device.
if [ -n "$HWACCEL_USE" ]; then
    if [ "$ENCODE" = "nvenc" ]; then
        ffmpeg_args+=( -hwaccel cuda )
        # Keep decoded frames on the GPU only for the empty-mask path where
        # HEAD is "[0:v]" and no CPU overlay follows. The non-empty mask path
        # needs CPU frames (CPU overlay → hwupload_cuda), so no output_format.
        if [ -n "$MASK_EMPTY" ]; then
            ffmpeg_args+=( -hwaccel_output_format cuda )
        fi
    else
        ffmpeg_args+=(
            -init_hw_device "vaapi=va:${VAAPI_PATH}"
            -filter_hw_device va
            -hwaccel vaapi -hwaccel_device va
        )
        # Keep decoded frames on the GPU only when the graph stays on the GPU;
        # the CPU overlay path wants CPU frames straight from the decoder.
        if [ -n "$OVERLAY_VAAPI_USE" ] || [ -n "$MASK_EMPTY" ]; then
            ffmpeg_args+=( -hwaccel_output_format vaapi )
        fi
    fi
fi
ffmpeg_args+=( -i "$SOURCE_URL" )
if [ -z "$MASK_EMPTY" ]; then
    ffmpeg_args+=( -i "$OVERLAY_PATH" )
fi
ffmpeg_args+=( -filter_complex "$FILTER" )

# Video encoder options go into venc (shared by the main and sub outputs);
# rate control into main_rate / sub_rate. The sub stream always uses
# constant QP — a main-stream BITRATE would be absurd at 640 wide.
venc=()
if [ "$ENCODE" = "vaapi" ]; then
    # --- hardware encode (VAAPI: AMD iGPU or Intel QuickSync) -------------
    # With GPU decode active, the named device "va" is shared via -init_hw_device
    # and -filter_hw_device. h264_vaapi inherits the VAAPI context from the filter
    # chain's output frames (hwupload / overlay_vaapi). -vaapi_device is NOT used
    # because it only accepts file paths, not named device references — passing "va"
    # causes "No VA display found for device va" (verified on AMD 2026-09-26).
    # Without GPU decode, no device is established yet; specify the path explicitly
    # so hwupload in the filter chain can derive the target device from the encoder.
    if [ -z "$HWACCEL_USE" ]; then
        ffmpeg_args+=( -vaapi_device "$VAAPI_PATH" )
    fi
    venc=(
        -c:v h264_vaapi
        -profile:v "$PROFILE"
        -g "$GOP"
        -bf "$B_FRAMES"
        -r "$FPS"
    )
    sub_rate=( -qp "$QP" )
    if [ -n "$BITRATE" ]; then
        main_rate=( -rc_mode vbr -b:v "$BITRATE" )
        if [ -n "$MAXRATE" ]; then main_rate+=( -maxrate "$MAXRATE" ); fi
        if [ -n "$BUFSIZE" ]; then main_rate+=( -bufsize "$BUFSIZE" ); fi
    else
        main_rate=( -qp "$QP" )
    fi
elif [ "$ENCODE" = "nvenc" ]; then
    # --- hardware encode (NVENC: NVIDIA GPU) ----------------------------------
    # h264_nvenc accepts nv12 CUDA surfaces from hwupload_cuda / CUDA decode.
    # Rate control: constqp for constant quality (closest to VAAPI's -qp mode).
    # Sub stream always uses constqp — a main-stream bitrate target makes no
    # sense at 640px wide.
    venc=(
        -c:v h264_nvenc
        -profile:v "$PROFILE"
        -g "$GOP"
        -bf "$B_FRAMES"
        -r "$FPS"
    )
    sub_rate=( -rc constqp -qp "$QP" )
    if [ -n "$BITRATE" ]; then
        main_rate=( -rc vbr -b:v "$BITRATE" )
        if [ -n "$MAXRATE" ]; then main_rate+=( -maxrate "$MAXRATE" ); fi
        if [ -n "$BUFSIZE" ]; then main_rate+=( -bufsize "$BUFSIZE" ); fi
    else
        main_rate=( -rc constqp -qp "$QP" )
    fi
else
    # --- software encode (libx264) ----------------------------------------
    venc=(
        -c:v libx264
        -preset veryfast
        -profile:v "$PROFILE"
        -g "$GOP"
        -bf "$B_FRAMES"
        -r "$FPS"
    )
    # QP is our "constant quality" knob -> map to CRF (same 0-51-ish scale)
    sub_rate=( -b:v 0 -crf "$QP" )
    if [ -n "$BITRATE" ]; then
        main_rate=( -b:v "$BITRATE" )
        if [ -n "$MAXRATE" ]; then main_rate+=( -maxrate "$MAXRATE" ); fi
        if [ -n "$BUFSIZE" ]; then main_rate+=( -bufsize "$BUFSIZE" ); fi
    else
        main_rate=( -b:v 0 -crf "$QP" )
    fi
fi
if [ -n "$LEVEL" ] && [ "$LEVEL" != "auto" ]; then
    venc+=( -level "$LEVEL" )
fi

case "$AUDIO_MODE" in
    copy|aac|none) ;;
    *) log "ERROR: AUDIO_MODE must be 'copy', 'aac' or 'none' (got '$AUDIO_MODE')"; exit 1 ;;
esac
if [ "$AUDIO_MODE" = "copy" ]; then
    aenc=( -c:a copy )
elif [ "$AUDIO_MODE" = "aac" ]; then
    # The cameras emit G.711 A-law with broken timestamps; re-encoding to AAC
    # fixes the timestamp glitches and is understood by every player.
    aenc=( -c:a aac -b:a "$AUDIO_BITRATE" -ac 1 )
else
    aenc=( -an )
fi

ffmpeg_args+=(
    -map "[vout]" -map 0:a?
    "${venc[@]}" "${main_rate[@]}" "${aenc[@]}"
    -avoid_negative_ts make_zero
    -f rtsp
    -rtsp_transport tcp
    "$OUTPUT_URL"
)
# Sub stream: video only (detectors don't need the audio).
if [ -n "$SUB_W" ]; then
    ffmpeg_args+=(
        -map "[vsub]"
        "${venc[@]}" "${sub_rate[@]}" -an
        -avoid_negative_ts make_zero
        -f rtsp
        -rtsp_transport tcp
        "$SUB_OUTPUT_URL"
    )
fi

# --------------------------------------------------------------- preflight --
if [ "$PREFLIGHT" = "1" ]; then
    log "preflight: test-encoding 1s of testsrc ($ENCODE)"
    PREF_VF=""
    if [ "$ENCODE" = "vaapi" ]; then
        # Hand the encoder the same frames the REAL pipeline gives it: nv12 on
        # the GPU. testsrc is yuv444p in software — feeding 4:4:4 straight to
        # h264_vaapi fails on the AMD driver (no 4:4:4 H.264 surface) even
        # though the live nv12 stream encodes fine, so convert first exactly
        # like the live filter chain does (bare hwupload; the encoder's
        # -vaapi_device is what it targets).
        PREF_VF="format=nv12,hwupload"
        PREF_ARGS=( -vaapi_device "$VAAPI_PATH" -c:v h264_vaapi -profile:v "$PROFILE" )
    elif [ "$ENCODE" = "nvenc" ]; then
        # testsrc is yuv444p; h264_nvenc needs nv12 on a CUDA surface.
        PREF_VF="format=nv12,hwupload_cuda"
        PREF_ARGS=( -c:v h264_nvenc -profile:v "$PROFILE" )
    else
        # testsrc is yuv444p; libx264 'main' profile rejects 4:4:4, so pin 4:2:0
        # (the real pipeline always lands in nv12 via the filter chain anyway)
        PREF_ARGS=( -c:v libx264 -preset veryfast -profile:v "$PROFILE" -pix_fmt yuv420p )
    fi
    # Capture stderr (not discard it) so a failure says WHY — same rule as the
    # watchdog's "probe said:" logs.
    if PREF_ERR=$(timeout "$PREFLIGHT_TIMEOUT" ffmpeg -hide_banner -loglevel error -nostdin \
            -f lavfi -i "testsrc=duration=1:size=640x360:rate=5" \
            ${PREF_VF:+-vf "$PREF_VF"} \
            "${PREF_ARGS[@]}" \
            -f null - </dev/null 2>&1 >/dev/null); then
        if [ "$ENCODE" = "vaapi" ]; then
            log "preflight: OK — H.264 encode works (vaapi on $VAAPI_DEVICE)"
        elif [ "$ENCODE" = "nvenc" ]; then
            log "preflight: OK — H.264 encode works (h264_nvenc)"
        else
            log "preflight: OK — H.264 encode works (libx264)"
        fi
    else
        pref_line=$(printf '%s' "${PREF_ERR:-}" | tail -n 1)
        log "WARNING: preflight test-encode FAILED (${pref_line:-timed out}) — continuing; the real stream will fail with a clearer message"
    fi
fi

# ------------------------------------------------------- watchdog (probe) --
# ffprobe (not ffmpeg) on purpose: distinct binary, and we only need the
# stream header — a quick, bounded read of the pushed stream.
#
# NOTE: no `-t` / duration flag here — that is an ffmpeg (transcode) option
# and ffprobe rejects it with "Failed to set value for option 't': Option
# not found". Passing it made EVERY probe fail, so the watchdog concluded
# "zombie encoder" and force-killed perfectly healthy streams. Bounding the
# read relies on probe completion + `timeout 15` (and the 5s socket -timeout).
#
# PROBE_ERR keeps the probe's last error line so a strike says WHY the read
# failed (before this, stderr went to /dev/null and every failure looked
# identical).
PROBE_ERR=""
probe_output() {
    PROBE_ERR=$(timeout 15 ffprobe -v error \
        -rtsp_transport tcp -timeout 5000000 \
        -i "$OUTPUT_URL" \
        -show_entries stream=codec_name -of default=nw=1 \
        </dev/null 2>&1 >/dev/null | tail -n 1)
    local rc=$?
    [ -n "$PROBE_ERR" ] || PROBE_ERR="probe timed out"
    return "$rc"
}

# The mask is analysed and read once at startup, so a changed mask file needs
# a restart. The editor's "Save & Apply" restarts the container itself; this
# covers an apply that failed after the save, or a PNG replaced by hand. A
# deleted mask also triggers it, and the startup check then fails closed.
mask_sig() { stat -c '%i %Y %s' "$OVERLAY_PATH" 2>/dev/null || echo missing; }
MASK_SIG=$(mask_sig)
MAIN_PID=$$

# Reads the live pid from PID_FILE each round (a background subshell cannot
# see the parent's variable updates).
watchdog() {
    local fails=0 pid i
    while :; do
        sleep "$WATCHDOG_INTERVAL"
        if [ "$(mask_sig)" != "$MASK_SIG" ]; then
            log "watchdog: mask file ${OVERLAY_FILE} changed on disk — restarting the encoder to apply it"
            kill -TERM "$MAIN_PID" 2>/dev/null || true
            return 0
        fi
        pid=$(cat "$PID_FILE" 2>/dev/null || true)
        if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
            fails=0     # ffmpeg not running (backoff/restart in progress) — nothing to judge
            continue
        fi
        if probe_output; then
            [ "$fails" -gt 0 ] && log "watchdog: pushed stream readable again"
            fails=0
        else
            fails=$((fails + 1))
            if [ "$fails" -ge "$WATCHDOG_FAILS" ]; then
                log "watchdog: $WATCHDOG_FAILS consecutive failed reads of $(mask_url "$OUTPUT_URL") while ffmpeg (pid $pid) is alive — zombie encoder, force-killing (probe said: ${PROBE_ERR})"
                kill -TERM "$pid" 2>/dev/null || true
                for i in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 1
                done
                kill -KILL "$pid" 2>/dev/null || true
                # D-state check: a VAAPI/DRM kernel call can hang indefinitely
                # after hours of use; SIGKILL cannot terminate a D-state process.
                # The supervisor's 'wait' is also blocked on the same child.
                # If the process survives SIGKILL, force-restart the entire
                # container — Docker restarts it and the container teardown
                # cleans up the orphaned D-state process.
                sleep 2
                if kill -0 "$pid" 2>/dev/null; then
                    log "watchdog: pid $pid survived SIGKILL (D-state GPU driver hang) — force-restarting the container"
                    kill -KILL "$MAIN_PID" 2>/dev/null || true
                    exit 1
                fi
                fails=0
            else
                log "watchdog: cannot read pushed stream ($fails/$WATCHDOG_FAILS) — ffmpeg (pid $pid) still alive (probe said: ${PROBE_ERR})"
            fi
        fi
    done
}

# ----------------------------------------------------------------- signals --
FFMPEG_PID=""
WATCHDOG_PID=""
shutdown() {
    trap - TERM INT
    log "stop signal received, shutting down"
    if [ -n "$WATCHDOG_PID" ]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    fi
    if [ -n "$FFMPEG_PID" ]; then
        kill -TERM "$FFMPEG_PID" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do
            kill -0 "$FFMPEG_PID" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$FFMPEG_PID" 2>/dev/null || true
        # Only reap if the process actually died — a D-state process survives
        # SIGKILL and would block 'wait' forever. Let the container runtime
        # clean it up instead.
        if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
            wait "$FFMPEG_PID" 2>/dev/null || true
        else
            log "shutdown: ffmpeg pid $FFMPEG_PID survived SIGKILL (D-state) — container teardown will clean it up"
        fi
    fi
    log "shutdown complete"
    exit 0
}
trap shutdown TERM INT

# -------------------------------------------------------------------- main --
encode_note=""
if [ "$ENCODE" = "vaapi" ]; then encode_note=" vaapi=$VAAPI_DEVICE"
elif [ "$ENCODE" = "nvenc" ]; then encode_note=" nvenc"
fi
decode_note="cpu"
if [ -n "$HWACCEL_USE" ]; then
    if [ "$ENCODE" = "nvenc" ]; then decode_note="cuda"
    else decode_note="vaapi"
    fi
fi
ovl_note="cpu"
if [ -n "$OVERLAY_VAAPI_USE" ]; then ovl_note="vaapi"; fi
if [ -n "$MASK_EMPTY" ]; then ovl_note="none"; fi
sub_note="off"
if [ -n "$SUB_W" ]; then sub_note="${SUB_W}x${SUB_H}"; fi
log "config: in=$(mask_url "$SOURCE_URL") out=$(mask_url "$OUTPUT_URL") overlay=${OVERLAY_FILE}@${MASK_XY} encode=$ENCODE${encode_note} decode=${decode_note} ovl=${ovl_note} scale=${SCALE:-native} sub=${sub_note} fps=${FPS} gop=${GOP} audio=${AUDIO_MODE}"
if [ -n "$BITRATE" ]; then
    log "rate control: VBR bitrate=${BITRATE}${MAXRATE:+ maxrate=${MAXRATE}}${BUFSIZE:+ bufsize=${BUFSIZE}}"
else
    log "rate control: constant QP ${QP}"
fi
# Mask the source URL for display. (Do NOT sed-substitute it: a replacement
# string containing '&' means "the matched text" to sed, which would paste
# the full unmasked URL back into the log whenever the URL contains '&',
# e.g. Dahua realmonitor?channel=1&subtype=0.)
cmd_display=()
for a in "${ffmpeg_args[@]}"; do
    [ "$a" = "$SOURCE_URL" ] && a="$(mask_url "$SOURCE_URL")"
    cmd_display+=( "$a" )
done
log "cmd: ffmpeg ${cmd_display[*]}"

# Watchdog starts before the loop so it covers the very first run too.
watchdog &
WATCHDOG_PID=$!

delay="$RESTART_DELAY_INITIAL"
while true; do
    started=$(date +%s)
    log "starting ffmpeg"
    ffmpeg "${ffmpeg_args[@]}" </dev/null &
    FFMPEG_PID=$!
    printf '%s\n' "$FFMPEG_PID" > "$PID_FILE"

    set +e
    wait "$FFMPEG_PID"
    rc=$?
    set -e
    FFMPEG_PID=""
    rm -f "$PID_FILE"
    elapsed=$(( $(date +%s) - started ))

    if [ "$MAX_UPTIME_HOURS" -gt 0 ] 2>/dev/null && [ "$elapsed" -ge $(( MAX_UPTIME_HOURS * 3600 )) ]; then
        log "ran ${elapsed}s — preventive restart (max uptime ${MAX_UPTIME_HOURS}h reached)"
        delay="$RESTART_DELAY_INITIAL"
        continue
    fi

    log "ffmpeg exited rc=${rc} after ${elapsed}s — retrying in ${delay}s"
    sleep $(( delay + RANDOM % 3 ))   # jitter so cameras don't retry in lockstep
    delay=$(( delay * 2 ))
    [ "$delay" -gt "$RESTART_DELAY_MAX" ] && delay="$RESTART_DELAY_MAX"
done
