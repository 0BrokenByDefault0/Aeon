"""Build reproducible OTF and WOFF Aeon Nocturne assets from one source.

The checked-in WOFF is a valid canonical source for release rebuilds. Passing an
unmodified Latin Modern Roman 17 OTF recreates Aeon's ligatures before export.
Requires fonttools[woff].
"""

from argparse import ArgumentParser
from pathlib import Path

from fontTools.feaLib.builder import addOpenTypeFeaturesFromString
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "app" / "fonts"
DEFAULT_SOURCE = OUTPUT / "AeonNocturne-Regular.woff"
FIXED_FONT_TIMESTAMP = 3_786_825_600


def add_aeon_glyphs(font: TTFont) -> None:
    if "aeon_HE" in font.getGlyphOrder():
        return
    glyph_set = font.getGlyphSet()
    top = font["CFF "].cff.topDictIndex[0]
    charstrings = top.CharStrings
    rules: list[str] = []

    def add(name: str, components: list[tuple[str, tuple]], width: int, swash: bool = False) -> None:
        pen = T2CharStringPen(width, glyph_set)
        for glyph, transform in components:
            glyph_set[glyph].draw(TransformPen(pen, transform))
        if swash:
            pen.moveTo((400, 85))
            pen.curveTo((545, -50), (740, -132), (1010, 12))
            pen.curveTo((777, -170), (539, -98), (390, 73))
            pen.closePath()
        value = pen.getCharString(private=top.Private, globalSubrs=font["CFF "].cff.GlobalSubrs)
        charstrings.charStrings[name] = len(charstrings.charStringsIndex)
        charstrings.charStringsIndex.append(value)
        top.charset.append(name)
        font["hmtx"][name] = (round(width), 0)

    overlaps = {"HE": 145, "TH": 170, "AE": 175, "LL": 140, "OO": 200, "RA": 135, "TT": 180, "ER": 135}
    for pair, overlap in overlaps.items():
        first, second = pair
        first_width = font["hmtx"][first][0]
        second_width = font["hmtx"][second][0]
        offset = first_width - overlap
        name = f"aeon_{pair}"
        add(name, [(first, (1, 0, 0, 1, 0, 0)), (second, (1, 0, 0, 1, offset, 0))], offset + second_width, pair == "RA")
        rules.append(f"sub {first} {second} by {name};")
    for pair in ["OU", "QU"]:
        name = f"aeon_{pair}"
        add(name, [(pair[0], (1, 0, 0, 1, 0, 0)), ("U", (0.60, 0, 0, 0.60, 151, 135))], 720)
        rules.append(f"sub {pair[0]} U by {name};")
    for pair in ["st", "ft"]:
        first_width = font["hmtx"][pair[0]][0]
        second_width = font["hmtx"][pair[1]][0]
        offset = first_width - 28
        name = f"aeon_{pair}"
        add(name, [(pair[0], (1, 0, 0, 1, 0, 0)), (pair[1], (1, 0, 0, 1, offset, 0))], offset + second_width)
        rules.append(f"sub {pair[0]} {pair[1]} by {name};")

    font.setGlyphOrder(top.charset)
    font["maxp"].numGlyphs = len(top.charset)
    standard = []
    for characters, glyph in [("ff", "f_f"), ("fi", "f_i"), ("fl", "f_l"), ("ffi", "f_f_i"), ("ffl", "f_f_l")]:
        if glyph in font.getGlyphOrder():
            standard.append(f"sub {' '.join(characters)} by {glyph};")
    features = "languagesystem DFLT dflt; languagesystem latn dflt; feature liga {\n" + "\n".join(standard + rules) + "\n} liga;"
    addOpenTypeFeaturesFromString(font, features)


def normalize_metadata(font: TTFont) -> None:
    values = {
        1: "Aeon Nocturne",
        2: "Regular",
        3: "Aeon-Nocturne-5.0",
        4: "Aeon Nocturne Regular",
        6: "AeonNocturne-Regular",
        16: "Aeon Nocturne",
        17: "Regular",
    }
    for name_id, value in values.items():
        font["name"].setName(value, name_id, 3, 1, 0x409)
        font["name"].setName(value, name_id, 1, 0, 0)
    top = font["CFF "].cff.topDictIndex[0]
    top.FamilyName = "Aeon Nocturne"
    top.FullName = "Aeon Nocturne Regular"
    font["CFF "].cff.fontNames = ["AeonNocturne-Regular"]
    font["name"].setName(
        "Modified Latin Modern Roman 17 by B. Jackowski and J. M. Nowacki. "
        "Aeon interlocking glyphs and swash additions, 2026. Distributed under GUST Font License / LPPL 1.3c.",
        0,
        3,
        1,
        0x409,
    )
    if "head" in font:
        font["head"].created = FIXED_FONT_TIMESTAMP
        font["head"].modified = FIXED_FONT_TIMESTAMP


def main() -> None:
    parser = ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    arguments = parser.parse_args()
    OUTPUT.mkdir(exist_ok=True)
    font = TTFont(arguments.source, recalcTimestamp=False)
    add_aeon_glyphs(font)
    normalize_metadata(font)

    font.flavor = None
    font.save(OUTPUT / "AeonNocturne-Regular.otf", reorderTables=False)
    font.flavor = "woff"
    font.save(OUTPUT / "AeonNocturne-Regular.woff", reorderTables=False)
    print("Built AeonNocturne-Regular.otf and AeonNocturne-Regular.woff")


if __name__ == "__main__":
    main()
