#!/usr/bin/env python3
"""Lays out the Macrophone DMG window without asking Finder.

    python3 Mac/scripts/dmg/dsstore.py <mounted volume> [--app Macrophone.app]

Writes <volume>/.DS_Store directly: an icon view with no toolbar or sidebar, the window size,
the icon size, the background picture (.background/background.tiff, referenced by an alias built
from the mounted file), and where the app and the Applications link sit. Finder reads it when
the DMG is opened. Standard library only — no Finder scripting, so no Automation prompt.

The .DS_Store format (a "buddy allocator" file holding a B-tree of records) is described by
Mark Mentovai and Wim Lewis; this writes the small, single-leaf case.
"""
import os
import plistlib
import struct
import sys

# The window: content size matches the 640×400 background (render-dmg-background.swift).
WINDOW_ORIGIN = (200, 120)
WINDOW_SIZE = (640, 400)
ICON_SIZE = 112
TEXT_SIZE = 13
# Icon centres, in window points from the top-left (they sit either side of the arrow).
POSITIONS = {"Applications": (480, 195)}
APP_POSITION = (160, 195)
BACKGROUND = ".background/background.tiff"

MAC_EPOCH_OFFSET = 2082844800  # seconds from 1904-01-01 to 1970-01-01


# ── The alias Finder uses to find the background picture ────────────────────────────────────

def _str_fixed(s, size):
    """A Pascal string in a fixed-size field (length byte + bytes, zero-padded)."""
    b = s.encode("mac_roman", "replace")[: size - 1]
    return bytes([len(b)]) + b + b"\0" * (size - 1 - len(b))


def _tag(tag, data):
    out = struct.pack(">hH", tag, len(data)) + data
    return out + (b"\0" if len(data) % 2 else b"")


def _utf16(s):
    return struct.pack(">H", len(s)) + s.encode("utf-16-be")


def make_alias(volume, rel_path):
    """A classic (version 2) alias record for <volume>/<rel_path>."""
    path = os.path.join(volume, rel_path)
    st = os.stat(path)
    parent = os.path.dirname(path)
    pst = os.stat(parent)
    vst = os.stat(volume)
    vol_name = os.path.basename(volume.rstrip("/"))
    file_name = os.path.basename(path)
    parent_name = os.path.basename(parent)
    vol_date = int(getattr(vst, "st_birthtime", vst.st_mtime)) + MAC_EPOCH_OFFSET
    file_date = int(getattr(st, "st_birthtime", st.st_mtime)) + MAC_EPOCH_OFFSET

    body = b""
    body += _str_fixed(vol_name, 28)                    # volume name (Str27)
    body += struct.pack(">I", vol_date & 0xFFFFFFFF)    # volume creation date
    body += b"H+"                                       # file system: HFS+
    body += struct.pack(">H", 5)                        # disk type: ejectable
    body += struct.pack(">I", pst.st_ino)               # parent folder id
    body += _str_fixed(file_name, 64)                   # file name (Str63)
    body += struct.pack(">I", st.st_ino)                # file id
    body += struct.pack(">I", file_date & 0xFFFFFFFF)   # file creation date
    body += b"\0\0\0\0" + b"\0\0\0\0"                   # type, creator
    body += struct.pack(">hh", -1, -1)                  # levels from / to
    body += struct.pack(">I", 0)                        # volume attributes
    body += struct.pack(">H", 0)                        # volume fs id
    body += b"\0" * 10                                  # reserved

    extra = b""
    extra += _tag(0, parent_name.encode("mac_roman", "replace"))
    extra += _tag(1, struct.pack(">I", pst.st_ino))
    extra += _tag(2, (vol_name + ":" + rel_path.replace("/", ":")).encode("mac_roman", "replace"))
    extra += _tag(14, _utf16(file_name))
    extra += _tag(15, _utf16(vol_name))
    extra += _tag(18, ("/" + rel_path).encode("utf-8"))
    extra += _tag(19, volume.rstrip("/").encode("utf-8"))
    extra += struct.pack(">hH", -1, 0)

    header_len = 4 + 2 + 2 + 2  # app type, record size, version, kind
    total = header_len + len(body) + len(extra)
    return b"\0\0\0\0" + struct.pack(">HHH", total, 2, 0) + body + extra


# ── Records ─────────────────────────────────────────────────────────────────────────────────

def _record(name, code, kind, data):
    out = struct.pack(">I", len(name)) + name.encode("utf-16-be") + code.encode("ascii") + kind.encode("ascii")
    if kind == "blob":
        out += struct.pack(">I", len(data)) + data
    elif kind == "long" or kind == "shor":
        out += struct.pack(">I", data)
    elif kind == "bool":
        out += struct.pack(">B", 1 if data else 0)
    elif kind == "type":
        out += data.encode("ascii")
    else:
        raise ValueError(kind)
    return out


def _iloc(x, y):
    return struct.pack(">IIII", x, y, 0xFFFFFFFF, 0xFFFF0000)


def records(volume, app_name):
    (wx, wy), (ww, wh) = WINDOW_ORIGIN, WINDOW_SIZE
    bwsp = {
        "ContainerShowSidebar": False, "ShowPathbar": False, "ShowSidebar": False, "ShowStatusBar": False,
        "ShowTabView": False, "ShowToolbar": False, "SidebarWidth": 0,
        # Finder's bounds include the title bar (28 pt) on top of the content.
        "WindowBounds": "{{%d, %d}, {%d, %d}}" % (wx, wy, ww, wh + 28),
    }
    icvp = {
        "arrangeBy": "none", "backgroundColorBlue": 1.0, "backgroundColorGreen": 1.0, "backgroundColorRed": 1.0,
        "backgroundImageAlias": make_alias(volume, BACKGROUND), "backgroundType": 2,
        "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0, "iconSize": float(ICON_SIZE),
        "labelOnBottom": True, "showIconPreview": True, "showItemInfo": False, "textSize": float(TEXT_SIZE),
        "viewOptionsVersion": 1,
    }
    recs = [
        (".", "bwsp", "blob", plistlib.dumps(bwsp, fmt=plistlib.FMT_BINARY)),
        (".", "icvp", "blob", plistlib.dumps(icvp, fmt=plistlib.FMT_BINARY)),
        (".", "vSrn", "long", 1),
        (".", "vstl", "type", "icnv"),
        (app_name, "Iloc", "blob", _iloc(*APP_POSITION)),
    ]
    for name, (x, y) in POSITIONS.items():
        recs.append((name, "Iloc", "blob", _iloc(x, y)))
    # Finder keeps records sorted by file name (case-insensitive), then by code.
    recs.sort(key=lambda r: (r[0].lower(), r[1]))
    return recs


# ── The buddy-allocated file ────────────────────────────────────────────────────────────────

def build(recs):
    # Block layout (offsets count from byte 4 of the file):
    #   the 32-byte header · DSDB at 32 (32 bytes) · the root at 2048 · the leaf node at 4096.
    DSDB_OFF, DSDB_LOG = 32, 5
    ROOT_OFF, ROOT_LOG = 2048, 11
    LEAF_OFF, LEAF_LOG = 4096, 12

    leaf = struct.pack(">II", 0, len(recs)) + b"".join(_record(*r) for r in recs)
    if len(leaf) > (1 << LEAF_LOG):
        raise SystemExit("too many records for one leaf")

    # Block 0 is the root itself, 1 the DSDB header, 2 the leaf.
    addresses = [ROOT_OFF | ROOT_LOG, DSDB_OFF | DSDB_LOG, LEAF_OFF | LEAF_LOG]
    root = struct.pack(">II", len(addresses), 0)
    root += b"".join(struct.pack(">I", a) for a in addresses)
    root += b"\0" * 4 * (256 - len(addresses))
    root += struct.pack(">I", 1) + bytes([4]) + b"DSDB" + struct.pack(">I", 1)
    # Free lists by size (2^0 … 2^31): every buddy not used above, up to 2^31.
    used = {(0, 5), (DSDB_OFF, DSDB_LOG), (ROOT_OFF, ROOT_LOG), (LEAF_OFF, LEAF_LOG)}
    free = {i: [] for i in range(32)}
    # The header and DSDB share the first 64 bytes; above them, each power-of-two buddy is free.
    for log in range(6, 31):
        off = 1 << log
        if (off, log) not in used and not any(o <= off < o + (1 << l) for o, l in used):
            free[log].append(off)
    for i in range(32):
        root += struct.pack(">I", len(free[i])) + b"".join(struct.pack(">I", o) for o in free[i])

    dsdb = struct.pack(">IIIII", 2, 0, len(recs), 1, 0x1000)

    size = LEAF_OFF + (1 << LEAF_LOG)
    buf = bytearray(4 + size)
    buf[0:4] = struct.pack(">I", 1)
    buf[4:36] = b"Bud1" + struct.pack(">III", ROOT_OFF, 1 << ROOT_LOG, ROOT_OFF) + b"\0" * 16
    buf[4 + DSDB_OFF: 4 + DSDB_OFF + len(dsdb)] = dsdb
    buf[4 + ROOT_OFF: 4 + ROOT_OFF + len(root)] = root
    buf[4 + LEAF_OFF: 4 + LEAF_OFF + len(leaf)] = leaf
    return bytes(buf)


def main():
    args = sys.argv[1:]
    if not args:
        raise SystemExit(__doc__)
    volume = args[0]
    app = "Macrophone.app"
    if "--app" in args:
        app = args[args.index("--app") + 1]
    if not os.path.exists(os.path.join(volume, BACKGROUND)):
        raise SystemExit(f"No background at {BACKGROUND} on {volume}")
    with open(os.path.join(volume, ".DS_Store"), "wb") as f:
        f.write(build(records(volume, app)))
    print(f"Wrote {volume}/.DS_Store")


if __name__ == "__main__":
    main()
