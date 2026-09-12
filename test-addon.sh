#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${ADDON_TEST_IMAGE:-lva-unifi-camera-addon:test}"
APP_VERSION="$(
    sed -nE 's/^version: *"?([^"]+)"?$/\1/p' \
        "$ROOT_DIR/unifi-camera-voice/config.yaml"
)"
ESPHOME_PORT="${ADDON_ESPHOME_PORT:-16053}"
PERIPHERAL_PORT="${ADDON_PERIPHERAL_PORT:-16055}"
MODE="${1:---smoke}"
DATA_DIR=
CONTAINER_ID=
FIRST_DEVICE_NAME=

usage() {
    cat <<'EOF'
Usage: ./test-addon.sh [--smoke | --run OPTIONS_JSON]

  --smoke             Build the add-on and verify all processes start using
                      unreachable test endpoints. This is the default.
  --run OPTIONS_JSON  Build and run against real settings in Home Assistant's
                      options.json format. Press Ctrl+C to stop.

Environment overrides:
  ADDON_ESPHOME_PORT    Host port mapped to container port 6053 (default 16053)
  ADDON_PERIPHERAL_PORT Host port mapped to container port 6055 (default 16055)
  ADDON_TEST_IMAGE      Local Docker image name
EOF
}

cleanup() {
    trap - EXIT INT TERM
    if [[ -n "$CONTAINER_ID" ]]; then
        docker rm -f "$CONTAINER_ID" >/dev/null 2>&1 || true
    fi
    if [[ -n "$DATA_DIR" && -d "$DATA_DIR" ]]; then
        rm -rf -- "$DATA_DIR"
    fi
}

trap cleanup EXIT INT TERM

case "$(uname -m)" in
    x86_64) BUILD_ARCH=amd64 ;;
    arm64|aarch64) BUILD_ARCH=aarch64 ;;
    *) printf 'Unsupported local architecture: %s\n' "$(uname -m)" >&2; exit 1 ;;
esac

build_image() {
    printf 'Building %s for %s...\n' "$IMAGE" "$BUILD_ARCH"
    docker build \
        --build-arg "BUILD_ARCH=${BUILD_ARCH}" \
        --build-arg "BUILD_VERSION=${APP_VERSION}-local" \
        --tag "$IMAGE" \
        "$ROOT_DIR/unifi-camera-voice"
}

prepare_data() {
    DATA_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lva-addon-test.XXXXXX")"
    chmod 700 "$DATA_DIR"
}

case "$MODE" in
    --smoke)
        [[ $# -le 1 ]] || { usage >&2; exit 1; }
        build_image
        prepare_data
        cat >"$DATA_DIR/options.json" <<'EOF'
{
  "rtsp_url": "rtsp://127.0.0.1:8554/test",
  "protect_camera": "Test Camera",
  "protect_controller": "127.0.0.1:8443",
  "protect_username": "test-user",
  "protect_password": "smoke-test-secret",
  "verify_tls": false,
  "client_name": "test-satellite",
  "mic_rate": 16000,
  "debug_logging": false
}
EOF
        chmod 600 "$DATA_DIR/options.json"

        CONTAINER_ID="$(docker run -d -v "$DATA_DIR:/data" "$IMAGE")"
        for _ in $(seq 1 30); do
            if ! docker inspect --format '{{.State.Running}}' "$CONTAINER_ID" |
                grep -qx true; then
                docker logs "$CONTAINER_ID" >&2
                printf 'Add-on exited during startup.\n' >&2
                exit 1
            fi

            LOGS="$(docker logs "$CONTAINER_ID" 2>&1)"
            if grep -q 'virtual microphone is ready' <<<"$LOGS" &&
                grep -q 'Server started (host=0.0.0.0, port=6053)' <<<"$LOGS" &&
                grep -q 'Starting UniFi Protect speaker talkback bridge' <<<"$LOGS"; then
                if grep -q 'smoke-test-secret' <<<"$LOGS"; then
                    printf 'Add-on exposed a configured secret in its log.\n' >&2
                    exit 1
                fi
                FIRST_DEVICE_NAME="$(
                    sed -nE 's/^Device name: (lva-[[:xdigit:]]+)$/\1/p' <<<"$LOGS" |
                        tail -1
                )"
                [[ -n "$FIRST_DEVICE_NAME" ]] || {
                    docker logs "$CONTAINER_ID" >&2
                    printf 'Unable to determine the initial ESPHome device name.\n' >&2
                    exit 1
                }
                break
            fi
            sleep 1
        done

        [[ -n "$FIRST_DEVICE_NAME" ]] || {
            docker logs "$CONTAINER_ID" >&2
            printf 'Timed out waiting for add-on startup.\n' >&2
            exit 1
        }

        docker rm -f "$CONTAINER_ID" >/dev/null
        CONTAINER_ID="$(docker run -d -v "$DATA_DIR:/data" "$IMAGE")"
        for _ in $(seq 1 30); do
            if ! docker inspect --format '{{.State.Running}}' "$CONTAINER_ID" |
                grep -qx true; then
                docker logs "$CONTAINER_ID" >&2
                printf 'Add-on exited during restart.\n' >&2
                exit 1
            fi

            LOGS="$(docker logs "$CONTAINER_ID" 2>&1)"
            SECOND_DEVICE_NAME="$(
                sed -nE 's/^Device name: (lva-[[:xdigit:]]+)$/\1/p' <<<"$LOGS" |
                    tail -1
            )"
            if [[ -n "$SECOND_DEVICE_NAME" ]]; then
                [[ "$SECOND_DEVICE_NAME" == "$FIRST_DEVICE_NAME" ]] || {
                    printf 'ESPHome device identity changed after restart: %s -> %s\n' \
                        "$FIRST_DEVICE_NAME" "$SECOND_DEVICE_NAME" >&2
                    exit 1
                }
                printf 'Local add-on smoke and restart tests passed.\n'
                exit 0
            fi
            sleep 1
        done

        docker logs "$CONTAINER_ID" >&2
        printf 'Timed out waiting for the restarted add-on.\n' >&2
        exit 1
        ;;
    --run)
        [[ $# -eq 2 ]] || { usage >&2; exit 1; }
        OPTIONS_PATH="$(cd -- "$(dirname -- "$2")" && pwd)/$(basename -- "$2")"
        [[ -f "$OPTIONS_PATH" ]] || {
            printf 'Options file not found: %s\n' "$OPTIONS_PATH" >&2
            exit 1
        }

        build_image
        prepare_data
        cp "$OPTIONS_PATH" "$DATA_DIR/options.json"
        chmod 600 "$DATA_DIR/options.json"

        printf 'Starting on ESPHome port %s and peripheral port %s...\n' \
            "$ESPHOME_PORT" "$PERIPHERAL_PORT"
        printf 'Press Ctrl+C to stop. Persistent test data will be removed.\n'
        docker run --rm \
            --cap-add SYS_NICE \
            --publish "${ESPHOME_PORT}:6053" \
            --publish "${PERIPHERAL_PORT}:6055" \
            --volume "$DATA_DIR:/data" \
            "$IMAGE"
        CONTAINER_ID=
        ;;
    -h|--help)
        usage
        ;;
    *)
        usage >&2
        exit 1
        ;;
esac
