"""Fit the iPhone viewfinder (Apple-processed video, linearised by Core Image) to the ProRAW linear develop.

Input: phone/<ts>/{preview,raw}.tiff — linear Rec.2020 ×0.25, 16-bit, from the app's debug dump.
Output: per-channel cubic in log2 space, t = log2(x / 0.18): y = c0 + c1 t + c2 t² + c3 t³, raw = 0.18·2^y.
"""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent / "phone"
EPS = 0.18 * 2.0**-9


def load(p: Path) -> np.ndarray:
    img = cv2.imread(str(p), cv2.IMREAD_UNCHANGED)
    rgb = cv2.cvtColor(img, cv2.COLOR_BGRA2RGB if img.shape[2] == 4 else cv2.COLOR_BGR2RGB)
    return rgb.astype(np.float32) / 65535.0 * 4.0


def lum(x: np.ndarray) -> np.ndarray:
    return x @ np.array([0.2627, 0.6780, 0.0593], np.float32)


def align(src: np.ndarray, dst: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    """Warp src onto dst using ECC on log luminance (robust to the two different tone curves)."""
    src = cv2.resize(src, (dst.shape[1], dst.shape[0]), interpolation=cv2.INTER_AREA)
    g = lambda x: (lambda l: (l - l.mean()) / (l.std() + 1e-6))(cv2.GaussianBlur(np.log2(np.maximum(lum(x), EPS)), (0, 0), 1.5))  # noqa: E731
    warp = np.eye(2, 3, dtype=np.float32)
    try:
        cc, warp = cv2.findTransformECC(g(dst), g(src), warp, cv2.MOTION_AFFINE, (cv2.TERM_CRITERIA_EPS | cv2.TERM_CRITERIA_COUNT, 200, 1e-6), None, 5)
    except cv2.error:
        cc = 0.0
    size = (dst.shape[1], dst.shape[0])
    out = cv2.warpAffine(src, warp, size, flags=cv2.INTER_LINEAR | cv2.WARP_INVERSE_MAP)
    valid = cv2.warpAffine(np.ones(src.shape[:2], np.float32), warp, size, flags=cv2.WARP_INVERSE_MAP) > 0.999
    return out, valid, float(cc)


def main() -> None:
    xs, ys = [], []
    for d in sorted(p for p in ROOT.iterdir() if (p / "raw.tiff").exists()):
        raw, prev = load(d / "raw.tiff"), load(d / "preview.tiff")
        # Selfie viewfinder frames are mirrored; the RAW is not.
        prev_a, valid, cc = max((align(prev, raw), align(prev[:, ::-1].copy(), raw)), key=lambda r: r[2])
        gm = np.hypot(*np.gradient(cv2.GaussianBlur(np.log2(np.maximum(lum(raw), EPS)), (0, 0), 1.0)))
        mask = valid & (gm < 0.15) & (raw.max(axis=2) < 3.9) & (prev_a.max(axis=2) < 0.995 * 4) & (raw.min(axis=2) > EPS) & (prev_a.min(axis=2) > EPS)
        m = 12
        mask[:m] = mask[-m:] = False
        mask[:, :m] = mask[:, -m:] = False
        print(f"{d.name}: {raw.shape[1]}x{raw.shape[0]} align r={cc:.3f} samples={mask.sum()} "
              f"median lum preview={np.median(lum(prev_a)[mask]):.4f} raw={np.median(lum(raw)[mask]):.4f}")
        if cc > 0.85:
            # Per-shot exposure: the iPhone may underexpose the RAW by several stops and lift it in processing.
            # Match geometric-mean luminance so the curve captures tone shape only (the app does the same per shot).
            gp = np.exp(np.mean(np.log(lum(prev_a[mask]))))
            gr = np.exp(np.mean(np.log(lum(raw[mask]))))
            print(f"    exposure gap {np.log2(gp / gr):+.2f} stops")
            xs.append(prev_a[mask])
            ys.append(raw[mask] * (gp / gr))
    x, y = np.concatenate(xs), np.concatenate(ys)
    tx, ty = np.log2(x / 0.18), np.log2(y / 0.18)
    # One curve shared by all channels: a per-channel fit bakes the video-vs-RAW white-balance difference of the
    # calibration scenes into the viewfinder as a colour cast.
    t, u = tx.reshape(-1), ty.reshape(-1)
    A = np.stack([np.ones_like(t), t, t**2, t**3], 1)
    k = np.linalg.lstsq(A, u, rcond=None)[0]
    r = np.abs(A @ k - u)
    keep = r < np.percentile(r, 90)
    k = np.linalg.lstsq(A[keep], u[keep], rcond=None)[0]
    res = (A @ k - u).reshape(-1, 3)
    print(f"shared coef {np.round(k, 4).tolist()}  residual stops: median {np.median(np.abs(res)):.3f}  p90 {np.percentile(np.abs(res), 90):.3f}")
    print("per-channel mean bias (stops):", np.round(res.mean(axis=0), 3).tolist())
    coefs = [k.tolist()] * 3
    # Compare with the current placeholder (×0.8).
    base = np.abs(np.log2(np.maximum(x, EPS) / y))
    print(f"identity (exposure-matched) error stops: median {np.median(base):.3f} p90 {np.percentile(base, 90):.3f}")
    (ROOT / "preview_curve.json").write_text(json.dumps({"coefficients": coefs, "pairs": len(xs)}, indent=2))
    # Slope at mid grey tells how much extra contrast the video path carries.
    print("slope at mid grey:", round(coefs[0][1], 3))


if __name__ == "__main__":
    sys.exit(main())
