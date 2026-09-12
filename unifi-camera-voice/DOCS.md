# UniFi Camera Voice Assistant

This add-on turns a supported UniFi Protect camera into a Home Assistant Assist
satellite. It runs the RTSP microphone bridge, Linux Voice Assistant, and the
Protect speaker bridge together inside Home Assistant OS.

It is based on
[OHF-Voice/linux-voice-assistant](https://github.com/OHF-Voice/linux-voice-assistant),
which provides the Linux Voice Assistant runtime.

## Before installing

In UniFi Protect:

1. Enable the camera microphone and an RTSP stream under the camera's
   **Settings > Advanced > RTSP** page.
2. Copy the complete `rtsp://` or `rtsps://` URL.
3. Create a dedicated **local UniFi OS user**, not a UI.com/cloud user.
4. Grant that account Protect **Full Management** for the selected camera.

The broad permission is currently required by Protect's talkback API. Use a
unique password and do not reuse an administrator's credentials.

## Known supported devices

| Device | Microphone | Speaker talkback | Status |
|---|---|---|---|
| UniFi Protect G4 Instant | Yes | Yes | Tested and supported |

Other UniFi Protect cameras are currently unverified. Compatible cameras must
provide an audio-enabled RTSP(S) stream and speaker talkback through Protect.

## Configuration

Configure all required values before starting:

- **Camera RTSP(S) URL**: the complete URL copied from Protect.
- **Protect camera name**: the camera's exact display name.
- **Protect controller**: hostname/IP and optional port, such as
  `192.168.1.1` or `https://unifi.local:443`.
- **Protect username/password**: the dedicated local account.
- **Verify controller TLS**: leave disabled for the usual self-signed local
  certificate; enable only when the certificate is trusted by the container.
- **Assist satellite name**: the device name shown in Home Assistant.
- **Microphone sample rate**: keep `16000` for Linux Voice Assistant.

Configuration and downloaded LVA state are stored in the add-on's private
`/data` directory and are included in Home Assistant backups.
The ESPHome device identity is also persisted there, so restarting or updating
the add-on does not cause a MAC-address mismatch in Home Assistant.

## Add the satellite to Home Assistant

After the add-on log reports that Linux Voice Assistant has started:

1. Follow Home Assistant's
   [local voice assistant guide](https://www.home-assistant.io/voice_control/voice_remote_local_assistant/)
   to install local speech-to-text and text-to-speech services and create an
   Assist voice assistant. In a typical local setup, Speech-to-Phrase or
   Whisper handles speech-to-text and Piper handles text-to-speech.
2. Go to **Settings > Devices & services > Add integration**.
3. Select **ESPHome**.
4. Enter the Home Assistant host's LAN IP or hostname and port `6053`.
5. Finish setup, then assign the voice assistant you created and the desired
   wake word to the new Assist satellite.

The voice assistant defines how Home Assistant processes requests and generates
spoken responses; the satellite provides the camera microphone and speaker.
Also [expose the entities you want to control to Assist](https://www.home-assistant.io/voice_control/voice_remote_expose_devices/)
so voice commands can access them.

Port `6055` exposes LVA's peripheral API. Most installations only use `6053`.

## Troubleshooting

### Initial ESPHome setup keeps spinning

The initial ESPHome setup dialog can keep spinning even though Home Assistant
has added the device successfully. Go to **Settings > Devices & services >
ESPHome** and open the new satellite device. Confirm that its **Assistant** and
**Wake word** settings are assigned correctly, then review the remaining device
settings before testing a voice request.

The log should show, in order:

1. the private PulseAudio server and virtual microphone becoming ready;
2. Linux Voice Assistant starting; and
3. the speaker bridge connecting to the named camera.

If the camera is not found or talkback is unauthorized, verify the exact camera
name, use a local (not cloud/SSO) account, and confirm Protect Full Management.
If microphone audio is silent, verify that the selected RTSP stream includes
audio and that the camera microphone is enabled.

The camera can hear its own speaker. Reduce speaker volume or shorten responses
if placement causes echo or feedback.
