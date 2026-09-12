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

## Add the satellite to Home Assistant

After the add-on log reports that Linux Voice Assistant has started:

1. Go to **Settings > Devices & services > Add integration**.
2. Select **ESPHome**.
3. Enter the Home Assistant host's LAN IP or hostname and port `6053`.
4. Assign the desired Assist pipeline and wake word to the new satellite.

Port `6055` exposes LVA's peripheral API. Most installations only use `6053`.

## Troubleshooting

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
