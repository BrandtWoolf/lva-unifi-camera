#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

CONFIGURE=0
CHECK_ONLY=0
WAIT_TIMEOUT=240

usage() {
    cat <<'EOF'
Usage: ./start.sh [--configure] [--check]

Without arguments, validates the saved configuration, updates images, builds
the bridges, starts the full microphone + speaker stack, and waits for health.

  --configure  Replace the saved .env and ufp.json after prompting again
  --check      Validate configuration and build prerequisites without starting
  -h, --help   Show this help
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

for argument in "$@"; do
    case "$argument" in
        --configure) CONFIGURE=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: ${argument}" ;;
    esac
done

command -v docker >/dev/null 2>&1 ||
    die "Docker is not installed. Install Docker Desktop or Docker Engine first."
docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is required (the 'docker compose' command)."
docker info >/dev/null 2>&1 ||
    die "The Docker daemon is not available. Start Docker Desktop or Docker Engine."

has_control_characters() {
    LC_ALL=C grep -q '[[:cntrl:]]' <<<"$1"
}

is_placeholder() {
    local value
    value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    [[ "$value" == *"replace_with"* ||
       "$value" == *"replace-with"* ||
       "$value" == *"changeme"* ||
       "$value" == *"console_ip"* ||
       "$value" == *"stream_id"* ||
       "$value" == *"your_"* ||
       "$value" == *"<"* ||
       "$value" == *">"* ]]
}

validate_plain_value() {
    local label="$1"
    local value="$2"
    [[ -n "$value" ]] || die "${label} cannot be empty."
    ! has_control_characters "$value" || die "${label} contains unsupported control characters."
    ! is_placeholder "$value" || die "${label} still contains a placeholder."
}

validate_rtsp_url() {
    local value="$1"
    validate_plain_value "RTSP(S) URL" "$value"
    [[ "$value" =~ ^rtsps?://([^/@[:space:]]+@)?(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]{1,5})?/.+ ]] ||
        die "RTSP(S) URL must look like rtsp://host:7447/stream-id or rtsps://host:7441/stream-id?enableSrtp."
    [[ "$value" != *[[:space:]]* ]] || die "RTSP(S) URL cannot contain whitespace."
}

validate_controller() {
    local value="$1"
    local authority
    validate_plain_value "Protect controller" "$value"
    authority="${value#http://}"
    authority="${authority#https://}"
    authority="${authority%/}"
    [[ "$authority" =~ ^(\[[0-9A-Fa-f:]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(:[0-9]{1,5})?$ ]] &&
        [[ "$value" =~ ^(https?://)?[^/]+/?$ ]] ||
        die "Protect controller must be a hostname/IP and optional port, without a path."
}

dotenv_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\'/\\\'}"
    printf "'%s'" "$value"
}

json_quote() {
    local value="${1//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

read_env_value() {
    local key="$1"
    local line value
    line="$(grep -E "^${key}=" .env | tail -n 1 || true)"
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    if [[ "$value" == \'*\' || "$value" == \"*\" ]]; then
        value="${value:1:${#value}-2}"
    fi
    value="${value//\\\'/\'}"
    value="${value//\\\\/\\}"
    printf '%s' "$value"
}

validate_saved_configuration() {
    local rtsp_url camera

    [[ -f .env ]] || die ".env is missing. Run ./start.sh --configure."
    [[ -f ufp.json ]] || die "ufp.json is missing. Run ./start.sh --configure."
    [[ ! -L .env && ! -L ufp.json ]] || die "Refusing symlinked configuration files."

    rtsp_url="$(read_env_value RTSP_URL || true)"
    camera="$(read_env_value PROTECT_CAMERA || true)"

    validate_rtsp_url "$rtsp_url"
    validate_plain_value "Protect camera name" "$camera"
    ! grep -Eqi 'replace[_-]?with|changeme|console_ip|stream_id|your_|[<>]' ufp.json ||
        die "ufp.json still contains a placeholder."
    chmod 600 .env ufp.json
}

configure() {
    local rtsp_url camera controller username password password_confirm
    local env_tmp json_tmp

    [[ -t 0 ]] || die "Interactive configuration requires a terminal."

    cat <<'EOF'
UniFi Protect setup requirement
-------------------------------
Camera speaker talkback is not available over RTSP. Create a dedicated LOCAL
UniFi OS user (not a cloud/SSO account) and grant it Protect "Full Management"
for the selected camera. This broad local permission is currently required by
Protect's authenticated talkback API. Use a unique password for this account.
Credentials stay in owner-readable local files and are never printed.
EOF

    read -r -s -p "RTSP(S) URL (hidden): " rtsp_url
    printf '\n'
    validate_rtsp_url "$rtsp_url"

    read -r -p "Exact Protect camera name: " camera
    validate_plain_value "Protect camera name" "$camera"

    read -r -p "Protect controller hostname/IP (optional https:// and port): " controller
    validate_controller "$controller"

    read -r -p "Local Protect username: " username
    validate_plain_value "Protect local username" "$username"

    read -r -s -p "Local Protect password: " password
    printf '\n'
    validate_plain_value "Protect password" "$password"
    read -r -s -p "Confirm password: " password_confirm
    printf '\n'
    [[ "$password" == "$password_confirm" ]] || die "Passwords do not match."

    umask 077
    env_tmp="$(mktemp "${ROOT_DIR}/.env.tmp.XXXXXX")"
    json_tmp="$(mktemp "${ROOT_DIR}/ufp.json.tmp.XXXXXX")"
    trap 'rm -f "${env_tmp:-}" "${json_tmp:-}"' EXIT

    cat >"$env_tmp" <<EOF
# Generated by ./start.sh. Re-run ./start.sh --configure to replace.
COMPOSE_PROFILES='speaker'
RTSP_URL=$(dotenv_quote "$rtsp_url")
MIC_RATE='16000'

LVA_USER_ID='1000'
LVA_USER_GROUP='1000'
CLIENT_NAME='unifi-camera-satellite'
HOST='0.0.0.0'
LVA_PORT='6053'
LVA_PERIPHERAL_PORT='6055'
LVA_PULSE_SERVER='unix:/run/pulse/native'
LVA_PULSE_COOKIE='DISABLED'
LVA_XDG_RUNTIME_DIR='/run/pulse'
AUDIO_INPUT_DEVICE='camera_mic'
AUDIO_INPUT_CHANNELS='1'
AUDIO_OUTPUT_DEVICE='pulse/lva_out'
LISTEN_DURING_WAKE_SOUND='1'

PROTECT_CAMERA=$(dotenv_quote "$camera")
TALKBACK_OUTPUT_MONITOR='lva_out.monitor'
EOF

    cat >"$json_tmp" <<EOF
{
  "controller": $(json_quote "$controller"),
  "username": $(json_quote "$username"),
  "password": $(json_quote "$password"),
  "verifyTls": false
}
EOF

    chmod 600 "$env_tmp" "$json_tmp"
    mv -f "$env_tmp" .env
    mv -f "$json_tmp" ufp.json
    trap - EXIT
    unset password password_confirm
    printf 'Saved .env and owner-only ufp.json.\n'
}

if (( CONFIGURE )); then
    configure
elif [[ ! -e .env && ! -e ufp.json ]]; then
    configure
elif [[ ! -e .env || ! -e ufp.json ]]; then
    die "Only one configuration file exists. Run ./start.sh --configure to replace both safely."
fi

validate_saved_configuration
docker compose --profile speaker config --quiet ||
    die "Docker Compose configuration is invalid."

printf 'Validating credentials file and building the speaker bridge...\n'
docker compose --profile speaker build speaker-bridge
docker run --rm -i --entrypoint node \
    lva-unifi-camera-speaker-bridge:local -e '
const fs = require("node:fs");
let config;
try {
  config = JSON.parse(fs.readFileSync(0, "utf8"));
} catch {
  throw new Error("ufp.json is not valid JSON");
}
for (const key of ["controller", "username", "password"]) {
  if (typeof config[key] !== "string" || config[key].length === 0) {
    throw new Error(`ufp.json field "${key}" must be a non-empty string`);
  }
  if (/replace[_-]?with|changeme|console_ip|stream_id|your_|[<>]/i.test(config[key])) {
    throw new Error(`ufp.json field "${key}" contains a placeholder`);
  }
}
if (typeof config.verifyTls !== "boolean") {
  throw new Error("ufp.json field \"verifyTls\" must be true or false");
}
let controller;
try {
  controller = new URL(
    config.controller.includes("://") ? config.controller : `https://${config.controller}`,
  );
} catch {
  throw new Error("ufp.json controller is not a valid hostname/IP and optional port");
}
if (
  !["http:", "https:"].includes(controller.protocol) ||
  !controller.hostname ||
  controller.username ||
  controller.password ||
  (controller.pathname !== "/" && controller.pathname !== "") ||
  controller.search ||
  controller.hash
) {
  throw new Error("ufp.json controller must be a hostname/IP and optional port, without a path");
}
' <ufp.json || die "ufp.json validation failed."

if (( CHECK_ONLY )); then
    printf 'Configuration and build prerequisites are valid.\n'
    exit 0
fi

printf 'Updating images and starting the stack...\n'
docker compose --profile speaker pull linux-voice-assistant
docker compose --profile speaker up -d --build --remove-orphans

wait_for_service() {
    local service="$1"
    local deadline=$((SECONDS + WAIT_TIMEOUT))
    local container_id status health

    while (( SECONDS < deadline )); do
        container_id="$(docker compose --profile speaker ps -q "$service")"
        if [[ -n "$container_id" ]]; then
            status="$(docker inspect --format '{{.State.Status}}' "$container_id")"
            health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container_id")"
            if [[ "$status" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
                printf '  ready: %s\n' "$service"
                return 0
            fi
            if [[ "$status" == "exited" || "$health" == "unhealthy" ]]; then
                docker compose --profile speaker logs --tail 30 "$service" >&2
                die "${service} failed to become healthy."
            fi
        fi
        sleep 3
    done

    docker compose --profile speaker logs --tail 30 "$service" >&2
    die "Timed out after ${WAIT_TIMEOUT}s waiting for ${service}."
}

printf 'Waiting for microphone, assistant, and talkback readiness...\n'
wait_for_service audio-bridge
wait_for_service linux-voice-assistant
wait_for_service speaker-bridge

cat <<'EOF'

Ready.
Home Assistant: add the ESPHome integration using this Docker host and port 6053.
Status:         docker compose ps
Logs:           docker compose logs -f
Stop:           docker compose down
Reconfigure:    ./start.sh --configure
EOF
