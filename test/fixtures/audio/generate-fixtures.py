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


def ogg_page(packet: bytes, header_type: int = 2, sequence: int = 0, granule: int = 0, serial: int = 1) -> bytes:
    page = bytearray(b"OggS" + bytes([0, header_type]) + struct.pack("<QIIIB", granule, serial, sequence, 0, 1) + bytes([len(packet)]) + packet)
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
    def stream(head: bytes = packet, *, tags_type: int = 0, audio_type: int = 4,
               tags_sequence: int = 1, audio_sequence: int = 2, tags_serial: int = 1) -> bytes:
        return (ogg_page(head) + ogg_page(tags, header_type=tags_type, sequence=tags_sequence, serial=tags_serial) +
                ogg_page(audio, header_type=audio_type, sequence=audio_sequence, granule=960))

    complete = stream()
    path.write_bytes(complete)
    head_page = ogg_page(packet)
    corrupt = bytearray(head_page)
    corrupt[-1] ^= 1
    (ROOT / "corrupt-crc.ogg").write_bytes(corrupt)
    (ROOT / "truncated-opushead.ogg").write_bytes(stream(b"OpusHead\x01\x02"))
    (ROOT / "continued-first-page.ogg").write_bytes(ogg_page(packet, header_type=3))
    (ROOT / "non-bos-first-page.ogg").write_bytes(ogg_page(packet, header_type=0))
    (ROOT / "trailing-opushead.ogg").write_bytes(stream(packet + b"\x00"))
    unassigned = packet[:-1] + bytes([254]) + bytes([1, 1, 0, 1])
    (ROOT / "unassigned-mapping-family.ogg").write_bytes(stream(unassigned))
    family_two = packet[:-1] + bytes([2]) + bytes([1, 1, 0, 1])
    (ROOT / "assigned-mapping-family-2.ogg").write_bytes(stream(family_two))
    (ROOT / "opus-version-0.ogg").write_bytes(stream(packet[:8] + bytes([0]) + packet[9:]))
    (ROOT / "header-only.ogg").write_bytes(ogg_page(packet, header_type=6))
    (ROOT / "missing-comment.ogg").write_bytes(ogg_page(packet) + ogg_page(audio, header_type=4, sequence=1, granule=960))
    (ROOT / "missing-audio.ogg").write_bytes(ogg_page(packet) + ogg_page(tags, header_type=4, sequence=1))
    (ROOT / "missing-eos.ogg").write_bytes(stream(audio_type=0))
    (ROOT / "sequence-error.ogg").write_bytes(stream(tags_sequence=2, audio_sequence=3))
    (ROOT / "serial-error.ogg").write_bytes(stream(tags_serial=2))
    (ROOT / "continuation-error.ogg").write_bytes(stream(tags_type=1))
    (ROOT / "reserved-mapping-family.ogg").unlink(missing_ok=True)


def main() -> None:
    ROOT.mkdir(parents=True, exist_ok=True)
    for rate in (44_100, 48_000, 96_000):
        write_wav(ROOT / f"pcm-{rate}.wav", rate, samples(rate, 0, rate // 4))

    gapless_rate = 48_000
    # Split away from a sine zero crossing / whole period so boundary errors
    # cannot hide behind identical end/start samples. Exact tolerance: 0 frames.
    split_frame = 2_401
    total_frames = 4_800
    continuous = samples(gapless_rate, 0, total_frames)
    write_wav(ROOT / "gapless-a.wav", gapless_rate, continuous[:split_frame])
    write_wav(ROOT / "gapless-b.wav", gapless_rate, continuous[split_frame:])
    decoded = []
    for name in ("gapless-a.wav", "gapless-b.wav"):
        with wave.open(str(ROOT / name), "rb") as source:
            assert source.getframerate() == gapless_rate
            raw = struct.unpack("<" + "h" * source.getnframes() * 2, source.readframes(source.getnframes()))
            assert raw[::2] == raw[1::2]
            decoded.extend(raw[::2])
    assert decoded == continuous, "Gapless fixture contains inserted or duplicated PCM frames"
    print(f"Gapless WAV verified: {split_frame} + {total_frames - split_frame} frames; 0 inserted, 0 duplicated")

    valid = (ROOT / "pcm-48000.wav").read_bytes()
    (ROOT / "truncated.wav").write_bytes(valid[:40])
    (ROOT / "corrupt.wav").write_bytes(b"RIFF\x04\x00\x00\x00NOPE")
    (ROOT / "corrupt.ogg").write_bytes(b"OggS invalid")
    write_minimal_ogg(ROOT / "valid-opus.ogg")
    optional_compressed(ROOT / "pcm-48000.wav")


if __name__ == "__main__":
    main()
