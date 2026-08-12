#!/usr/bin/env python3
"""Regenerate the audio fixtures used by the test suite.

They are tiny synthetic MP3s carrying real ID3 tags — enough for the tag
parser, the grouping rules and the artwork pipeline to be exercised for
real, without shipping anyone's music in the repository.
"""
import io, zipfile
from PIL import Image

def cover(colour):
    buf = io.BytesIO()
    Image.new("RGB", (200, 200), colour).save(buf, "JPEG")
    return buf.getvalue()

def ss(n):            # ID3 syncsafe integer
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])

def frame23(fid, payload):
    return fid.encode() + len(payload).to_bytes(4, "big") + b"\x00\x00" + payload

def frame24(fid, payload, flags=b"\x00\x00"):
    return fid.encode() + ss(len(payload)) + flags + payload

def text(fid, value, v24=False):
    p = b"\x03" + value.encode()
    return (frame24 if v24 else frame23)(fid, p)

def apic_payload(jpeg, prefix=b""):
    return prefix + b"\x03" + b"image/jpeg\x00" + b"\x03" + b"\x00" + jpeg

def unsync(data):
    out = bytearray()
    for i, b in enumerate(data):
        out.append(b)
        if b == 0xFF and (i + 1 >= len(data) or data[i + 1] == 0x00 or (data[i + 1] & 0xE0) == 0xE0):
            out.append(0x00)
    return bytes(out)

def tag(version, body, header_flags=0x00):
    return b"ID3" + bytes([version, 0, header_flags]) + ss(len(body)) + body + bytes(400)

def mp3(title, artist, album, genre, track, colour, art=True):
    body = text("TIT2", title) + text("TPE1", artist) + text("TRCK", str(track)) + text("TDRC", "2024")
    if album:
        body += text("TALB", album)
    if genre:
        body += text("TCON", genre)
    if art:
        body += frame23("APIC", apic_payload(cover(colour)))
    return tag(3, body)

LIBRARY = [
    ("Ken Carson",       "Rage",    ["X", "A Great Chaos", "Project X"],            "#5a2a44"),
    ("Playboi Carti",    "Rage",    ["Whole Lotta Red", "Die Lit"],                 "#6a1f2a"),
    ("Aphex Twin",       "Ambient", ["SAW II", "Drukqs", "Syro", "Collapse"],       "#1f4a5a"),
    ("Boards of Canada", "Ambient", ["Geogaddi", "Campfire"],                       "#2a4a2f"),
    ("Burial",           "Dubstep", ["Untrue"],                                     "#2a2a5a"),
    ("Four Tet",         "Dubstep", ["Rounds", "Sixteen Oceans"],                   "#3a2a5a"),
    ("Solo One",         "Jazz",    ["Alpha"],                                      "#5a4a1f"),
    ("Solo Two",         "Jazz",    ["Beta"],                                       "#5a3a1f"),
    ("Solo Three",       "Rock",    ["Gamma"],                                      "#4a2a2a"),
    ("Solo Four",        "Rock",    ["Delta"],                                      "#3a3a2a"),
    ("Solo Five",        "",        ["Untagged Thing"],                             "#333333"),
    ("Solo Six",         "",        ["Another Untagged"],                           "#3a3a3a"),
]

def build_library(path="library.zip"):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for artist, genre, albums, colour in LIBRARY:
            for album in albums:
                for n in (1, 2):
                    z.writestr(f"{artist} - {album}/{n:02d} Track {n}.mp3",
                               mp3(f"{album} pt{n}", artist, album, genre, n, colour))

def build_split(path="split.zip"):
    """One record whose tracks disagree about the album name."""
    rows = [("intro", "XPERIMENTOR"), ("margiela", "XPERIMENTOR"),
            ("the acronym", "XPERIMENTOR (Deluxe)"), ("wtf?", ""),
            ("outro", "Xperimentor [Bonus Tracks]")]
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        for i, (title, album) in enumerate(rows, 1):
            z.writestr(f"Ken Carson - Xperimentor/{i:02d} {title}.mp3",
                       mp3(title, "Ken Carson", album, "Rage", i, "#5a2a44"))

def build_single(path="single.zip"):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("Ken Carson - Vampire Hour/01 vampire hour.mp3",
                   mp3("vampire hour", "Ken Carson", "Vampire Hour", "Rage", 1, "#2a1a3a"))

def build_edge(path="edge3.zip"):
    """Tag layouts that used to destroy embedded artwork."""
    art = cover("#3a2a55")
    payload = apic_payload(art)
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        # v2.4 with a data-length indicator
        z.writestr("Dli/01 a.mp3", tag(4,
            text("TIT2", "a", True) + text("TPE1", "Ken Carson", True) + text("TALB", "DLI", True)
            + frame24("APIC", ss(len(payload)) + payload, b"\x00\x01")))
        # v2.3 with the whole tag unsynchronised
        body = (text("TIT2", "b") + text("TPE1", "Ken Carson") + text("TALB", "UNSYNCTHREE")
                + frame23("APIC", payload))
        z.writestr("Unsyncthree/01 b.mp3", tag(3, unsync(body), 0x80))
        # v2.4 with frame-level unsynchronisation
        z.writestr("Frameun/01 c.mp3", tag(4,
            text("TIT2", "c", True) + text("TPE1", "Ken Carson", True) + text("TALB", "FRAMEUN", True)
            + frame24("APIC", unsync(payload), b"\x00\x02")))
        # v2.4 with a grouping byte AND a data-length indicator
        z.writestr("Grouped/01 d.mp3", tag(4,
            text("TIT2", "d", True) + text("TPE1", "Ken Carson", True) + text("TALB", "GROUPED", True)
            + frame24("APIC", b"\x07" + ss(len(payload)) + payload, b"\x00\x41")))
        # a plain v2.3 control
        z.writestr("Plainthree/01 e.mp3", tag(3,
            text("TIT2", "e") + text("TPE1", "Ken Carson") + text("TALB", "PLAINTHREE")
            + frame23("APIC", payload)))
        # genuinely corrupt art — must be dropped, never shown broken
        z.writestr("Broken/01 f.mp3", tag(3,
            text("TIT2", "f") + text("TPE1", "Ken Carson") + text("TALB", "BROKEN")
            + frame23("APIC", apic_payload(b"\xff\xd8\xff\xe0not-actually-a-jpeg" * 4))))

if __name__ == "__main__":
    build_library(); build_split(); build_single(); build_edge()
    print("fixtures written")
