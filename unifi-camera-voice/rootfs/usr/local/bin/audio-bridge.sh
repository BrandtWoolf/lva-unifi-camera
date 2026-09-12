#!/usr/bin/env bash
set -uo pipefail

: "${RTSP_URL:?RTSP_URL is required}"
MIC_RATE="${MIC_RATE:-16000}"
PULSE_DIR="${PULSE_DIR:-/run/pulse}"
PA_PID=
FFMPEG_PID=

cleanup() {
    trap - EXIT INT TERM
    [[ -n "$FFMPEG_PID" ]] && kill -TERM "$FFMPEG_PID" 2>/dev/null || true
    [[ -n "$PA_PID" ]] && kill -TERM "$PA_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}

trap cleanup EXIT INT TERM

mkdir -p "$PULSE_DIR"
rm -f \
    "${PULSE_DIR}/native" \
    "${PULSE_DIR}/camera_mic.fifo" \
    "${PULSE_DIR}/pulse/pid"
export XDG_RUNTIME_DIR="$PULSE_DIR"
export HOME=/root

echo "[audio-bridge] starting PulseAudio"
pulseaudio -n --daemonize=no --exit-idle-time=-1 --disallow-exit \
    --log-target=stderr --log-level=notice \
    --load="module-native-protocol-unix auth-anonymous=1 socket=${PULSE_DIR}/native" \
    --load="module-null-sink sink_name=lva_out sink_properties=device.description=lva_out" \
    --load="module-pipe-source source_name=camera_mic file=${PULSE_DIR}/camera_mic.fifo format=s16le rate=${MIC_RATE} channels=1 source_properties=device.description=UniFi_Camera_Mic" &
PA_PID=$!

for _ in $(seq 1 30); do
    [[ -S "${PULSE_DIR}/native" ]] && break
    sleep 1
done
chmod -R a+rwX "$PULSE_DIR" 2>/dev/null || true

export PULSE_SERVER="unix:${PULSE_DIR}/native"
pactl set-default-sink lva_out 2>/dev/null || true
pactl info >/dev/null 2>&1 ||
    { echo "[audio-bridge] ERROR: PulseAudio did not start" >&2; exit 1; }

echo "[audio-bridge] virtual microphone is ready"
while true; do
    echo "[audio-bridge] connecting to configured RTSP(S) stream"
    ffmpeg -hide_banner -loglevel warning -nostdin -y \
        -rtsp_transport tcp -fflags nobuffer -flags low_delay \
        -i "$RTSP_URL" \
        -vn -ac 1 -ar "$MIC_RATE" -f s16le "${PULSE_DIR}/camera_mic.fifo" &
    FFMPEG_PID=$!
    wait "$FFMPEG_PID" || true
    FFMPEG_PID=

    kill -0 "$PA_PID" 2>/dev/null ||
        { echo "[audio-bridge] ERROR: PulseAudio exited" >&2; exit 1; }
    echo "[audio-bridge] RTSP stream stopped; reconnecting in 3 seconds"
    sleep 3
done
