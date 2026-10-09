"""Screen checks for InfestationHop.ahk (Fallout 76 map / HUD).

    python cloudscan.py <left> <top> <width> <height> [--save-all]
        Is there an Infestation cloud on the map? Exit 2 = cloud, 0 = none.
    python cloudscan.py spots <left> <top> <width> <height> <out.txt>
        Writes the cloud's centre ("cx cy" on the first line) and every spawn spot
        (magenta dot) in or touching the cloud ("x y" per line), in game-window pixels.
        Exit 2 = cloud found, 0 = none.
    python cloudscan.py button <left> <top> <width> <height> <x> <y> <out.txt>
        Finds the gold FAST TRAVEL button near a clicked spot (x, y). Writes "x y".
        Exit 2 = found, 0 = none.
    python cloudscan.py dot <left> <top> <width> <height> <x> <y> <out.txt>
        Re-measures the spawn-spot dot nearest (x, y): writes the centre of its ring.
        Exit 2 = found, 0 = none.
    python cloudscan.py yes <left> <top> <width> <height> <out.txt>
        Finds the gold "Yes" button of the "Pay N Caps to travel to this location?" box.
        Writes "x y". Exit 2 = found, 0 = none.
    python cloudscan.py infest <left> <top> <width> <height>
        Is INFESTATION showing in the quest list (top right)? Exit 2 = yes, 0 = no.

Any of them can take a saved screenshot path instead of <left> <top> <width> <height>
for testing. Exit code 1 = error. Map views with a cloud are saved to cloudshots/.
"""
import json
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageGrab

BLOCK = 40            # grid square size (at 1920x1080)
MIN_CLOUD_BLOCKS = 12 # patch size that counts as a cloud (clouds seen: 21-47; no-cloud maps: 4 at most)
MIN_CLOUD_SIDE = 4    # a cloud is round and big (~12 squares across); region-name banners and
                      # hover tooltips are wide but only ~1.5 squares tall, so they don't count

# Fixed map-screen panels (1920x1080 coordinates): x0, y0, x1, y1
MASKS = [
    (40, 30, 150, 78),      # Z) MENU
    (45, 85, 388, 195),     # C.A.M.P. slots
    (45, 775, 388, 995),    # world activity
    (1275, 85, 1875, 540),  # challenges
    (1750, 30, 1875, 78),   # C) SOCIAL
    (1095, 30, 1250, 165),  # season icon
    (250, 1000, 1840, 1080),# key hints / atoms
    (1735, 860, 1905, 990), # weight / caps
    (1880, 0, 1920, 15),    # fps counter
]

HERE = Path(__file__).parent
SHOT_DIR = HERE / "cloudshots"
TITLE_TEMPLATE = HERE / "infestation_title.png"   # "INFESTATION" quest title, cut from a screenshot


# ---- screen grab ------------------------------------------------------------

def grab(args):
    """args = [left, top, width, height] or [screenshot path]. Returns (img as 1920x1080
    int16 array, scale back to window pixels, raw PIL image, live?)."""
    if len(args) == 1:
        img = Image.open(args[0]).convert("RGB")
        live = False
    else:
        left, top, w, h = map(int, args[:4])
        img = ImageGrab.grab(bbox=(left, top, left + w, top + h), all_screens=True).convert("RGB")
        live = True
    a = np.asarray(img.resize((1920, 1080))).astype(np.int16)
    return a, (img.width / 1920, img.height / 1080), img, live


def valid_mask():
    valid = np.ones((1080, 1920), bool)
    for x0, y0, x1, y1 in MASKS:
        valid[y0:y1, x0:x1] = False
    return valid


def components(mask, connectivity=4):
    """Connected areas of a boolean array -> list of (ys, xs) arrays."""
    h, w = mask.shape
    seen = np.zeros_like(mask)
    steps = ((1, 0), (-1, 0), (0, 1), (0, -1)) if connectivity == 4 else \
        tuple((dy, dx) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dy or dx)
    out = []
    for y0, x0 in zip(*np.nonzero(mask)):
        if seen[y0, x0]:
            continue
        stack, ys, xs = [(y0, x0)], [], []
        seen[y0, x0] = True
        while stack:
            y, x = stack.pop()
            ys.append(y)
            xs.append(x)
            for dy, dx in steps:
                yy, xx = y + dy, x + dx
                if 0 <= yy < h and 0 <= xx < w and mask[yy, xx] and not seen[yy, xx]:
                    seen[yy, xx] = True
                    stack.append((yy, xx))
        out.append((np.array(ys), np.array(xs)))
    return out


# ---- cloud ------------------------------------------------------------------

def is_white_map(a, valid):
    """True when most of the open map area is (near) white (Infestation Map White mod)."""
    return (a[valid].min(1) > 230).mean() > 0.4


def cloud_blocks(a, valid):
    """Grid squares whose typical (median) colour is the cloud's. Using the median ignores
    map icons, roads and rivers drawn over the cloud.

    Normal map: dark, nearly colourless grey, blue a touch lower than red/green, red >= green.
    The Ash Heap is less green than blue and the dark olive map edges have green above red.

    White map: neutral grey that isn't white. Icons are blue and spawn spots magenta."""
    gh, gw = 1080 // BLOCK, 1920 // BLOCK
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    blocks = lambda m: np.median(m[:gh * BLOCK, :gw * BLOCK]
                                 .reshape(gh, BLOCK, gw, BLOCK).transpose(0, 2, 1, 3)
                                 .reshape(gh, gw, BLOCK * BLOCK), 2)
    br, sat = blocks(a.mean(2)), blocks(a.max(2) - a.min(2))
    if is_white_map(a, valid):
        # the smoke is a perfectly neutral grey (colour strength ~1); pop-up banners are
        # bluish (~10) and region labels warm (~6) or thin strips
        grid = (br > 35) & (br < 215) & (sat <= 3)
    else:
        rb, gb, rg = blocks(r - b), blocks(g - b), blocks(r - g)
        grid = ((br > 28) & (br < 70) & (sat <= 6)
                & (rb >= 0) & (rb <= 9) & (gb >= 0) & (gb <= 6) & (rg >= 0) & (rg <= 3))
    open_area = valid[:gh * BLOCK, :gw * BLOCK].reshape(gh, BLOCK, gw, BLOCK).mean((1, 3)) >= 0.9
    return grid & open_area


def cloud_patch(a, valid):
    """The biggest cloud-shaped patch of grid squares: (number of squares, list of (row, col))."""
    best = []
    for ys, xs in components(cloud_blocks(a, valid)):
        if min(np.ptp(xs), np.ptp(ys)) + 1 < MIN_CLOUD_SIDE:
            continue   # long thin strip: a banner or tooltip, not a cloud
        if len(ys) > len(best):
            best = list(zip(ys.tolist(), xs.tolist()))
    return len(best), best


def save_shot(img, tag, size):
    SHOT_DIR.mkdir(exist_ok=True)
    img.save(SHOT_DIR / f"{time.strftime('%Y%m%d_%H%M%S')}_{tag}_{size}.png")


def cmd_cloud(args, save_all):
    a, _, img, live = grab(args)
    size, patch = cloud_patch(a, valid_mask())
    found = size >= MIN_CLOUD_BLOCKS
    at = (patch[0][1] * BLOCK, patch[0][0] * BLOCK) if patch else (0, 0)
    print(f"{'CLOUD' if found else 'NONE'} patch={size} at={at[0]},{at[1]}")
    if live and (found or save_all):
        save_shot(img, "cloud" if found else "none", size)
    return 2 if found else 0


# ---- spawn spots ------------------------------------------------------------

def find_dots(a, valid):
    """Magenta spawn-spot dots, bright or dimmed by the smoke: list of (x, y) centres.
    The centre is the middle of the ring's outline, so the icon inside doesn't skew it."""
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    mag = (r - g > 25) & (b - g > 25) & (np.abs(r - b) < 80) & valid
    dots = []
    for ys, xs in components(mag):
        if len(ys) >= 150 and np.ptp(xs) < 70 and np.ptp(ys) < 70:
            dots.append(((xs.min() + xs.max()) / 2, (ys.min() + ys.max()) / 2))
    return dots


def cmd_dot(args):
    a, (sx, sy), _, _ = grab(args[:-3])
    x, y = float(args[-3]) / sx, float(args[-2]) / sy
    best, best_d = None, 80.0
    for dx, dy in find_dots(a, valid_mask()):
        d = np.hypot(dx - x, dy - y)
        if d < best_d:
            best, best_d = (dx, dy), d
    if best is None:
        Path(args[-1]).write_text("none")
        print("NONE")
        return 0
    out = f"{round(best[0] * sx)} {round(best[1] * sy)}"
    Path(args[-1]).write_text(out)
    print("DOT", out)
    return 2


def cmd_spots(args):
    a, (sx, sy), img, live = grab(args[:-1])
    valid = valid_mask()
    size, patch = cloud_patch(a, valid)
    result = {"cloud": size >= MIN_CLOUD_BLOCKS, "size": size, "cx": 0, "cy": 0, "spots": []}
    if result["cloud"]:
        rows = np.array([p[0] for p in patch])
        cols = np.array([p[1] for p in patch])
        result["cx"] = round((cols.mean() + 0.5) * BLOCK * sx)
        result["cy"] = round((rows.mean() + 0.5) * BLOCK * sy)
        near = {(r + dr, c + dc) for r, c in patch for dr in (-1, 0, 1) for dc in (-1, 0, 1)}
        for x, y in find_dots(a, valid):
            if (int(y // BLOCK), int(x // BLOCK)) in near:
                result["spots"].append([round(x * sx), round(y * sy)])
        if live:
            save_shot(img, "spots", len(result["spots"]))
    lines = [f"{result['cx']} {result['cy']}"] + [f"{x} {y}" for x, y in result["spots"]]
    Path(args[-1]).write_text("\n".join(lines) if result["cloud"] else "none")
    print(json.dumps(result))
    return 2 if result["cloud"] else 0


# ---- fast travel button -----------------------------------------------------

def cmd_button(args):
    a, (sx, sy), _, _ = grab(args[:-3])
    x, y = float(args[-3]) / sx, float(args[-2]) / sy
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    gold = (np.abs(r - 245) < 22) & (np.abs(g - 203) < 25) & (np.abs(b - 91) < 35)
    # solid gold 4x4 cells (the button), not gold text
    cells = gold.reshape(270, 4, 480, 4).mean((1, 3)) >= 0.8
    best, best_d = None, 1e9
    for ys, xs in components(cells, 8):
        w, h = (np.ptp(xs) + 1) * 4, (np.ptp(ys) + 1) * 4
        if w < 100 or h < 12 or w < 3 * h:
            continue
        bx, by = (xs.mean() + 0.5) * 4, (ys.mean() + 0.5) * 4
        if abs(bx - x) > 500 or abs(by - y) > 300:
            continue
        d = np.hypot(bx - x, by - y)
        if d < best_d:
            best, best_d = (bx, by), d
    if best is None:
        Path(args[-1]).write_text("none")
        print("NONE")
        return 0
    out = f"{round(best[0] * sx)} {round(best[1] * sy)}"
    Path(args[-1]).write_text(out)
    print("BUTTON", out)
    return 2


def cmd_yes(args):
    """The confirmation box's gold "Yes" button: a solid gold block ~90x38 px near the
    middle of the screen (the FAST TRAVEL button is much wider and next to the spot)."""
    a, (sx, sy), _, _ = grab(args[:-1])
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    # gold with a lighter middle: (246,205,96) at the edges to (249,225,138) in the centre
    gold = (r > 232) & (g > 192) & (g < 235) & (b > 78) & (b < 152) & (r - b > 95)
    cells = gold.reshape(270, 4, 480, 4).mean((1, 3)) >= 0.6
    best, best_d = None, 1e9
    for ys, xs in components(cells, 8):
        w, h = (np.ptp(xs) + 1) * 4, (np.ptp(ys) + 1) * 4
        if not (50 <= w <= 220 and 20 <= h <= 64):
            continue
        bx, by = (xs.mean() + 0.5) * 4, (ys.mean() + 0.5) * 4
        if not (400 < bx < 1520 and 250 < by < 850):
            continue
        d = np.hypot(bx - 960, by - 540)
        if d < best_d:
            best, best_d = (bx, by), d
    if best is None:
        Path(args[-1]).write_text("none")
        print("NONE")
        return 0
    out = f"{round(best[0] * sx)} {round(best[1] * sy)}"
    Path(args[-1]).write_text(out)
    print("YES", out)
    return 2


# ---- INFESTATION in the quest list -----------------------------------------

def gold_text(a):
    r, g, b = a[..., 0], a[..., 1], a[..., 2]
    return (r > 190) & (g > 140) & (b < 160) & (r - b > 60)


def cmd_infest(args):
    a, _, _, _ = grab(args)
    t = gold_text(np.asarray(Image.open(TITLE_TEMPLATE).convert("RGB")).astype(np.int16))
    th, tw = t.shape
    x_left = 1706                       # titles are right-aligned at the same x
    band = gold_text(a[:, x_left - 8:x_left + tw + 8])
    best = 0.0
    for y in range(30, 800):
        win = band[y:y + th]
        if win.sum() < 0.5 * t.sum():
            continue
        for dx in range(0, 17, 2):
            w = win[:, dx:dx + tw]
            inter = (w & t).sum()
            iou = inter / max(1, (w | t).sum())
            best = max(best, iou)
    found = best >= 0.5
    print(f"{'INFESTATION' if found else 'NONE'} match={best:.2f}")
    return 2 if found else 0


def main():
    args = sys.argv[1:]
    save_all = "--save-all" in args
    args = [x for x in args if not x.startswith("--")]
    if args and args[0] == "spots":
        return cmd_spots(args[1:])
    if args and args[0] == "button":
        return cmd_button(args[1:])
    if args and args[0] == "dot":
        return cmd_dot(args[1:])
    if args and args[0] == "yes":
        return cmd_yes(args[1:])
    if args and args[0] == "infest":
        return cmd_infest(args[1:])
    if len(args) in (1, 4):
        return cmd_cloud(args, save_all)
    print(__doc__)
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # never crash the AHK loop
        print("ERROR", e)
        sys.exit(1)
