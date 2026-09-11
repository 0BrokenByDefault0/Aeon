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
        return
    formats = (("flac", ["-c:a", "flac"]), ("m4a", ["-c:a", "alac"]), ("mp3", ["-c:a", "libmp3lame"]))
    for suffix, args in formats:
        destination = ROOT / f"tone-48000.{suffix}"
        temporary = ROOT / f"tone-48000.tmp.{suffix}"
        temporary.unlink(missing_ok=True)
        try:
            subprocess.run(
                [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", str(source), *args, str(temporary)],
                check=True,
            )
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)


def ogg_page(packet: bytes, header_type: int = 2, sequence: int = 0, granule: int = 0) -> bytes:
    page = bytearray(b"OggS" + bytes([0, header_type]) + struct.pack("<QIIIB", granule, 1, sequence, 0, 1) + bytes([len(packet)]) + packet)
    crc = 0
    for byte in page:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    page[22:26] = struct.pack("<I", crc)
    return bytes(page)


def write_minimal_ogg(path: Path) -> None:
    packet = b"OpusHead" + bytes([1, 2]) + struct.pack("<HIhB", 312, 48_000, 0, 0)
    tags = b"OpusTags" + struct.pack("<I", 4) + b"Aeon" + struct.pack("<I", 0)
    audio = b"\xF8\xFF\xFE"
    head_page = ogg_page(packet)
    tags_page = ogg_page(tags, header_type=0, sequence=1)
    audio_page = ogg_page(audio, header_type=4, sequence=2, granule=960)
    path.write_bytes(head_page + tags_page + audio_page)
    corrupt = bytearray(head_page)
    corrupt[-1] ^= 1
    (ROOT / "corrupt-crc.ogg").write_bytes(corrupt)
    (ROOT / "truncated-opushead.ogg").write_bytes(ogg_page(b"OpusHead\x01\x02"))
    (ROOT / "continued-first-page.ogg").write_bytes(ogg_page(packet, header_type=3))
    (ROOT / "non-bos-first-page.ogg").write_bytes(ogg_page(packet, header_type=0))
    (ROOT / "trailing-opushead.ogg").write_bytes(ogg_page(packet + b"\x00"))
    reserved = packet[:-1] + bytes([2]) + bytes([1, 1, 0, 1])
    (ROOT / "reserved-mapping-family.ogg").write_bytes(ogg_page(reserved))


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
