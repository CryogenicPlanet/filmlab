"""Export fitted LUTs into the iOS bundle: <id>.cube (RGBA float32, red fastest) + looks.json."""

import json
from pathlib import Path

import numpy as np

import fit

DEST = Path(__file__).resolve().parent.parent / "ios" / "Filmlab" / "Resources" / "Looks"

# Our own names: these are measured re-creations, not Fujifilm's products.
# Fujifilm's names ship only as `fujiName` for debug builds on Rahul's phone; release builds never show them.
FUJI = {
    "provia": "Provia", "velvia": "Velvia", "astia": "Astia", "classicchrome": "Classic Chrome",
    "classicneg": "Classic Neg", "nostalgic": "Nostalgic Neg", "reala": "Reala Ace", "eterna": "Eterna",
    "bleach": "Bleach Bypass", "proneghi": "Pro Neg Hi", "pronegstd": "Pro Neg Std", "acros": "Acros", "mono": "Monochrome",
}
LOOKS = [
    ("provia", "standard", "Standard", "Balanced, faithful slide-film colour."),
    ("velvia", "vivid-slide", "Vivid Slide", "Deep saturation and contrast for landscapes and colour."),
    ("astia", "soft-slide", "Soft Slide", "Gentle contrast, kind to skin, still colourful."),
    ("classicchrome", "documentary", "Documentary", "Muted colour, firm shadows, reportage feel."),
    ("classicneg", "street-neg", "Street Neg", "Hard-toned colour negative with shifted hues."),
    ("nostalgic", "amber-neg", "Amber Neg", "Warm, amber-tinted print with soft highlights."),
    ("reala", "true-color", "True Colour", "Natural, accurate colour with a clean finish."),
    ("eterna", "cinema", "Cinema", "Flat, low-saturation motion-picture tone."),
    ("bleach", "bleach", "Bleach", "Silvery, desaturated, high-contrast."),
    ("proneghi", "portrait-hi", "Portrait Hi", "Studio negative with a bit more punch."),
    ("pronegstd", "portrait", "Portrait", "Soft studio negative, smooth skin tones."),
    ("acros", "silver", "Silver", "Rich black-and-white with fine tonality."),
    ("mono", "mono", "Mono", "Plain black-and-white."),
]


def main() -> None:
    DEST.mkdir(parents=True, exist_ok=True)
    looks = []
    for src, ident, name, blurb in LOOKS:
        path = fit.LUTS / f"{src}.npz"
        if not path.exists():
            print(f"skip {src}: not fitted")
            continue
        lut = np.load(path)["lut"].astype(np.float32)  # [r][g][b][3]
        rgba = np.concatenate([lut, np.ones(lut.shape[:3] + (1,), np.float32)], axis=-1)
        rgba.transpose(2, 1, 0, 3).tofile(DEST / f"{ident}.cube")  # -> [b][g][r]: red fastest
        looks.append({"id": ident, "name": name, "fujiName": FUJI[src], "blurb": blurb, "monochrome": src in ("acros", "mono")})
    manifest = {"gridSize": fit.GRID, "midGrey": fit.MID_GREY, "logLo": fit.LOG_LO, "logHi": fit.LOG_HI, "looks": looks}
    (DEST / "looks.json").write_text(json.dumps(manifest, indent=2))
    print(f"exported {len(looks)} looks to {DEST}")


if __name__ == "__main__":
    main()
