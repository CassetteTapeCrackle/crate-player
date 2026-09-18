#!/usr/bin/env python3
"""Generates Crate's pixel-art mark and macOS icon.

A vinyl record: concentric grooves cut out of a solid disc, an accent label and
a spindle hole. Drawn on a 32x32 grid so there is room for groove detail, which
is double the icon's smallest rendering but still divides cleanly into every
size macOS asks for.

Cells are square rather than the wide slabs of the Claude Code house idiom. The
app is set in Departure Mono, a square-grid bitmap face, so the mark matches the
typography beside it, and a record has to stay circular in both axes.

Geometry is computed from radii rather than hand-placed, because a hand-drawn
circle is never symmetric and the error is only visible after rendering.
"""
import math, subprocess, shutil
from pathlib import Path

GROUND = "#0D0D0D"   # tile and groove cuts
INK    = "#FFFFFF"   # disc
DIM    = "#8C8C8C"   # outer rim, gives the disc an edge
ACCENT = "#C0826A"   # label

N = 32                # grid cells per side
CENTER = N / 2        # 16.0, the true centre of the grid

R_DISC  = 15.0            # outer edge of the record
R_RIM   = 14.4            # below this is disc, above it is the rim
R_LABEL = 6.0             # accent label, about a third of the diameter
HOLE    = 1               # spindle hole half-width, in cells
GROOVE_RINGS = {9, 12}       # groove radii, as whole cell-rings


def classify(c: int, r: int, detail: bool = True) -> str:
    """Returns the palette key for one cell, from its distance to the centre."""
    dx, dy = c + 0.5 - CENTER, r + 0.5 - CENTER
    d = math.hypot(dx, dy)

    if d > R_DISC:
        return "."
    if d > R_RIM:
        return "d"                      # rim gives the disc an edge against the tile

    # Spindle hole. Measured on the square rather than the circle, because a
    # radius this small quantises into a plus sign rather than a hole.
    if max(abs(dx), abs(dy)) <= HOLE:
        return "."
    if d <= R_LABEL:
        return "A"

    # Grooves are drawn in the mid grey, not in the ground colour. Cutting them
    # to the background gives black and white equal area and the disc reads as a
    # dartboard; against white, grey reads as texture on one surface.
    #
    # Ring membership is quantised to a whole cell-ring rather than tested
    # against a band. A thin annulus samples inconsistently around the circle
    # and breaks into diagonal speckle; rounding gives one crisp ring.
    if detail and round(d) in GROOVE_RINGS:
        return "g"
    return "#"


GRID = ["".join(classify(c, r) for c in range(N)) for r in range(N)]

# At 16px each grid cell is half a pixel and the grooves alias into speckle, so
# that size gets its own simplified artwork. Per-size icon art is normal on macOS.
GRID_PLAIN = ["".join(classify(c, r, detail=False) for c in range(N)) for r in range(N)]

# ---- guards: these failures are invisible in source and obvious only on render ----

assert all(len(row) == N for row in GRID), "grid must be square"

filled = {(c, r) for r, row in enumerate(GRID) for c, ch in enumerate(row) if ch != "."}
assert filled, "mark is empty"

# 1. Clearance: nothing may touch the tile edge, or the disc fuses with the border.
for c, r in filled:
    assert 0 < c < N - 1 and 0 < r < N - 1, f"cell ({c},{r}) touches the edge"

# 2. Symmetry: a record is symmetric on both axes. Catches an off-centre circle,
#    which reads as a wobble rather than as an obvious mistake.
for r in range(N):
    for c in range(N):
        assert GRID[r][c] == GRID[r][N - 1 - c], f"not mirrored horizontally at row {r}"
        assert GRID[r][c] == GRID[N - 1 - r][c], f"not mirrored vertically at col {c}"

# 3. The label must be one solid block, not speckle, and must enclose the hole.
label_rows = {r for c, r in filled if GRID[r][c] == "A"}
assert label_rows == set(range(min(label_rows), max(label_rows) + 1)), "label is broken"
assert GRID[N // 2][N // 2] == ".", "spindle hole is filled in"

# 3b. The simplified variant must differ only by its grooves.
assert GRID_PLAIN != GRID, "simplified variant is identical to the detailed one"
assert all(
    a == b or (b == "g" and a == "#")
    for ra, rb in zip(GRID_PLAIN, GRID) for a, b in zip(ra, rb)
), "simplified variant changed something other than the grooves"

# 4. Grooves must actually appear, or the disc renders as a plain white circle.
groove_cells = sum(row.count("g") for row in GRID)
expected = sum(2 * math.pi * g for g in GROOVE_RINGS)
assert 0.5 * expected < groove_cells < 1.6 * expected, (
    f"{groove_cells} groove cells against ~{expected:.0f} expected; "
    "grooves are either missing or have smeared together")

FILLS = {"#": INK, "A": ACCENT, "d": DIM, "g": DIM}


def svg(px: int, grid=None) -> str:
    grid = grid if grid is not None else (GRID if px >= 32 else GRID_PLAIN)
    cell = px / N
    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" '
        f'viewBox="0 0 {px} {px}" shape-rendering="crispEdges">',
        f'<rect width="{px}" height="{px}" fill="{GROUND}"/>',
    ]
    for r, row in enumerate(grid):
        c = 0
        while c < N:                      # merge horizontal runs into single rects
            ch = row[c]
            if ch == ".":
                c += 1
                continue
            start = c
            while c < N and row[c] == ch:
                c += 1
            parts.append(
                f'<rect x="{start * cell:g}" y="{r * cell:g}" '
                f'width="{(c - start) * cell:g}" height="{cell:g}" fill="{FILLS[ch]}"/>'
            )
    parts.append("</svg>")
    return "".join(parts)


root = Path(__file__).resolve().parent.parent
(root / "Resources").mkdir(exist_ok=True)
(root / "Resources/icon.svg").write_text(svg(1024))

iconset = root / "build/Crate.iconset"
if iconset.exists():
    shutil.rmtree(iconset)
iconset.mkdir(parents=True)

for base in (16, 32, 128, 256, 512):
    for scale in (1, 2):
        px = base * scale
        name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
        tmp = iconset / "_tmp.svg"
        tmp.write_text(svg(px))
        subprocess.run(["rsvg-convert", "-w", str(px), "-h", str(px),
                        "-o", str(iconset / name), str(tmp)], check=True)
        tmp.unlink()

subprocess.run(["iconutil", "-c", "icns", str(iconset),
                "-o", str(root / "Resources/Crate.icns")], check=True)

tmp = root / "build/_logo.svg"
tmp.write_text(svg(512))
subprocess.run(["rsvg-convert", "-w", "512", "-h", "512",
                "-o", str(root / "Resources/crate-logo.png"), str(tmp)], check=True)
tmp.unlink()

print(f"guards passed: {len(filled)} cells, {groove_cells} groove cells, symmetric")
print("wrote Resources/icon.svg, Resources/Crate.icns, Resources/crate-logo.png")

# ---------------------------------------------------------------- menu bar mark

# The menu bar wants a template image: macOS reads only the alpha channel and
# paints it black or white to match the bar, which is what makes it look native
# in both appearances. So the record is drawn as a silhouette with the groove and
# the spindle hole punched through, and colour is discarded.
#
# Its own 18-cell grid, because the menu bar renders at 18pt and the 32-cell grid
# would land on half pixels and turn the groove to mush.
NB = 18
NB_CENTER = NB / 2
NB_DISC = 8.5
NB_GROOVE = 6            # one ring only; more than that closes up at this size
NB_HOLE = 1              # half-width in cells, so a 2x2 hole


def menubar_classify(c: int, r: int) -> str:
    dx, dy = c + 0.5 - NB_CENTER, r + 0.5 - NB_CENTER
    d = math.hypot(dx, dy)
    if d > NB_DISC:
        return "."
    if max(abs(dx), abs(dy)) <= NB_HOLE:
        return "."
    if round(d) == NB_GROOVE:
        return "."
    return "#"


GRID_MENUBAR = ["".join(menubar_classify(c, r) for c in range(NB)) for r in range(NB)]

for r in range(NB):
    for c in range(NB):
        assert GRID_MENUBAR[r][c] == GRID_MENUBAR[r][NB - 1 - c], "menu bar mark not mirrored"
        assert GRID_MENUBAR[r][c] == GRID_MENUBAR[NB - 1 - r][c], "menu bar mark not mirrored"
assert any("." in row for row in GRID_MENUBAR), "groove did not punch through"
assert GRID_MENUBAR[NB // 2][NB // 2] == ".", "spindle hole is filled in"


def menubar_svg(px: int) -> str:
    """Transparent ground, solid shape. Colour is irrelevant to a template image."""
    cell = px / NB
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" '
             f'viewBox="0 0 {px} {px}" shape-rendering="crispEdges">']
    for r, row in enumerate(GRID_MENUBAR):
        c = 0
        while c < NB:
            if row[c] == ".":
                c += 1
                continue
            start = c
            while c < NB and row[c] == "#":
                c += 1
            parts.append(f'<rect x="{start * cell:g}" y="{r * cell:g}" '
                         f'width="{(c - start) * cell:g}" height="{cell:g}" fill="#000000"/>')
    parts.append("</svg>")
    return "".join(parts)


tmp = root / "build/_menubar.svg"
tmp.write_text(menubar_svg(36))
subprocess.run(["rsvg-convert", "-w", "36", "-h", "36",
                "-o", str(root / "Resources/menubar.png"), str(tmp)], check=True)
tmp.unlink()
print("wrote Resources/menubar.png (18pt template, 36px @2x)")
