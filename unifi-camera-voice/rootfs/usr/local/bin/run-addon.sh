#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_PATH=/data/options.json
PIDS=()

log() {
    printf '[unifi-camera-voice] %s\n' "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

option() {
    jq -r --arg key "$1" 'if has($key) then .[$key] else empty end' "$CONFIG_PATH"
}

require_option() {
    local key="$1"
    local label="$2"
    local value

    value="$(option "$key")" || die "Unable to read ${label} from the add-on configuration."
    [[ -n "$value" ]] || die "${label} is required. Configure it on the add-on Configuration tab."
    printf '%s' "$value"
}

cleanup() {
    local pid

    trap - EXIT INT TERM
    for pid in "${PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    wait "${PIDS[@]}" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

[[ -r "$CONFIG_PATH" ]] || die "Home Assistant add-on configuration is unavailable."

export RTSP_URL
export PROTECT_CAMERA
export CLIENT_NAME
export MIC_RATE
RTSP_URL="$(require_option rtsp_url "RTSP(S) URL")"
PROTECT_CAMERA="$(require_option protect_camera "Protect camera name")"
CLIENT_NAME="$(require_option client_name "client name")"
MIC_RATE="$(option mic_rate)"

PROTECT_CONTROLLER="$(require_option protect_controller "Protect controller")"
PROTECT_USERNAME="$(require_option protect_username "Protect username")"
PROTECT_PASSWORD="$(require_option protect_password "Protect password")"
VERIFY_TLS="$(option verify_tls)"
DEBUG_LOGGING="$(option debug_logging)"

[[ "$RTSP_URL" =~ ^rtsps?://[^[:space:]]+/.+ ]] ||
    die "RTSP(S) URL must begin with rtsp:// or rtsps:// and include a stream path."
[[ "$MIC_RATE" =~ ^[0-9]+$ ]] && (( MIC_RATE >= 8000 && MIC_RATE <= 48000 )) ||
    die "Microphone sample rate must be between 8000 and 48000 Hz."

mkdir -p \
    /data/lva/configuration \
    /data/lva/local \
    /data/lva/sounds-custom \
    /data/lva/wakewords-custom

rm -rf \
    /app/configuration \
    /app/local \
    /app/sounds/custom \
    /app/wakewords/custom
ln -s /data/lva/configuration /app/configuration
ln -s /data/lva/local /app/local
ln -s /data/lva/sounds-custom /app/sounds/custom
ln -s /data/lva/wakewords-custom /app/wakewords/custom

jq -n \
    --arg controller "$PROTECT_CONTROLLER" \
    --arg username "$PROTECT_USERNAME" \
    --arg password "$PROTECT_PASSWORD" \
    --argjson verifyTls "$VERIFY_TLS" \
    '{controller: $controller, username: $username, password: $password, verifyTls: $verifyTls}' \
    > /data/ufp.json
chmod 600 /data/ufp.json
unset PROTECT_PASSWORD

export HOST=0.0.0.0
export PORT=6053
export PERIPHERAL_HOST=0.0.0.0
export PERIPHERAL_PORT=6055
export PULSE_SERVER=unix:/run/pulse/native
export PULSE_COOKIE=DISABLED
export XDG_RUNTIME_DIR=/run/pulse
export AUDIO_INPUT_DEVICE=camera_mic
export AUDIO_INPUT_CHANNELS=1
export AUDIO_OUTPUT_DEVICE=pulse/lva_out
export TALKBACK_OUTPUT_MONITOR=lva_out.monitor
export LISTEN_DURING_WAKE_SOUND=1
export UFP_CREDENTIALS_PATH=/data/ufp.json

if [[ "$DEBUG_LOGGING" == "true" ]]; then
    export ENABLE_DEBUG=1
fi

log "Starting private PulseAudio server and camera microphone bridge."
/usr/local/bin/audio-bridge.sh &
PIDS+=("$!")

for _ in $(seq 1 30); do
    if PULSE_SERVER="$PULSE_SERVER" pactl list sources short 2>/dev/null |
        awk '{print $2}' | grep -qx camera_mic; then
        break
    fi
    sleep 1
done

PULSE_SERVER="$PULSE_SERVER" pactl list sources short 2>/dev/null |
    awk '{print $2}' | grep -qx camera_mic ||
    die "The virtual camera microphone did not become ready."

log "Starting Linux Voice Assistant as ${CLIENT_NAME}."
(
    cd /app
    exec ./docker-entrypoint.sh
) &
PIDS+=("$!")

log "Starting UniFi Protect speaker talkback bridge."
node /opt/unifi-camera-voice/speaker-bridge.mjs &
PIDS+=("$!")

set +e
wait -n "${PIDS[@]}"
STATUS=$?
set -e
die "A required process exited with status ${STATUS}; restarting the add-on."
