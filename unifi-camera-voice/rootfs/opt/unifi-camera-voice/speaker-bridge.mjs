import { spawn } from "node:child_process";
import { readFile, rm, writeFile } from "node:fs/promises";
import { setTimeout as sleep } from "node:timers/promises";
import { ProtectClient } from "unifi-protect";

const credentialsPath =
  process.env.UFP_CREDENTIALS_PATH ?? "/data/ufp.json";
const cameraName = process.env.PROTECT_CAMERA;
const monitor = process.env.TALKBACK_OUTPUT_MONITOR ?? "lva_out.monitor";
const pulseServer = process.env.PULSE_SERVER ?? "unix:/run/pulse/native";
const readinessPath = "/tmp/talkback-ready";
const shutdown = new AbortController();

async function* adtsFrames(source) {
  let buffered = Buffer.alloc(0);

  for await (const chunk of source) {
    buffered = Buffer.concat([buffered, chunk]);

    while (buffered.length >= 7) {
      if (buffered[0] !== 0xff || (buffered[1] & 0xf6) !== 0xf0) {
        const syncOffset = buffered.findIndex(
          (byte, index) =>
            index > 0 &&
            byte === 0xff &&
            index + 1 < buffered.length &&
            (buffered[index + 1] & 0xf6) === 0xf0,
        );

        if (syncOffset === -1) {
          buffered = buffered.subarray(Math.max(0, buffered.length - 1));
          break;
        }

        buffered = buffered.subarray(syncOffset);
      }

      if (buffered.length < 7) {
        break;
      }

      const frameLength =
        ((buffered[3] & 0x03) << 11) |
        (buffered[4] << 3) |
        ((buffered[5] & 0xe0) >> 5);

      if (frameLength < 7) {
        throw new Error(`Invalid ADTS frame length: ${frameLength}`);
      }

      if (buffered.length < frameLength) {
        break;
      }

      yield buffered.subarray(0, frameLength);
      buffered = buffered.subarray(frameLength);
    }
  }
}

if (!cameraName) {
  throw new Error("PROTECT_CAMERA is required");
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.once(signal, () => shutdown.abort());
}

const credentials = JSON.parse(await readFile(credentialsPath, "utf8"));
const controller = new URL(
  credentials.controller.includes("://")
    ? credentials.controller
    : `https://${credentials.controller}`,
).host;

while (!shutdown.signal.aborted) {
  let parec;
  let ffmpeg;

  try {
    await rm(readinessPath, { force: true });
    await using client = await ProtectClient.connect({
      host: controller,
      username: credentials.username,
      password: credentials.password,
      verifyTls: credentials.verifyTls ?? false,
      signal: shutdown.signal,
    });

    const camera = client.cameras.find(
      (candidate) => candidate.name.toLowerCase() === cameraName.toLowerCase(),
    );

    if (!camera) {
      throw new Error(`Camera "${cameraName}" was not found in UniFi Protect`);
    }

    if (!camera.config.featureFlags.hasSpeaker) {
      throw new Error(`Camera "${camera.name}" does not report speaker support`);
    }

    const { channels, samplingRate } = camera.config.talkbackSettings;
    console.log(
      `[speaker-bridge] connected to "${camera.name}"; ` +
        `streaming ${samplingRate} Hz, ${channels} channel AAC`,
    );

    parec = spawn(
      "parec",
      [
        "--device",
        monitor,
        "--format=s16le",
        "--rate=48000",
        "--channels=2",
        "--latency-msec=20",
        "--raw",
      ],
      {
        env: { ...process.env, PULSE_SERVER: pulseServer },
        stdio: ["ignore", "pipe", "inherit"],
      },
    );

    ffmpeg = spawn(
      "ffmpeg",
      [
        "-hide_banner",
        "-loglevel",
        "warning",
        "-f",
        "s16le",
        "-ar",
        "48000",
        "-ac",
        "2",
        "-i",
        "pipe:0",
        "-acodec",
        "aac",
        "-profile:a",
        "aac_low",
        "-avioflags",
        "direct",
        "-fflags",
        "+flush_packets",
        "-flush_packets",
        "1",
        "-ar",
        String(samplingRate),
        "-ac",
        String(channels),
        "-b:a",
        "64k",
        "-f",
        "adts",
        "-muxdelay",
        "0",
        "pipe:1",
      ],
      { stdio: ["pipe", "pipe", "inherit"] },
    );

    parec.stdout.pipe(ffmpeg.stdin);

    await using session = await camera.talkback({ signal: shutdown.signal });
    await writeFile(readinessPath, "");
    await session.send(adtsFrames(ffmpeg.stdout), { signal: shutdown.signal });
  } catch (error) {
    if (!shutdown.signal.aborted) {
      console.error(
        `[speaker-bridge] ${error instanceof Error ? error.message : String(error)}`,
      );
    }
  } finally {
    await rm(readinessPath, { force: true });
    parec?.kill("SIGTERM");
    ffmpeg?.kill("SIGTERM");
  }

  if (!shutdown.signal.aborted) {
    console.log("[speaker-bridge] reconnecting in 3 seconds");
    await sleep(3000);
  }
}
