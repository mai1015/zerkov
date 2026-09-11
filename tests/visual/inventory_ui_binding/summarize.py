"""Historical/deferred inventory contact-sheet generator.

The source and existing packet remain useful audit history, but this generator
must not write a smaller-resolution packet from the current first-playable
matrix. Remove this guard only through task 11.8 or a later approved
display-support proposal.
"""

raise SystemExit(
    "DEFERRED_DISPLAY_SUITE: inventory_ui_binding summarize.py is historical; "
    "reopen only through task 11.8 or an approved display-support proposal"
)

from pathlib import Path
import json
import gzip
import shutil
from PIL import Image, ImageDraw

PROJECT = Path(__file__).resolve().parents[3]
OUT = PROJECT / "docs/qa/inventory_ui_binding/astra_gate"
REFERENCE = Path("/Volumes/Data/codes/games/zerkov-ui-backup.pdqYzi/after")
RESOLUTIONS = ["1920x1080", "1600x900", "1280x720", "960x540"]
STATES = ["ready", "focused_tooltip", "pending", "accepted_split_50_10", "rejected_restored", "filter_search", "no_match", "resynchronizing", "disconnected"]

def sheet(name, entries, columns, width=480):
    height = width * 9 // 16
    row_height = height + 28
    result = Image.new("RGB", (columns * width, ((len(entries)+columns-1)//columns) * row_height), "#161917")
    draw = ImageDraw.Draw(result)
    for index, (label, path) in enumerate(entries):
        x, y = index % columns * width, index // columns * row_height
        draw.text((x+8, y+8), label, fill="#e6e8e3")
        value = Image.open(path).convert("RGB")
        value.thumbnail((width, height), Image.Resampling.LANCZOS)
        result.paste(value, (x, y+28))
    result.save(OUT / name)

sheet("core_state_matrix.png", [(f"{resolution} / {state}", OUT / f"{resolution}_{state}.png") for state in STATES for resolution in RESOLUTIONS], 4)
for resolution in RESOLUTIONS:
    sheet(f"{resolution}_core_sheet.png", [(state, OUT / f"{resolution}_{state}.png") for state in STATES], 2, 640)
sheet("reference_comparison.png", [(f"{resolution} / {kind}", (REFERENCE / resolution / "inventory.png") if kind == "approved" else (OUT / f"{resolution}_ready.png")) for resolution in RESOLUTIONS for kind in ["approved", "live"]], 2, 960)
sheet("compact_detail_sheet.png", [(state, OUT / f"960x540_{state}.png") for state in ["loadout_top", "loadout_bottom", "stash_top", "stash_bottom", "edge_tooltip", "wheel_over_item"]], 2, 960)

comparisons = []
for resolution in RESOLUTIONS:
    before = Image.open(REFERENCE / resolution / "inventory.png").convert("RGB")
    after = Image.open(OUT / f"{resolution}_ready.png").convert("RGB")
    # Static chrome geometry/pixels are independent of canonical fixture contents.
    top = round(56 * min(before.width/1920, before.height/1080)) if resolution != "960x540" else 56
    a, b = before.crop((0, 0, before.width, top)), after.crop((0, 0, after.width, top))
    changed = sum(x != y for x, y in zip(a.get_flattened_data(), b.get_flattened_data()))
    comparisons.append({"resolution": resolution, "before": before.size, "after": after.size, "chrome_region_height": top, "chrome_changed_pixels": changed, "chrome_pixels": a.width*a.height})
(OUT / "reference_comparison.json").write_text(json.dumps(comparisons, indent=2) + "\n")

source = OUT / "native_capture.log"
archive = OUT / "native_capture.full.log.gz"
lines = (source.read_text() if source.exists() else gzip.open(archive, "rt").read()).splitlines()
first_error = next((i for i, line in enumerate(lines) if "SCRIPT ERROR" in line or line.startswith("ERROR:")), len(lines))
summary = {
    "script_error_count": sum("SCRIPT ERROR" in line for line in lines),
    "error_count": sum(line.startswith("ERROR:") for line in lines),
    "stack_overflow_count": sum("Stack overflow" in line for line in lines),
    "leak_warning_count": sum("leak" in line.lower() for line in lines),
    "gate_result": "FAIL_DIAGNOSTICS",
    "note": "Capture save counters do not count engine diagnostics. Any engine diagnostic fails this gate.",
}
(OUT / "native_diagnostics.json").write_text(json.dumps(summary, indent=2) + "\n")
(OUT / "native_diagnostics_excerpt.log").write_text("\n".join(lines[max(0, first_error-2):first_error+75]) + "\n")
if source.exists():
    with source.open("rb") as raw, gzip.open(archive, "wb", compresslevel=9) as compressed:
        shutil.copyfileobj(raw, compressed)
print(json.dumps({"diagnostics": summary, "comparisons": comparisons}, indent=2))
