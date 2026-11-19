"""Fit per-look 3D LUTs from RAW + in-camera JPEG pairs.

Pipeline per pair:
  RAF --(LibRaw, camera WB, linear, Rec.2020)--> scene-linear RGB
  align to the camera JPEG (ECC homography on downscaled frames), mask edges/clipping
  sample (scene-linear, JPEG sRGB) pairs
Per look: regularised least-squares fit of a 33^3 lattice over a log2 shaper.

Commands:
  uv run fit.py samples            # develop + align every pair under captures/, cache samples
  uv run fit.py fit [look ...]     # fit LUTs into luts/<look>.npz and luts/<look>.cube
  uv run fit.py eval               # hold-out ΔE2000 per look
  uv run fit.py preview <scene> <look>   # side-by-side: camera JPEG vs our LUT on the RAW
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np
import rawpy
import scipy.sparse as sp
import scipy.sparse.linalg as spla

ROOT = Path(__file__).resolve().parent
CAPTURES = ROOT / "captures"
CACHE = ROOT / "cache"
LUTS = ROOT / "luts"

WORK_W = 640  # alignment / sampling resolution
GRID = 33
# Shaper: log2 exposure relative to mid grey, from -9 to +5 stops.
LOG_LO, LOG_HI = -9.0, 5.0
MID_GREY = 0.18


@dataclass(frozen=True)
class Shaper:
    scale: float  # multiplies RAW-normalised linear so that the camera's mid grey lands at 0.18

    def encode(self, lin: np.ndarray) -> np.ndarray:
        x = np.maximum(lin * self.scale, MID_GREY * 2.0**LOG_LO)
        return np.clip((np.log2(x / MID_GREY) - LOG_LO) / (LOG_HI - LOG_LO), 0.0, 1.0)


def develop_raw(path: Path) -> np.ndarray:
    """Scene-linear Rec.2020 (D65), camera as-shot WB, 1.0 = sensor clip."""
    with rawpy.imread(str(path)) as raw:
        rgb = raw.postprocess(
            use_camera_wb=True,
            output_color=rawpy.ColorSpace.Rec2020,
            gamma=(1, 1),
            no_auto_bright=True,
            output_bps=16,
            half_size=True,
            user_flip=0,
            highlight_mode=rawpy.HighlightMode.Clip,
        )
    return rgb.astype(np.float32) / 65535.0


def load_jpeg(path: Path) -> np.ndarray:
    bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if bgr is None:
        raise FileNotFoundError(path)
    return cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB).astype(np.float32) / 255.0


def resize_w(img: np.ndarray, w: int) -> np.ndarray:
    h = round(img.shape[0] * w / img.shape[1])
    return cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)


def gray_for_align(img: np.ndarray, linear: bool) -> np.ndarray:
    g = img.mean(axis=2)
    g = np.power(np.clip(g / max(np.percentile(g, 99), 1e-6), 0, 1), 1 / 2.2) if linear else g
    g = cv2.GaussianBlur(g.astype(np.float32), (0, 0), 1.0)
    return (g - g.mean()) / (g.std() + 1e-6)


def align(raw_lin: np.ndarray, jpg: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Warp the developed RAW onto the JPEG frame. Returns (raw_aligned, valid_mask)."""
    j = resize_w(jpg, WORK_W)
    r = cv2.resize(raw_lin, (j.shape[1], j.shape[0]), interpolation=cv2.INTER_AREA)
    warp = np.eye(3, dtype=np.float32)
    criteria = (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 200, 1e-6)
    _, warp = cv2.findTransformECC(gray_for_align(j, False), gray_for_align(r, True), warp, cv2.MOTION_HOMOGRAPHY, criteria, None, 5)
    size = (j.shape[1], j.shape[0])
    flags = cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP
    aligned = cv2.warpPerspective(r, warp, size, flags=flags)
    valid = cv2.warpPerspective(np.ones(r.shape[:2], np.float32), warp, size, flags=flags) > 0.999
    return aligned, valid


def flat_mask(img: np.ndarray) -> np.ndarray:
    """Pixels away from edges, so residual misalignment / lens-correction differences don't pollute samples."""
    g = img.mean(axis=2).astype(np.float32)
    mag = np.hypot(cv2.Sobel(g, cv2.CV_32F, 1, 0), cv2.Sobel(g, cv2.CV_32F, 0, 1))
    mag = cv2.dilate(mag, np.ones((5, 5), np.uint8))
    return mag < 0.04


def pair_samples(raf: Path, jpg_path: Path) -> tuple[np.ndarray, np.ndarray, float]:
    raw = develop_raw(raf)
    jpg = load_jpeg(jpg_path)
    raw_a, valid = align(raw, jpg)
    j = resize_w(jpg, WORK_W)
    mask = valid & flat_mask(j) & (raw_a.max(axis=2) < 0.97) & (j.max(axis=2) < 0.995) & (raw_a.max(axis=2) > 1e-5)
    # Margin: lens-correction warps are worst at the frame edge.
    m = int(WORK_W * 0.06)
    mask[:m, :] = mask[-m:, :] = False
    mask[:, :m] = mask[:, -m:] = False
    # Alignment quality: correlation of luminance where valid.
    a = gray_for_align(raw_a, True)[mask]
    b = gray_for_align(j, False)[mask]
    corr = float(np.corrcoef(a, b)[0, 1]) if a.size > 100 else 0.0
    return raw_a[mask], j[mask], corr


def cmd_samples() -> None:
    CACHE.mkdir(exist_ok=True)
    report = {}
    for scene in sorted(p for p in CAPTURES.iterdir() if p.is_dir() and not p.name.startswith("_")):
        for raf in sorted(scene.glob("*.raf")):
            jpg = raf.with_suffix(".jpg")
            out = CACHE / f"{scene.name}__{raf.stem}.npz"
            if not jpg.exists() or (out.exists() and out.stat().st_mtime > raf.stat().st_mtime):
                continue
            x, y, corr = pair_samples(raf, jpg)
            np.savez_compressed(out, x=x, y=y, corr=corr)
            report[f"{scene.name}/{raf.stem}"] = {"n": int(len(x)), "align_corr": round(corr, 4)}
            print(f"{scene.name}/{raf.stem}: {len(x)} samples, align r={corr:.3f}")
    if report:
        (CACHE / "report.json").write_text(json.dumps(report, indent=2))


def load_look(look: str, exclude_scene: str | None = None) -> tuple[np.ndarray, np.ndarray]:
    files = [f for f in sorted(CACHE.glob(f"*__{look}.npz")) if exclude_scene is None or not f.name.startswith(f"{exclude_scene}__")]
    data = [np.load(f) for f in files]
    good = [d for d in data if float(d["corr"]) > 0.9]
    if not good:
        raise SystemExit(f"no well-aligned samples for {look}")
    return np.concatenate([d["x"] for d in good]), np.concatenate([d["y"] for d in good])


def estimate_shaper() -> Shaper:
    """Find the scene-linear level the camera renders as mid grey (sRGB 0.46) under the neutral-ish look."""
    x, y = load_look("provia")
    lum_out = y.mean(axis=1)
    lum_in = x @ np.array([0.2627, 0.6780, 0.0593], np.float32)
    near = np.abs(lum_out - 0.4614) < 0.03
    level = float(np.median(lum_in[near])) if near.sum() > 50 else 0.05
    return Shaper(scale=MID_GREY / level)


def trilinear_matrix(u: np.ndarray, n: int) -> sp.csr_matrix:
    """Sparse (samples x n^3) trilinear interpolation weights for points u in [0,1]^3."""
    f = u * (n - 1)
    i0 = np.clip(np.floor(f).astype(np.int64), 0, n - 2)
    t = f - i0
    rows, cols, vals = [], [], []
    idx = np.arange(len(u))
    for dx in (0, 1):
        for dy in (0, 1):
            for dz in (0, 1):
                w = (t[:, 0] if dx else 1 - t[:, 0]) * (t[:, 1] if dy else 1 - t[:, 1]) * (t[:, 2] if dz else 1 - t[:, 2])
                c = ((i0[:, 0] + dx) * n + (i0[:, 1] + dy)) * n + (i0[:, 2] + dz)
                rows.append(idx)
                cols.append(c)
                vals.append(w)
    return sp.csr_matrix((np.concatenate(vals), (np.concatenate(rows), np.concatenate(cols))), shape=(len(u), n**3))


def laplacian(n: int) -> sp.csr_matrix:
    d = sp.diags([np.ones(n - 1), -2 * np.ones(n), np.ones(n - 1)], [-1, 0, 1], shape=(n, n)).tolil()
    d[0, 0] = d[-1, -1] = -1
    d = d.tocsr()
    eye = sp.identity(n, format="csr")
    return sp.kron(sp.kron(d, eye), eye) + sp.kron(sp.kron(eye, d), eye) + sp.kron(sp.kron(eye, eye), d)


def identity_lattice(n: int, shaper: Shaper) -> np.ndarray:
    """A plain display render (linear Rec.2020 -> sRGB) used as the prior where we have no data."""
    g = np.linspace(0, 1, n)
    enc = np.stack(np.meshgrid(g, g, g, indexing="ij"), -1).reshape(-1, 3)
    lin = MID_GREY * 2.0 ** (enc * (LOG_HI - LOG_LO) + LOG_LO)  # already shaper-normalised
    rec2020_to_srgb = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])
    s = np.clip(lin @ rec2020_to_srgb.T, 0, 1)
    return np.where(s <= 0.0031308, 12.92 * s, 1.055 * np.power(s, 1 / 2.4) - 0.055)


def fit_lut(x: np.ndarray, y: np.ndarray, shaper: Shaper, smooth: float = 0.02, prior: float = 1e-4) -> np.ndarray:
    rng = np.random.default_rng(0)
    if len(x) > 400_000:
        pick = rng.choice(len(x), 400_000, replace=False)
        x, y = x[pick], y[pick]
    a = trilinear_matrix(shaper.encode(x), GRID)
    lap = laplacian(GRID)
    w = len(x) / GRID**3
    lhs = (a.T @ a + (smooth * w) * (lap.T @ lap) + (prior * w) * sp.identity(GRID**3)).tocsc()
    base = identity_lattice(GRID, shaper)
    solve = spla.factorized(lhs)
    out = np.stack([solve(a.T @ y[:, c] + (prior * w) * base[:, c]) for c in range(3)], -1)
    return np.clip(out, 0, 1).reshape(GRID, GRID, GRID, 3)


def apply_lut(lut: np.ndarray, x: np.ndarray, shaper: Shaper) -> np.ndarray:
    a = trilinear_matrix(shaper.encode(x.reshape(-1, 3)), GRID)
    return (a @ lut.reshape(-1, 3)).reshape(x.shape)


def write_cube(path: Path, lut: np.ndarray, title: str) -> None:
    # .cube is red-fastest; our lattice is [r][g][b].
    lines = [f'TITLE "{title}"', f"LUT_3D_SIZE {GRID}", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
    lines += [f"{v[0]:.6f} {v[1]:.6f} {v[2]:.6f}" for v in lut.transpose(2, 1, 0, 3).reshape(-1, 3)]
    path.write_text("\n".join(lines) + "\n")


def looks_available() -> list[str]:
    return sorted({f.name.split("__", 1)[1][:-4] for f in CACHE.glob("*__*.npz")})


def cmd_fit(looks: list[str]) -> None:
    LUTS.mkdir(exist_ok=True)
    shaper = estimate_shaper()
    (LUTS / "shaper.json").write_text(json.dumps({"scale": shaper.scale, "mid_grey": MID_GREY, "log_lo": LOG_LO, "log_hi": LOG_HI, "space": "linear Rec.2020 D65", "output": "sRGB"}, indent=2))
    print(f"shaper scale {shaper.scale:.3f}")
    for look in looks or looks_available():
        x, y = load_look(look)
        lut = fit_lut(x, y, shaper)
        np.savez_compressed(LUTS / f"{look}.npz", lut=lut.astype(np.float32))
        write_cube(LUTS / f"{look}.cube", lut, look)
        print(f"{look}: fitted on {len(x)} samples")


def delta_e(a_srgb: np.ndarray, b_srgb: np.ndarray) -> np.ndarray:
    import colour

    lab = lambda s: colour.XYZ_to_Lab(colour.sRGB_to_XYZ(np.clip(s, 0, 1)))  # noqa: E731
    return colour.delta_E(lab(a_srgb), lab(b_srgb), method="CIE 2000")


def cmd_eval() -> None:
    shaper = estimate_shaper()
    scenes = sorted({f.name.split("__", 1)[0] for f in CACHE.glob("*__*.npz")})
    for look in looks_available():
        errs = []
        for held in scenes if len(scenes) > 1 else [None]:
            x, y = load_look(look, exclude_scene=held)
            lut = fit_lut(x, y, shaper)
            f = CACHE / f"{held}__{look}.npz" if held else None
            d = np.load(f) if f and f.exists() else {"x": x, "y": y}
            pred = apply_lut(lut, d["x"], shaper)
            errs.append(delta_e(pred, d["y"]))
        e = np.concatenate(errs)
        print(f"{look:14s} ΔE2000 mean {e.mean():.2f}  p90 {np.percentile(e, 90):.2f}  ({'held-out scenes' if len(scenes) > 1 else 'in-sample'})")


def cmd_preview(scene: str, look: str) -> None:
    shaper_d = json.loads((LUTS / "shaper.json").read_text())
    shaper = Shaper(scale=shaper_d["scale"])
    lut = np.load(LUTS / f"{look}.npz")["lut"]
    raf = CAPTURES / scene / f"{look}.raf"
    jpg = resize_w(load_jpeg(raf.with_suffix(".jpg")), 1200)
    raw, _ = align(develop_raw(raf), load_jpeg(raf.with_suffix(".jpg")))
    raw = cv2.resize(raw, (jpg.shape[1], jpg.shape[0]), interpolation=cv2.INTER_LINEAR)
    ours = apply_lut(lut, raw, shaper)
    side = np.concatenate([jpg, np.ones((jpg.shape[0], 12, 3)), ours], axis=1)
    out = ROOT / "previews" / f"{scene}__{look}.jpg"
    out.parent.mkdir(exist_ok=True)
    cv2.imwrite(str(out), cv2.cvtColor((np.clip(side, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 92])
    print(out)


if __name__ == "__main__":
    match sys.argv[1:]:
        case ["samples"]:
            cmd_samples()
        case ["fit", *looks]:
            cmd_fit(looks)
        case ["eval"]:
            cmd_eval()
        case ["preview", scene, look]:
            cmd_preview(scene, look)
        case _:
            print(__doc__)
            sys.exit(2)
