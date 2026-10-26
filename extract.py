#!/usr/bin/env python3
"""Crop Balatro joker sprites and scene props out of the user's own Balatro.love.

Reads the packed game archive directly; nothing Balatro owns is redistributed.
Stdlib only -- zipfile, zlib and struct cover the archive and the atlas crop.

Atlas geometry is game.lua's `asset_atli` table: Jokers.png is a 10x16 grid of
71x95 tiles (x=column, y=row), one tile per `G.P_CENTERS` entry keyed `j_*`.
Tiles decode as 8-bit RGBA, non-interlaced, filter types 0-4.
"""

import argparse
import json
import os
import re
import struct
import sys
import zipfile
import zlib

# {atlas name: (file, tile width, tile height)}, from game.lua's asset_atli.
ATLAS = {
    "Jokers": ("Jokers.png", 71, 95),
    "cards_1": ("8BitDeck.png", 71, 95),
    "centers": ("Enhancers.png", 71, 95),
    "Booster": ("boosters.png", 71, 95),
    "icons": ("icons.png", 66, 66),
    "chips": ("chips.png", 29, 29),
    "tags": ("tags.png", 34, 34),
}

# {animation atlas: (file, tile width, tile height, frames)}, from animation_atli.
ANIM = {
    "shop_sign": ("ShopSignAnimation.png", 113, 57, 4),
    "blind_chips": ("BlindChips.png", 34, 34, 21),
}

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


# --------------------------------------------------------------- png codec --

def png_read(data):
    """Decode a non-interlaced 8-bit PNG into (width, height, channels, pixels)."""
    if data[:8] != PNG_MAGIC:
        raise ValueError("not a PNG")
    pos, idat, ihdr = 8, bytearray(), None
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        elif kind == b"IEND":
            break
    if ihdr is None:
        raise ValueError("no IHDR")
    width, height, depth, colour, _, _, interlace = ihdr
    if depth != 8:
        raise ValueError("bit depth %d is not supported" % depth)
    if interlace != 0:
        raise ValueError("interlaced PNG is not supported")
    channels = CHANNELS[colour]
    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(height * stride)
    prev = bytearray(stride)
    at = 0
    for row in range(height):
        ftype = raw[at]
        at += 1
        line = bytearray(raw[at:at + stride])
        at += stride
        if ftype == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                up = prev[i]
                corner = prev[i - channels] if i >= channels else 0
                est = left + up - corner
                da, db, dc = abs(est - left), abs(est - up), abs(est - corner)
                near = left if (da <= db and da <= dc) else (up if db <= dc else corner)
                line[i] = (line[i] + near) & 0xFF
        elif ftype != 0:
            raise ValueError("filter type %d is not supported" % ftype)
        out[row * stride:(row + 1) * stride] = line
        prev = line
    return width, height, channels, bytes(out)


def _chunk(kind, body):
    return (
        struct.pack(">I", len(body))
        + kind
        + body
        + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
    )


def png_write(path, width, height, channels, pixels):
    """Write filter-0 rows, declaring the channel count the pixels carry."""
    stride = width * channels
    if len(pixels) != stride * height:
        raise ValueError(
            "png_write: %d bytes for %dx%d at %d channels"
            % (len(pixels), width, height, channels)
        )
    if channels not in (1, 2, 3, 4):
        raise ValueError("png_write: %d channels" % channels)
    colour = {1: 0, 2: 4, 3: 2, 4: 6}[channels]
    raw = bytearray()
    for row in range(height):
        raw.append(0)
        raw += pixels[row * stride:(row + 1) * stride]
    blob = (
        PNG_MAGIC
        + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, colour, 0, 0, 0))
        + _chunk(b"sRGB", b"\x00")
        + _chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + _chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(blob)


def crop(pixels, width, channels, x, y, cw, chh):
    stride = width * channels
    out = bytearray()
    for row in range(y, y + chh):
        out += pixels[row * stride + x * channels:row * stride + (x + cw) * channels]
    return bytes(out)


class Sheet:
    """One decoded spritesheet and the tile geometry that indexes it.

    Geometry follows the texture set: the 2x atlas holds 142x190 tiles, so tile
    (x, y) starts at (x*142, y*190) there, not at the 1x offset.
    """

    def __init__(self, tw, th, data):
        self.tw, self.th = tw, th
        self.width, self.height, self.channels, self.pixels = png_read(data)

    def count(self):
        return self.width // self.tw, self.height // self.th

    def tile(self, x, y):
        """Crop one tile. A tile outside the sheet raises rather than writing a
        short PNG: Python slicing past the buffer yields short bytes silently."""
        if x < 0 or y < 0 or (x + 1) * self.tw > self.width or (y + 1) * self.th > self.height:
            raise ValueError(
                "tile (%d, %d) is outside %dx%d at %dx%d"
                % (x, y, self.width, self.height, self.tw, self.th)
            )
        return crop(self.pixels, self.width, self.channels,
                    x * self.tw, y * self.th, self.tw, self.th)


# ------------------------------------------------------------ game.lua parse --

def strip_comments(src):
    """Drop Lua comments, so commented-out entries never reach the parser."""
    out, at, end, quote = [], 0, len(src), None
    while at < end:
        char = src[at]
        if quote is not None:
            out.append(char)
            if char == "\\" and at + 1 < end:
                out.append(src[at + 1])
                at += 2
                continue
            if char == quote:
                quote = None
            at += 1
            continue
        if char in "\"'":
            quote = char
            out.append(char)
            at += 1
            continue
        if src.startswith("--[[", at) or src.startswith("--[==[", at):
            close = "]]" if src.startswith("--[[", at) else "]==]"
            stop = src.find(close, at)
            at = end if stop < 0 else stop + len(close)
            out.append("\n")
            continue
        if src.startswith("--", at):
            stop = src.find("\n", at)
            at = end if stop < 0 else stop + 1
            out.append("\n")
            continue
        out.append(char)
        at += 1
    return "".join(out)


def balanced(src, open_at):
    """End index of the `{...}` group that starts at `open_at`, honouring strings."""
    depth, at, end, quote = 0, open_at, len(src), None
    while at < end:
        char = src[at]
        if quote is not None:
            if char == "\\":
                at += 2
                continue
            if char == quote:
                quote = None
            at += 1
            continue
        if char in "\"'":
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return at
        at += 1
    raise ValueError("unbalanced braces at offset %d" % open_at)


ENTRY = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{")


def centers(src):
    """The body of the `P_CENTERS = { ... }` table as text.

    game.lua declares it as `self.P_CENTERS`; the `G.` spelling is the alias
    the rest of the game reads it through, and some builds use that instead.
    """
    match = re.search(r"(?:self|G)\.P_CENTERS\s*=\s*\{", src)
    if match is None:
        raise ValueError("P_CENTERS not found in game.lua")
    open_at = match.end() - 1
    return src[open_at + 1:balanced(src, open_at)]


def entries(block):
    """Top-level `key = { ... }` bodies, in source order."""
    found, at, end, depth, quote = [], 0, len(block), 0, None
    while at < end:
        char = block[at]
        if quote is not None:
            if char == "\\":
                at += 2
                continue
            if char == quote:
                quote = None
            at += 1
            continue
        if char in "\"'":
            quote = char
            at += 1
            continue
        if char == "{":
            depth += 1
            at += 1
            continue
        if char == "}":
            depth -= 1
            at += 1
            continue
        if depth == 0:
            match = ENTRY.match(block, at)
            if match is not None:
                open_at = match.end() - 1
                stop = balanced(block, open_at)
                found.append((match.group(1), block[open_at + 1:stop]))
                at = stop + 1
                continue
        at += 1
    return found


def field(body, pattern, cast=str):
    match = re.search(pattern, body, re.S)
    if match is None:
        return None
    return cast(match.group(1))


def jokers(src):
    """Every `j_*` centre, with the tile position its art lives at."""
    out = []
    for key, body in entries(centers(src)):
        if not key.startswith("j_"):
            continue
        pos = re.search(r"pos\s*=\s*\{\s*x\s*=\s*(\d+)\s*,\s*y\s*=\s*(\d+)\s*\}", body)
        if pos is None:
            continue
        out.append({
            "key": key,
            "name": field(body, r'name\s*=\s*"([^"]*)"') or key[2:].replace("_", " "),
            "x": int(pos.group(1)),
            "y": int(pos.group(2)),
            "rarity": field(body, r"rarity\s*=\s*(\d+)", int),
            "cost": field(body, r"cost\s*=\s*(\d+)", int),
            "set": field(body, r'set\s*=\s*"([^"]*)"'),
            "effect": field(body, r'effect\s*=\s*"([^"]*)"'),
            "order": field(body, r"order\s*=\s*(\d+)", int),
            "unlocked": field(body, r"unlocked\s*=\s*(true|false)") == "true",
        })
    out.sort(key=lambda j: (j["order"] if j["order"] is not None else 1 << 30, j["key"]))
    return out


# --------------------------------------------------------------------- main --

def texture(zf, name, scale):
    """Atlas bytes at `scale`, falling back to 1x when that set is absent.

    Not every build ships a 2x copy of every atlas, so the tile geometry has
    to follow the set that was actually read rather than the requested one.
    """
    for candidate in (scale, 1):
        path = "resources/textures/%dx/%s" % (candidate, name)
        if path in zf.namelist():
            return zf.read(path), candidate
    raise SystemExit("extract.py: no texture set holds %s" % name)


def sheet(zf, name, scale):
    """A decoded atlas, plus the scale its tiles were actually read at."""
    geometry = ATLAS.get(name) or ANIM[name]
    data, used = texture(zf, geometry[0], scale)
    return Sheet(geometry[1] * used, geometry[2] * used, data), used


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--love", required=True, help="path to the user's Balatro.love")
    ap.add_argument("--out", required=True, help="directory to write into")
    ap.add_argument("--scale", type=int, default=2, choices=(1, 2),
                    help="texture set to crop from (default 2)")
    ap.add_argument("--dump", action="store_true",
                    help="also write whole atlases under <out>/dump for inspection")
    args = ap.parse_args()

    sprites = os.path.join(args.out, "sprites")
    props = os.path.join(args.out, "props")
    os.makedirs(sprites, exist_ok=True)
    os.makedirs(props, exist_ok=True)

    with zipfile.ZipFile(args.love) as zf:
        game = zf.read("game.lua").decode("utf-8", "replace")
        atlas, scale = sheet(zf, "Jokers", args.scale)
        cols, rows = atlas.count()
        tile_w, tile_h = atlas.tw, atlas.th

        roster = jokers(game)
        written = []
        for joker in roster:
            if joker["x"] >= cols or joker["y"] >= rows:
                continue
            rel = "%s.png" % joker["key"][2:]
            png_write(os.path.join(sprites, rel), atlas.tw, atlas.th,
                      atlas.channels, atlas.tile(joker["x"], joker["y"]))
            joker["sprite"] = "sprites/" + rel
            written.append(joker)

        # Scene props. Positions are the game's own: card fronts and deck backs
        # come from G.P_CARDS and the b_* centres, whose art sits in the
        # `cards_1` and `centers` atlases. See README.md for the tile table.
        props_spec = [
            ("cards_1", 12, 3, "card_front"),   # S_A, the Ace of Spades
            ("centers", 0, 0, "deck_red"),      # b_red
            ("centers", 0, 2, "deck_blue"),     # b_blue
            ("centers", 2, 0, "edition_gold"),
            ("Booster", 0, 0, "booster_a"),
            ("Booster", 1, 0, "booster_b"),
        ]
        for name, tx, ty, out_name in props_spec:
            prop, _ = sheet(zf, name, args.scale)
            png_write(os.path.join(props, out_name + ".png"), prop.tw, prop.th,
                      prop.channels, prop.tile(tx, ty))

        for name, (_, _, _, frames) in ANIM.items():
            anim, _ = sheet(zf, name, args.scale)
            count, _ = anim.count()
            for index in range(min(frames, count)):
                png_write(os.path.join(props, "%s_%d.png" % (name, index)), anim.tw, anim.th,
                          anim.channels, anim.tile(index, 0))

        if args.dump:
            dump = os.path.join(args.out, "dump")
            os.makedirs(dump, exist_ok=True)
            for path in zf.namelist():
                if re.fullmatch(r"resources/textures/%dx/[^/]+\.png" % scale, path):
                    with open(os.path.join(dump, os.path.basename(path)), "wb") as fh:
                        fh.write(zf.read(path))

    manifest = {
        "version": 1,
        "scale": scale,
        "tile": {"w": tile_w, "h": tile_h},
        "grid": {"cols": cols, "rows": rows},
        "jokers": written,
    }
    with open(os.path.join(args.out, "jokers.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)
        fh.write("\n")

    print("extract.py: %d sprites, tile %dx%d, scale %d, from %s"
          % (len(written), tile_w, tile_h, scale, os.path.basename(args.love)),
          file=sys.stderr)


if __name__ == "__main__":
    main()
