"""Reproduce the app's viewfinder and capture paths on saved phone pairs and render them side by side."""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

import fit
import preview_fit as pf

ROOT = Path(__file__).resolve().parent
ANCHOR = 0.75
CURVE = np.array(json.loads((ROOT / "phone" / "preview_curve.json").read_text())["coefficients"])
LUM = np.array([0.2627, 0.6780, 0.0593], np.float32)


def curve(x: np.ndarray) -> np.ndarray:
    t = np.clip(np.log2(np.maximum(x, 0.18 * 2**-9) / 0.18), -9, 4)
    y = np.stack([CURVE[c, 0] + t[..., c] * (CURVE[c, 1] + t[..., c] * (CURVE[c, 2] + t[..., c] * CURVE[c, 3])) for c in range(3)], -1)
    return 0.18 * 2**y


def geo(x: np.ndarray) -> float:
    return float(np.exp(np.mean(np.log(np.maximum(x @ LUM, 1e-5)))))


def geo3(x: np.ndarray) -> np.ndarray:
    return np.exp(np.mean(np.log(np.maximum(x.reshape(-1, 3), 1e-5)), axis=0))


def look(lin: np.ndarray, lut: np.ndarray) -> np.ndarray:
    return np.clip(fit.apply_lut(lut, lin, fit.Shaper(scale=1.0)), 0, 1)


def to8(x: np.ndarray) -> np.ndarray:
    return cv2.cvtColor((np.clip(x, 0, 1) * 255).astype(np.uint8), cv2.COLOR_RGB2BGR)


def srgb(lin: np.ndarray) -> np.ndarray:
    m = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])
    s = np.clip(lin @ m.T, 0, 1)
    return np.where(s <= 0.0031308, 12.92 * s, 1.055 * s ** (1 / 2.4) - 0.055)


def main(lookname: str, dirs: list[str]) -> None:
    lut = np.load(fit.LUTS / f"{lookname}.npz")["lut"]
    rows = []
    for d in dirs:
        p = ROOT / "phone" / d
        prev = pf.load(p / "preview.tiff")
        still_name = "raw.tiff" if (p / "raw.tiff").exists() else "processed.tiff"
        still = pf.load(p / still_name)
        prev = max((prev, prev[:, ::-1].copy()), key=lambda c: pf.align(c, still)[2])
        prev, _, _ = pf.align(prev, still)
        vf = look(curve(prev) * ANCHOR, lut)
        if still_name == "raw.tiff":
            final = look(still * (geo3(curve(prev)) / geo3(still)) * ANCHOR, lut)
        else:
            final = look(curve(still) * (geo(prev) / geo(still)) * ANCHOR, lut)
        gap = np.log2(geo(prev) / geo(still))
        sep = np.ones((vf.shape[0], 8, 3))
        rows.append(np.concatenate([srgb(prev), sep, vf, sep, final], axis=1))
        print(f"{d}: {still_name} exposure gap {gap:+.2f} stops, mean |vf-final| {np.abs(vf - final).mean():.3f}")
    out = ROOT / "previews" / f"app_{lookname}.jpg"
    out.parent.mkdir(exist_ok=True)
    cv2.imwrite(str(out), to8(np.concatenate([r for r in rows], axis=0)), [cv2.IMWRITE_JPEG_QUALITY, 88])
    print(out)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
