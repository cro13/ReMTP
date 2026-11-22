#!/usr/bin/env python3
# Usage: python3 docs/benchmarks/render_charts.py
"""Render the benchmark charts in docs/benchmarks/ from results.json.

Writes <chart>-{light,dark}.svg next to this file for every chart in CHARTS. Standard library only,
no network, and the output depends only on results.json, so re-running it gives the same bytes.

Each chart is a set of small multiples: one row per dataset, each row on its own time scale (times
differ by 40x between datasets), horizontal bars from zero, every bar labeled with its series, time
and MB/s. Colors are a validated categorical set (blue, orange, aqua) stepped separately for GitHub's
light (#ffffff) and dark (#0d1117) backgrounds; the SVG background is transparent.
"""

import json
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path
from xml.sax.saxutils import escape

HERE = Path(__file__).resolve().parent

WIDTH = 800
PAD = 24
BAR_X = 188  # where every bar starts (the zero baseline)
BAR_MAX = 340  # length of the longest bar in a row
BAR_H = 16
BAR_SLOT = 28  # vertical space per bar
FONT = '-apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif'

THEMES = {
    "light": {
        "primary": "#0b0b0b",
        "secondary": "#52514e",
        "hairline": "#e1e0d9",
        "baseline": "#a8a79f",
        "critical": "#d03b3b",
        "series": {"remtp": "#2a78d6", "openmtp": "#eb6834", "openmtp_zlpfix": "#1baf7a"},
    },
    "dark": {
        "primary": "#f0efec",
        "secondary": "#c3c2b7",
        "hairline": "#30363d",
        "baseline": "#6e7681",
        "critical": "#d03b3b",
        "series": {"remtp": "#3987e5", "openmtp": "#d95926", "openmtp_zlpfix": "#199e70"},
    },
}

# Rows, in display order: (dataset, direction). The headline comes first.
ROWS = [("B", "upload"), ("A", "upload"), ("C", "upload"), ("A", "download")]

CHARTS = {
    "sp3000": {
        "engines": ["remtp", "openmtp"],
        "compare_to": {"upload": "openmtp", "download": "openmtp"},
        "title": "ReMTP uploads 1,000 small files 12.4× faster than OpenMTP’s engine",
        "row_labels": {"openmtp": "OpenMTP 3.3.0 engine"},
        "extra_notes": [],
    },
    "lenovo": {
        "engines": ["remtp", "openmtp", "openmtp_zlpfix"],
        "compare_to": {"upload": "openmtp_zlpfix", "download": "openmtp"},
        "title": "Stock OpenMTP 3.3.0’s engine can’t upload to this tablet at all",
        "row_labels": {"openmtp": "OpenMTP 3.3.0 engine", "openmtp_zlpfix": ["go-mtpfs + ZLP fix", "not OpenMTP 3.3.0"]},
        "extra_notes": [
            "The stock engine times out after ~31 s on every upload (LIBUSB_ERROR_TIMEOUT, OpenMTP issue #411). “go-mtpfs with the",
            "ZLP fix” is that engine with one bug patched (bench/openmtp-harness/zlpfix.patch); it is not OpenMTP 3.3.0.",
        ],
    },
    "studio-sp3000": {
        "engines": ["remtp", "openmtp"],
        "compare_to": {"upload": "openmtp", "download": "openmtp"},
        "title": "ReMTP uploads 1,000 small files 19.4× faster than OpenMTP’s engine",
        "row_labels": {"openmtp": "OpenMTP 3.3.0 engine"},
        "extra_notes": [],
    },
    "studio-tab-s5e": {
        "engines": ["remtp", "openmtp"],
        "compare_to": {"upload": "openmtp", "download": "openmtp"},
        "title": "ReMTP uploads 1,000 small files 21.5× faster than OpenMTP’s engine",
        "row_labels": {"openmtp": "OpenMTP 3.3.0 engine"},
        "extra_notes": [],
    },
}


# ---------- numbers ----------


def dec(x):
    return Decimal(str(x))


def fmt1(x):
    return str(dec(x).quantize(Decimal("0.1"), rounding=ROUND_HALF_UP))


def fmt_time(seconds):
    s = fmt1(seconds) + " s"
    if seconds >= 120:
        whole = int(dec(seconds).quantize(Decimal("1"), rounding=ROUND_HALF_UP))
        s += f" ({whole // 60} min {whole % 60} s)" if whole % 60 else f" ({whole // 60} min)"
    return s


def cell(results, device, dataset, direction, engine, sizes):
    """One bar: the run, or the mean of several runs. Returns a dict or None if not measured."""
    runs = [
        r
        for r in results
        if r["device"] == device and r["dataset"] == dataset and r["direction"] == direction and r["engine"] == engine
    ]
    if not runs:
        return None
    if any("failed" in r for r in runs):
        assert all("failed" in r for r in runs), (device, dataset, engine)
        return {"failed": True}
    if len(runs) == 1:
        return {"seconds": dec(runs[0]["seconds"]), "mbps": dec(runs[0]["mb_per_s"]), "runs": 1}
    mean = sum(dec(r["seconds"]) for r in runs) / len(runs)
    mbps = dec(sizes[dataset]) / Decimal(1_000_000) / mean
    return {"seconds": mean, "mbps": mbps, "runs": len(runs), "each": [r["seconds"] for r in runs]}


# ---------- text measuring (approximate, for layout checks only) ----------

_W = {}
for ch in "il.,:;'|!·’":
    _W[ch] = 0.26
for ch in "fjtrI()[]/ -":
    _W[ch] = 0.33
for ch in "0123456789$#×":
    _W[ch] = 0.57
for ch in "mwMW%":
    _W[ch] = 0.86
for ch in "ABCDEFGHJKLNOPQRSTUVXYZ&":
    _W[ch] = 0.67


def text_width(text, size, bold=False):
    w = sum(_W.get(ch, 0.54) for ch in text) * size
    return w * (1.05 if bold else 1.0)


def wrap(text, size):
    """Greedy word wrap to the chart's text width."""
    lines, line = [], ""
    for word in text.split(" "):
        candidate = f"{line} {word}" if line else word
        if line and text_width(candidate, size) >= WIDTH - 2 * PAD - 8:
            lines.append(line)
            line = word
        else:
            line = candidate
    return lines + [line]


# ---------- svg pieces ----------


def t(x, y, text, cls, anchor="start"):
    a = "" if anchor == "start" else f' text-anchor="{anchor}"'
    return f'<text x="{x:g}" y="{y:g}" class="{cls}"{a}>{escape(text)}</text>'


def bar_path(key, x, y, w, h, r=4):
    # Square at the baseline, 4px rounded data end.
    return (
        f'<path d="M{x:g} {y:g}h{w - r:g}a{r} {r} 0 0 1 {r} {r}v{h - 2 * r:g}'
        f'a{r} {r} 0 0 1 -{r} {r}h-{w - r:g}z" class="s-{key}"/>'
    )


def fail_marker(x, y_mid):
    cx, r, d = x + 7, 6.5, 3
    return (
        f'<circle cx="{cx:g}" cy="{y_mid:g}" r="{r}" class="crit-stroke"/>'
        f'<path d="M{cx - d:g} {y_mid - d:g}l{2 * d} {2 * d}M{cx + d:g} {y_mid - d:g}l-{2 * d} {2 * d}" class="crit-stroke"/>'
    )


def render(device_key, theme_name, data):
    spec = CHARTS[device_key]
    theme = THEMES[theme_name]
    dev = data["devices"][device_key]
    sizes = {k: v["files"] * v["bytes_each"] for k, v in data["datasets"].items()}
    names = data["engines"]
    engines = spec["engines"]

    # A title that states the 1,000-file speed-up must match the number computed from results.json.
    if "× faster" in spec["title"]:
        b = {k: cell(data["results"], device_key, "B", "upload", k, sizes) for k in ("remtp", "openmtp")}
        ratio = fmt1(b["openmtp"]["seconds"] / b["remtp"]["seconds"])
        assert f" {ratio}× faster" in spec["title"], (device_key, ratio, spec["title"])

    out = []
    desc = []
    y = 36
    out.append(t(PAD, y, spec["title"], "title"))
    assert text_width(spec["title"], 19, True) < WIDTH - 2 * PAD, spec["title"]
    y += 24
    sub = f"{dev['name']} ({dev['os']}), {dev['link']}. Wall time in seconds: shorter is faster. Each row has its own scale."
    out.append(t(PAD, y, sub, "sub"))
    assert text_width(sub, 13) < WIDTH - 2 * PAD, sub

    # Legend: swatch + full series name. Wraps when the next item would not fit.
    y += 28
    x = PAD
    for key in engines:
        label = names[key]
        w = 18 + text_width(label, 13) + 24
        if x + w > WIDTH - PAD:
            x, y = PAD, y + 22
        out.append(f'<rect x="{x:g}" y="{y - 10:g}" width="12" height="12" rx="2" class="s-{key}"/>')
        out.append(t(x + 18, y, label, "legend"))
        x += w
    if any("failed" in r for r in data["results"] if r["device"] == device_key):
        w = 22 + text_width("fails (no bar)", 13)
        if x + w > WIDTH - PAD:
            x, y = PAD, y + 22
        out.append(fail_marker(x - 1, y - 4.5))
        out.append(t(x + 18, y, "fails (no bar)", "legend"))

    y += 20
    out.append(f'<line x1="{PAD}" x2="{WIDTH - PAD}" y1="{y:g}" y2="{y:g}" class="hair"/>')

    means = []
    for dataset, direction in spec.get("rows", ROWS):
        cells = {k: cell(data["results"], device_key, dataset, direction, k, sizes) for k in engines}
        measured = {k: c for k, c in cells.items() if c and not c.get("failed")}
        scale = max(c["seconds"] for c in measured.values())
        label = f"{data['datasets'][dataset]['label']} {direction}"
        runs = max(c.get("runs", 1) for c in measured.values())
        if runs > 1:
            label += f" (mean of {runs} runs)"
            means.append((dataset, direction, {k: c["each"] for k, c in measured.items()}))

        y += 26
        out.append(t(PAD, y, label, "row"))
        ref_key = spec["compare_to"][direction]
        ref = cells.get(ref_key)
        if ref and not ref.get("failed"):
            ratio = ref["seconds"] / cells["remtp"]["seconds"]
            vs = "" if ref_key == "openmtp" else " than the patched engine"
            speed = f"ReMTP {fmt1(ratio)}× faster{vs}"
            out.append(t(WIDTH - PAD, y, speed, "speed", "end"))
            assert text_width(label, 14, True) + text_width(speed, 14, True) + 24 < WIDTH - 2 * PAD, label
            desc.append(f"{label}: {speed}.")
        else:
            desc.append(f"{label}:")

        top = y + 12
        out.append(
            f'<line x1="{BAR_X}" x2="{BAR_X}" y1="{top - 4:g}" y2="{top + len(engines) * BAR_SLOT - BAR_SLOT + BAR_H + 4:g}" class="base"/>'
        )
        for i, key in enumerate(engines):
            by = top + i * BAR_SLOT
            mid = by + BAR_H / 2
            row_label = spec["row_labels"].get(key, names[key])
            if isinstance(row_label, list):
                out.append(t(PAD, mid - 1, row_label[0], "series"))
                out.append(t(PAD, mid + 12, row_label[1], "series-note"))
            else:
                out.append(t(PAD, mid + 4.5, row_label, "series"))
            c = cells[key]
            if c is None:
                out.append(t(BAR_X + 8, mid + 4.5, "not measured", "note"))
                desc.append(f"{names[key]}: not measured.")
            elif c.get("failed"):
                out.append(fail_marker(BAR_X + 4, mid))
                out.append(t(BAR_X + 22, mid + 4.5, "fails: timeout, 0 bytes written", "value"))
                desc.append(f"{names[key]}: fails, timeout, 0 bytes written.")
            else:
                w = float(c["seconds"] / scale) * BAR_MAX
                out.append(bar_path(key, BAR_X, by, round(w, 1), BAR_H))
                tm, mb = fmt_time(c["seconds"]), f"{fmt1(c['mbps'])} MB/s"
                lx = BAR_X + w + 8
                out.append(
                    f'<text x="{lx:.1f}" y="{mid + 4.5:g}" class="value">{escape(tm)}'
                    f'<tspan class="value-2"> · {escape(mb)}</tspan></text>'
                )
                assert lx + text_width(tm + " · " + mb, 13) < WIDTH - 4, (label, key)
                desc.append(f"{names[key]}: {tm}, {mb}.")
        y = top + len(engines) * BAR_SLOT + 4
        out.append(f'<line x1="{PAD}" x2="{WIDTH - PAD}" y1="{y:g}" y2="{y:g}" class="hair"/>')

    # Footnote.
    notes = []
    for dataset, direction, each in means:
        parts = "; ".join(f"{names[k]} " + " s, ".join(fmt1(v) for v in vals) + " s" for k, vals in each.items())
        notes.append(f"{data['datasets'][dataset]['label']} {direction}: mean of the runs ({parts}).")
    notes.append("MB/s for a mean is the data size divided by the mean time.")
    notes += spec["extra_notes"]
    rnd = data["rounds"][dev["round"]]
    notes += wrap(
        f"Method: ReMTP {rnd['remtp']} vs go-mtpx@18f12db + go-mtpfs@1c3302b (the engine inside OpenMTP 3.3.0, "
        f"run without its UI, with {dev['libusb']}). {rnd['host']}, random data, MB = 10^6 B. "
        "Details and raw tables: see docs/BENCHMARKS.md.",
        11.5,
    )
    y += 22
    for line in notes:
        assert text_width(line, 11.5) < WIDTH - 2 * PAD, line
        out.append(t(PAD, y, line, "foot"))
        y += 16
    height = int(y + 4)

    s = theme["series"]
    style = f"""
text{{font-family:{FONT};font-variant-numeric:tabular-nums}}
.title{{font-size:19px;font-weight:600;fill:{theme['primary']}}}
.sub{{font-size:13px;fill:{theme['secondary']}}}
.legend{{font-size:13px;fill:{theme['primary']}}}
.row{{font-size:14px;font-weight:600;fill:{theme['primary']}}}
.speed{{font-size:14px;font-weight:600;fill:{theme['primary']}}}
.series{{font-size:12.5px;fill:{theme['primary']}}}
.series-note{{font-size:11px;fill:{theme['secondary']}}}
.value{{font-size:13px;font-weight:600;fill:{theme['primary']}}}
.value-2{{font-weight:400;fill:{theme['secondary']}}}
.note{{font-size:12.5px;font-style:italic;fill:{theme['secondary']}}}
.foot{{font-size:11.5px;fill:{theme['secondary']}}}
.hair{{stroke:{theme['hairline']};stroke-width:1}}
.base{{stroke:{theme['baseline']};stroke-width:1}}
.crit-stroke{{fill:none;stroke:{theme['critical']};stroke-width:1.75;stroke-linecap:round}}
.s-remtp{{fill:{s['remtp']}}}
.s-openmtp{{fill:{s['openmtp']}}}
.s-openmtp_zlpfix{{fill:{s['openmtp_zlpfix']}}}
"""
    title = f"{spec['title']} ({dev['name']}, {dev['link']})"
    description = " ".join(desc + notes)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" viewBox="0 0 {WIDTH} {height}" '
        f'role="img" aria-labelledby="t d">\n'
        f'<title id="t">{escape(title)}</title>\n'
        f'<desc id="d">{escape(description)}</desc>\n'
        f"<style>{style}</style>\n" + "\n".join(out) + "\n</svg>\n"
    )


def main():
    data = json.loads((HERE / "results.json").read_text(encoding="utf-8"))
    for device_key in CHARTS:
        for theme_name in THEMES:
            path = HERE / f"{device_key}-{theme_name}.svg"
            path.write_text(render(device_key, theme_name, data), encoding="utf-8")
            print(f"wrote {path.relative_to(HERE.parent.parent)}")


if __name__ == "__main__":
    main()
