FROM node:24.21.0-trixie-slim AS node

FROM ghcr.io/ohf-voice/linux-voice-assistant:1.1.15

ARG BUILD_ARCH
ARG BUILD_VERSION

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ffmpeg \
        jq \
        pulseaudio \
    && rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/ /usr/local/

WORKDIR /opt/unifi-camera-voice
RUN npm install --omit=dev --no-package-lock unifi-protect@5.3.1

COPY rootfs /
RUN chmod +x \
    /usr/local/bin/audio-bridge.sh \
    /usr/local/bin/run-addon.sh

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant App: UniFi Camera Voice Assistant" \
    org.opencontainers.image.description="UniFi Protect camera microphone and talkback bridge for Home Assistant Assist" \
    org.opencontainers.image.source="https://github.com/BrandtWoolf/lva-unifi-camera"

ENTRYPOINT ["/usr/local/bin/run-addon.sh"]
