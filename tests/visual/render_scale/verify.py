#!/usr/bin/env python3
"""Run native evidence and existing UI regressions; assemble labeled QA sheets."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "docs/qa/render_scale"
CANDIDATES = ("320_fixed", "640_fractional", "640_integer", "adaptive_integer")
RESOLUTIONS = ((1920, 1080), (1600, 900), (1280, 720))


def sheets():
    font = ImageFont.truetype(str(ROOT / "assets/fonts/IBMPlexMono-Regular.ttf"), 16)
    sheet = Image.new("RGB", (1920, 3 * 310 + 42), "#0a0b0a")
    draw = ImageDraw.Draw(sheet)
    draw.text((16, 10), "RENDER SCALE / NATIVE GODOT CAPTURES / thumbnails only; inspect original PNGs for pixel fidelity", font=font, fill="#e6e8e3")
    for row, (width, height) in enumerate(RESOLUTIONS):
        for column, candidate in enumerate(CANDIDATES):
            path = OUT / f"{width}x{height}_{candidate}.png"
            with Image.open(path) as frame:
                assert frame.size == (width, height), path
                thumb = frame.convert("RGB").resize((480, 270), Image.Resampling.NEAREST)
            x, y = column * 480, 42 + row * 310
            draw.text((x + 8, y + 8), f"{width}x{height} / {candidate}", font=font, fill="#e8962e")
            sheet.paste(thumb, (x, y + 36))
    sheet.save(OUT / "comparison_sheet.png")
    # Crops retain original pixels at 1:1. No enhancement/sharpening is applied.
    details = Image.new("RGB", (1040, 560), "#0a0b0a")
    draw = ImageDraw.Draw(details)
    metrics = json.loads((OUT / "metrics.json").read_text())
    for index, candidate in enumerate(CANDIDATES):
        record = next(r for r in metrics["records"] if r["key"] == f"1600x900_{candidate}")
        scale, zoom = record["scale"], record["zoom"]
        sx, sy = record["surface"]
        ox, oy, _, _ = record["display_rect"]
        px, py = ox + (sx / 2 - 148 * zoom) * scale, oy + (sy / 2 - 104 * zoom) * scale
        x, y = (index % 2) * 520, (index // 2) * 280
        draw.text((x + 12, y + 12), f"900p / {candidate} / 1:1 pixels", font=font, fill="#e8962e")
        with Image.open(OUT / f"1600x900_{candidate}.png") as frame:
            details.paste(frame.crop((int(px), int(py), int(px) + 480, int(py) + 224)).convert("RGB"), (x + 12, y + 42))
    details.save(OUT / "900p_pixel_details.png")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default="/Volumes/Data/sdk/godot/editors/4.7.2/Godot.app/Contents/MacOS/Godot")
    parser.add_argument("--sheets-only", action="store_true")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if not args.sheets_only:
        cases = [("capture", False, "tests/visual/render_scale/capture.gd"),
                 ("ui_composition", True, "tests/ui_composition_smoke.gd"),
                 ("responsive", True, "tests/responsive_smoke.gd"),
                 ("border_render", False, "tests/border_render_smoke.gd")]
        results = []
        for name, headless, script in cases:
            command = [args.godot] + (["--headless"] if headless else []) + ["--path", str(ROOT), "--script", "res://" + script]
            result = subprocess.run(command, capture_output=True, text=True, timeout=180, cwd=ROOT)
            output = result.stdout + result.stderr
            (OUT / f"{name}.log").write_text(output)
            passed = result.returncode == 0 and "SCRIPT ERROR" not in output and "ERROR:" not in output
            completions = [line for line in output.splitlines() if "COMPLETE" in line or "PASS" in line]
            results.append({"name": name, "command": command, "exit_code": result.returncode, "passed": passed, "summary": completions})
            print(name, "PASS" if passed else "FAIL", " | ".join(completions))
        (OUT / "verification.json").write_text(json.dumps(results, indent=2) + "\n")
        if not all(result["passed"] for result in results):
            raise SystemExit("At least one runtime check failed; inspect logs.")
    sheets()
    manifest = {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in sorted(OUT.glob("*.png"))}
    (OUT / "captures.sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Generated contact sheets and SHA-256 manifest for {len(manifest)} PNGs.")


if __name__ == "__main__":
    main()
