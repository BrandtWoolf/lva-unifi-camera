# LVA + UniFi camera as microphone

Uses a [Linux Voice Assistant](https://github.com/OHF-Voice/linux-voice-assistant)
container with a **UniFi G4 Instant** as the microphone. A small `audio-bridge`
container runs its own PulseAudio and streams the camera's RTSP audio into a
virtual mic named `camera_mic`; LVA connects to that PulseAudio socket.

```
G4 Instant --RTSP(AAC)--> ffmpeg --> PulseAudio "camera_mic" --> LVA --> Home Assistant
                         [------- audio-bridge container -------]
```

No host sound card or host PipeWire/PulseAudio is required — everything is virtual.

## 1. Enable RTSP on the camera
In UniFi Protect: **the G4 Instant > Settings > Advanced > RTSP**, tick a stream,
and make sure the camera **microphone is enabled**. Copy the URL, e.g.
`rtsp://<console-ip>:7447/<streamId>`.

## 2. Configure
```sh
cp .env.example .env
```
Edit `.env` and set `RTSP_URL` to that URL. Leave the rest as-is.

## 3. Start
```sh
docker compose up -d --build
docker compose logs -f audio-bridge        # expect "virtual mic 'camera_mic' available"
```

## 4. Verify the mic works (no Home Assistant needed)
Confirm the source exists:
```sh
docker compose exec audio-bridge pactl list sources short
# ... camera_mic  module-pipe-source.c  s16le 1ch 16000Hz ...
```

Confirm real audio is flowing (talk near the camera during this 3s capture):
```sh
docker compose exec audio-bridge bash -c \
  'parec -d camera_mic --format=s16le --rate=16000 --channels=1 --raw \
   | ffmpeg -f s16le -ar 16000 -ac 1 -t 3 -i - -af volumedetect -f null - 2>&1 \
   | grep -E "mean_volume|max_volume"'
```
- `mean_volume` around **-25 to -45 dB** with speech = working.
- `mean_volume` near **-91 dB** = silence (check camera mic is enabled / correct stream).

## 5. Connect to Home Assistant
LVA speaks the ESPHome protocol. In Home Assistant:
**Settings > Devices & services > Add integration > ESPHome**, host = this
machine's IP, port `6053`. It should appear as an Assist satellite. (It may also
be auto-discovered.)

## Notes / next steps
- **Speaker/talkback is not wired yet** — this covers the microphone only. Until
  then, LVA's own sounds are sent to a discarded `lva_out` sink.
- Latency: RTSP adds ~1–2 s; the low-delay flags in the bridge reduce it.
- When we add the camera speaker, expect an **echo** issue (the camera mic hears
  its own output) since there's no acoustic echo cancellation.

## Files
- `docker-compose.yml` — audio-bridge + LVA services and a shared `pulse` volume.
- `.env` — camera URL and LVA settings.
- `audio-bridge/` — PulseAudio + ffmpeg bridge image.
