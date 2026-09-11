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
    destinations = [ROOT / f"tone-48000.{suffix}" for suffix in ("flac", "m4a", "mp3")]
    if not ffmpeg:
        for destination in destinations:
            destination.unlink(missing_ok=True)
        return
    formats = (("flac", ["-c:a", "flac"]), ("m4a", ["-c:a", "alac"]), ("mp3", ["-c:a", "libmp3lame"]))
    for suffix, args in formats:
        destination = ROOT / f"tone-48000.{suffix}"
        subprocess.run(
            [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), *args, str(destination)],
            check=True,
        )


def write_minimal_ogg(path: Path) -> None:
    packet = b"OpusHead" + bytes([1, 2]) + struct.pack("<HIhB", 312, 48_000, 0, 0)
    page = bytearray(b"OggS" + bytes([0, 2]) + struct.pack("<QIIIB", 0, 1, 0, 0, 1) + bytes([len(packet)]) + packet)
    crc = 0
    for byte in page:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    page[22:26] = struct.pack("<I", crc)
    path.write_bytes(page)
    corrupt = bytearray(page)
    corrupt[-1] ^= 1
    (ROOT / "corrupt-crc.ogg").write_bytes(corrupt)


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
    (ROOT / "corrupt.ogg").write_bytes(b"OggS invalid")
    write_minimal_ogg(ROOT / "valid-opus.ogg")
    optional_compressed(ROOT / "pcm-48000.wav")


if __name__ == "__main__":
    main()
