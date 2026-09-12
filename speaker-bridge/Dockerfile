FROM node:24-trixie-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        ffmpeg \
        pulseaudio-utils \
    && npm install --omit=dev unifi-protect@5.3.1 \
    && rm -rf /var/lib/apt/lists/*

COPY speaker-bridge.mjs /app/speaker-bridge.mjs

ENTRYPOINT ["node", "/app/speaker-bridge.mjs"]
