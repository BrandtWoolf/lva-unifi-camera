# UniFi Protect camera voice satellite

Turn a supported UniFi Protect camera into a full Home Assistant Assist
satellite: camera microphone in, wake-word/Assist processing through Linux Voice
Assistant (LVA), and spoken responses back through the camera speaker.

## Quick start: one command

```sh
git clone https://github.com/BrandtWoolf/lva-unifi-camera.git
cd lva-unifi-camera
./start.sh
```

On the first run, the script:

1. validates Docker, Compose v2, and the Docker daemon;
2. securely prompts for the RTSP(S) URL, exact Protect camera name, controller,
   dedicated local username, and a hidden password;
3. writes owner-readable `.env` and `ufp.json` files;
4. builds and starts the microphone, LVA, and speaker bridges; and
5. waits until the full stack is healthy.

Later runs reuse the saved configuration, pull updates, rebuild the local
bridges, and start the stack:

```sh
./start.sh
```

The script rejects example placeholders and malformed values. It never prints
the password or configured RTSP URL. Existing configuration is not replaced
unless you explicitly run `./start.sh --configure`.

## Architecture and supported assumptions

```text
UniFi camera
  RTSP(S) audio -> ffmpeg -> PulseAudio camera_mic -> Linux Voice Assistant
                                                        | ESPHome API :6053
                                                        v
                                                   Home Assistant
                                                        |
                                  response audio -> PulseAudio lva_out.monitor
                                                        |
                                      Protect talkback API -> camera speaker
```

Everything audio-related runs inside Docker. The host does not need a sound
card, PipeWire, or PulseAudio. The stack assumes:

- an x64 or ARM64 Docker host reachable by Home Assistant;
- a UniFi Protect camera with an enabled microphone, RTSP(S), and speaker
  talkback support;
- AAC audio in the selected Protect stream;
- LVA's required 16 kHz mono microphone input; and
- ports `6053/tcp` (ESPHome API) and `6055/tcp` (LVA peripheral API) available
  on the Docker host.

It was built around a G4 Instant. Other Protect cameras should work when they
provide the same RTSP audio and Protect talkback capabilities, but are not all
tested.

## Prerequisites

- Docker Desktop, or Docker Engine with the Compose v2 plugin
- Home Assistant with an Assist voice pipeline and wake-word support configured
- Network access from this host to the Protect controller/camera
- Network access from Home Assistant to this host on TCP port `6053`

`start.sh` stops with a specific error if Docker, `docker compose`, or the daemon
is unavailable.

### Docker Desktop

Start Docker Desktop before running the script. On macOS and Windows, ensure the
repository is in a directory Docker Desktop can share. Linux containers are
required. Named volumes retain LVA downloads/preferences and PulseAudio state
across container replacement; `docker compose down -v` intentionally deletes
that persistent state.

## Prepare UniFi Protect

### Enable camera microphone and RTSP(S)

In Protect, open the camera and go to **Settings > Advanced > RTSP**:

1. enable the camera microphone;
2. enable one RTSP stream; and
3. copy its complete URL.

Typical forms are:

```text
rtsp://CONTROLLER_OR_CAMERA_IP:7447/STREAM_ID
rtsps://CONTROLLER_OR_CAMERA_IP:7441/STREAM_ID?enableSrtp
```

Use the exact URL Protect provides. The bridge uses TCP transport and
automatically reconnects if the stream drops.

### Create the local talkback account

RTSP is receive-only; camera speaker talkback uses Protect's authenticated API.
Create a **dedicated local UniFi OS user**, not a UI.com/cloud/SSO user. Grant
that account Protect **Full Management** for the selected camera.

This broad local permission is currently required for Protect talkback. Use a
unique password, limit the account to the needed console/camera where your
Protect version permits it, and do not reuse a personal administrator account.
The setup prompt asks for:

- the controller hostname/IP (an `https://` prefix and custom port are accepted);
- this local username and password; and
- the camera's exact Protect display name.

Self-signed local controller certificates are supported by the default
`"verifyTls": false`. See [Credential security and persistence](#credential-security-and-persistence).

## Add it to Home Assistant

After `./start.sh` reports `Ready`:

1. Go to **Settings > Devices & services > Add integration**.
2. Select **ESPHome**.
3. Enter the Docker host's LAN IP or hostname and port `6053`.
4. Finish setup, then assign the desired Assist pipeline and wake word to the
   new Assist satellite.

The default device name is `unifi-camera-satellite`. Port `6055` exposes LVA's
peripheral API; most Home Assistant setups only need `6053`.

### Optional status-light automation

Home Assistant's Assist Satellite triggers can turn a nearby light on while the
satellite listens and off when the interaction returns to idle. Replace the
entity IDs below:

```yaml
alias: UniFi camera satellite status light
mode: restart
triggers:
  - trigger: assist_satellite.started_listening
    target:
      entity_id: assist_satellite.unifi_camera_satellite
    id: listening
  - trigger: assist_satellite.idle
    target:
      entity_id: assist_satellite.unifi_camera_satellite
    id: idle
actions:
  - choose:
      - conditions: "{{ trigger.id == 'listening' }}"
        sequence:
          - action: light.turn_on
            target:
              entity_id: light.voice_status
            data:
              brightness_pct: 35
              rgb_color: [0, 120, 255]
    default:
      - action: light.turn_off
        target:
          entity_id: light.voice_status
```

These are the integration's `assist_satellite.started_listening` and
`assist_satellite.idle` triggers, rather than fragile raw state matching.

## Verify microphone and speaker

### Microphone

Confirm the virtual 16 kHz mono source exists:

```sh
docker compose exec audio-bridge pactl list sources short
```

The output should include `camera_mic`, `s16le`, `1ch`, and `16000Hz`.

Measure three seconds while speaking near the camera:

```sh
docker compose exec audio-bridge bash -c \
  'parec -d camera_mic --format=s16le --rate=16000 --channels=1 --raw |
   ffmpeg -hide_banner -f s16le -ar 16000 -ac 1 -t 3 -i - \
   -af volumedetect -f null - 2>&1 |
   grep -E "mean_volume|max_volume"'
```

Speech commonly produces a mean around `-25` to `-45 dB`; approximately
`-91 dB` indicates silence.

### Speaker/talkback

Use Home Assistant's Assist Satellite **Announce** action or run a normal voice
request that produces speech. Watch the bridge while testing:

```sh
docker compose logs -f speaker-bridge linux-voice-assistant
```

The speaker bridge should log that it connected to the exact camera and show
the camera-provided AAC format. If it repeatedly reconnects, check the local
account, Full Management permission, camera name, and speaker support.

## Daily commands

| Task | Command |
|---|---|
| Start, update images, rebuild, and wait | `./start.sh` |
| Stop containers (keep configuration/data) | `docker compose down` |
| Restart without pulling/building | `docker compose up -d` |
| Follow all logs | `docker compose logs -f` |
| Follow one bridge | `docker compose logs -f audio-bridge` |
| Show status/health | `docker compose ps` |
| Validate without starting | `./start.sh --check` |
| Re-enter and replace configuration | `./start.sh --configure` |

Because `.env` sets `COMPOSE_PROFILES=speaker`, ordinary Compose commands include
the speaker bridge. If you remove that setting during advanced configuration,
add `--profile speaker` to commands that should include talkback.

## Advanced manual setup

The interactive script is recommended. For automation or manual provisioning:

```sh
cp .env.example .env
cp ufp.json.example ufp.json
chmod 600 .env ufp.json
# Replace every REPLACE_* / CONSOLE_IP / stream placeholder.
docker compose --profile speaker config --quiet
docker compose --profile speaker pull linux-voice-assistant
docker compose --profile speaker up -d --build
```

Do not source `.env` in a shell: an RTSP URL may contain shell-significant
characters. Compose reads it directly.

## Configuration reference

| Setting | Default | Purpose |
|---|---:|---|
| `COMPOSE_PROFILES` | `speaker` | Enables the talkback service |
| `RTSP_URL` | required | Complete camera RTSP(S) stream URL |
| `MIC_RATE` | `16000` | Mono microphone sample rate required by LVA |
| `CLIENT_NAME` | `unifi-camera-satellite` | ESPHome/LVA device name |
| `HOST` | `0.0.0.0` | LVA bind address inside the container |
| `LVA_PORT` | `6053` | Published ESPHome API port |
| `LVA_PERIPHERAL_PORT` | `6055` | Published LVA peripheral API port |
| `AUDIO_INPUT_DEVICE` | `camera_mic` | PulseAudio virtual microphone |
| `AUDIO_INPUT_CHANNELS` | `1` | Mono input |
| `AUDIO_OUTPUT_DEVICE` | `pulse/lva_out` | Valid MPV PulseAudio output |
| `TALKBACK_OUTPUT_MONITOR` | `lva_out.monitor` | Source captured for talkback |
| `LISTEN_DURING_WAKE_SOUND` | `1` | Avoids missing speech while wake audio plays |
| `LVA_USER_ID` / `LVA_USER_GROUP` | `1000` | Ownership for persistent LVA data |
| `LVA_IMAGE` / `LVA_IMAGE_TAG` | upstream / `latest` | Optional LVA image override |
| `ENABLE_DEBUG` | unset | Optional verbose LVA diagnostics |
| `LIST_DEVICES` | unset | Optional LVA audio-device listing |

`ufp.json` contains `controller`, `username`, `password`, and `verifyTls`.
Keep `verifyTls: false` for the usual self-signed local Protect certificate.
Set it to `true` only when the controller presents a certificate trusted inside
the container.

## Credential security and persistence

`.env` may contain credentials embedded in an RTSP URL. `ufp.json` contains the
local Protect password. Both are ignored by Git and `start.sh` sets mode `0600`.
The Protect file is mounted read-only into only the speaker bridge. The setup
script writes temporary files with a private umask, atomically replaces the
final files, hides RTSP URL and password input, and does not echo either secret.

The files remain on the Docker host until you remove them. Docker named volumes
retain LVA configuration, downloaded wake models, custom sounds, and runtime
data. `docker compose down` preserves all of these; `docker compose down -v`
removes the named volumes but not `.env` or `ufp.json`.

## Troubleshooting

### Wake word is never detected

- Verify live microphone levels with the command above.
- Confirm the camera microphone and the selected RTSP stream's audio are enabled.
- In Home Assistant, assign a pipeline with a wake-word engine/model.
- Check `AUDIO_INPUT_DEVICE=camera_mic`, `AUDIO_INPUT_CHANNELS=1`, and
  `MIC_RATE=16000`.
- Inspect `docker compose logs -f audio-bridge linux-voice-assistant`.

### Wake detection hangs after the wake sound

MPV must receive its own device syntax, not a raw PulseAudio monitor/source.
Keep:

```dotenv
AUDIO_OUTPUT_DEVICE="pulse/lva_out"
TALKBACK_OUTPUT_MONITOR="lva_out.monitor"
LISTEN_DURING_WAKE_SOUND="1"
```

An invalid MPV output device can block wake-sound playback and make listening
appear hung. Re-run `./start.sh --configure` to restore known-working defaults.

### The microphone exists but is silent

- Speak while running the volume test; a static source listing only proves the
  virtual device exists.
- Verify the RTSP(S) URL and camera microphone setting.
- Check `audio-bridge` logs for ffmpeg authentication, TLS, codec, or reconnect
  errors.
- Prefer the URL copied directly from Protect; do not invent the stream ID.

### Talkback is unauthorized or continuously reconnects

- Use a local UniFi OS account, not a cloud/SSO account.
- Grant Protect **Full Management** and verify the account can access the exact
  camera.
- Camera matching is case-insensitive, but the full display name must otherwise
  match `PROTECT_CAMERA`.
- Run `./start.sh --configure` after changing credentials.
- Confirm the camera reports speaker support in `speaker-bridge` logs.

### PulseAudio state appears stale

First recreate the containers and shared runtime volume:

```sh
docker compose down
docker volume ls \
  --filter "label=com.docker.compose.project=$(basename "$PWD")" \
  --filter "label=com.docker.compose.volume=pulse"
# After confirming the listed volume belongs to this checkout:
docker volume rm "$(docker volume ls -q \
  --filter "label=com.docker.compose.project=$(basename "$PWD")" \
  --filter "label=com.docker.compose.volume=pulse")"
./start.sh
```

If no volume is listed, inspect `docker volume ls` and remove only this
project's PulseAudio volume. Do not remove the LVA data volumes unless you
intend to reset LVA preferences/models.

### Talkback is delayed, clipped, or choppy

- Use wired Ethernet where possible and keep the Docker host/controller/camera
  on a low-latency LAN.
- RTSP microphone input commonly adds roughly 1–2 seconds before processing.
- The bridge keeps talkback connected and uses low-buffer capture/encoding, but
  Protect and camera firmware add their own latency.
- Check host CPU pressure, packet loss, and repeated reconnects in both bridge
  logs.
- Avoid changing `lva_out.monitor`; capturing the wrong source causes silence
  or buffering.

### Echo or feedback

The camera microphone can hear its own speaker, and this virtual path does not
provide hardware acoustic echo cancellation. Lower the camera speaker volume,
shorten responses, increase physical separation, or use a camera/placement with
better built-in echo handling.

## Repository components

- `start.sh` - safe first-run configuration, update/start, and health waiting
- `docker-compose.yml` - LVA, bridge services, health checks, and named volumes
- `audio-bridge/` - RTSP(S) to PulseAudio `camera_mic`
- `speaker-bridge/` - `lva_out.monitor` to authenticated Protect talkback
- `.env.example` / `ufp.json.example` - advanced/manual configuration templates
