# Changelog

## 0.1.2

- Persist the ESPHome device MAC so Home Assistant reconnects after add-on
  restarts and updates.
- Document the UniFi Protect G4 Instant as the currently verified supported
  camera.

## 0.1.1

- Clarify that the status-light automation uses the camera status-light switch
  provided by the UniFi Protect integration.
- Credit OHF-Voice/linux-voice-assistant as the project's upstream foundation.

## 0.1.0

- Initial Home Assistant OS add-on.
- Run the RTSP microphone bridge, Linux Voice Assistant, and Protect talkback
  bridge in a single supervised container.
- Persist assistant configuration and downloaded data across updates.
