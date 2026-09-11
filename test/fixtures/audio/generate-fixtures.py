#!/usr/bin/env python3
"""Generate deterministic, redistributable audio fixtures for native tests."""

import math
from pathlib import Path
import shutil
import struct
import subprocess
import wave

ROOT = Path(__file__).resolve().parent
AMPLITUDE = 8_192
FREQUENCY = 440.0


def samples(sample_rate: int, start_frame: int, frame_count: int) -> list[int]:
    return [
        round(AMPLITUDE * math.sin(2.0 * math.pi * FREQUENCY * frame / sample_rate))
        for frame in range(start_frame, start_frame + frame_count)
    ]


def write_wav(path: Path, sample_rate: int, values: list[int], channels: int = 2) -> None:
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(b"".join(struct.pack("<h", value) * channels for value in values))


def optional_compressed(source: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        return
    formats = (("flac", ["-c:a", "flac"]), ("m4a", ["-c:a", "alac"]), ("mp3", ["-c:a", "libmp3lame"]))
    for suffix, args in formats:
        destination = ROOT / f"tone-48000.{suffix}"
        subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), *args, str(destination)],
            check=True,
        )


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for rate in (44_100, 48_000, 96_000):
        write_wav(ROOT / f"pcm-{rate}.wav", rate, samples(rate, 0, rate // 4))

    gapless_rate = 48_000
    half = 2_400
    write_wav(ROOT / "gapless-a.wav", gapless_rate, samples(gapless_rate, 0, half))
    write_wav(ROOT / "gapless-b.wav", gapless_rate, samples(gapless_rate, half, half))

    valid = (ROOT / "pcm-48000.wav").read_bytes()
    (ROOT / "truncated.wav").write_bytes(valid[:40])
    (ROOT / "corrupt.wav").write_bytes(b"RIFF\x04\x00\x00\x00NOPE")
    optional_compressed(ROOT / "pcm-48000.wav")


if __name__ == "__main__":
    main()
