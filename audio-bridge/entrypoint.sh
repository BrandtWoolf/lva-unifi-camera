#!/usr/bin/env bash
# Runs a private PulseAudio server and streams a UniFi camera's RTSP audio into
# a virtual microphone source called "camera_mic". The Linux Voice Assistant
# container connects to the shared PulseAudio socket and uses that source as its
# microphone.
set -uo pipefail

: "${RTSP_URL:?Set RTSP_URL to your UniFi camera RTSP(S) URL in .env}"
MIC_RATE="${MIC_RATE:-16000}"
PULSE_DIR="${PULSE_DIR:-/run/pulse}"

mkdir -p "$PULSE_DIR"
export XDG_RUNTIME_DIR="$PULSE_DIR"
export HOME=/root

echo "[audio-bridge] starting PulseAudio (socket: ${PULSE_DIR}/native)"
pulseaudio -n --daemonize=no --exit-idle-time=-1 --disallow-exit \
    --log-target=stderr --log-level=notice \
    --load="module-native-protocol-unix auth-anonymous=1 socket=${PULSE_DIR}/native" \
    --load="module-null-sink sink_name=lva_out sink_properties=device.description=lva_out" \
    --load="module-pipe-source source_name=camera_mic file=${PULSE_DIR}/camera_mic.fifo format=s16le rate=${MIC_RATE} channels=1 source_properties=device.description=UniFi_Camera_Mic" &
PA_PID=$!

# Wait for the socket, then relax perms so the (uid 1000) LVA container can use it
for _ in $(seq 1 30); do [ -S "${PULSE_DIR}/native" ] && break; sleep 1; done
chmod -R a+rwX "$PULSE_DIR" 2>/dev/null || true

export PULSE_SERVER="unix:${PULSE_DIR}/native"
pactl set-default-sink lva_out 2>/dev/null || true
if ! pactl info >/dev/null 2>&1; then
    echo "[audio-bridge] ERROR: PulseAudio did not come up" >&2
    exit 1
fi
echo "[audio-bridge] PulseAudio ready; virtual mic 'camera_mic' available."

# Feed the pipe source from the camera. Reconnect forever if the stream drops.
while true; do
    echo "[audio-bridge] connecting to ${RTSP_URL}"
    ffmpeg -hide_banner -loglevel warning -nostdin \
        -rtsp_transport tcp -fflags nobuffer -flags low_delay \
        -i "${RTSP_URL}" \
        -vn -ac 1 -ar "${MIC_RATE}" -f s16le "${PULSE_DIR}/camera_mic.fifo" || true
    echo "[audio-bridge] ffmpeg stopped; reconnecting in 3s..."
    sleep 3
    kill -0 "$PA_PID" 2>/dev/null || { echo "[audio-bridge] PulseAudio died" >&2; exit 1; }
done
