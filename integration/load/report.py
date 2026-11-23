#!/usr/bin/env python3
"""Turns k6 summary exports and the sample logs into the markdown the report uses.

k6's summary export already carries every custom Trend with the statistics this
run asked for (`summaryTrendStats`), one metric per endpoint per load level.
What it does not carry is *when the first error happened* or the per-level error
mix -- k6 aggregates counters across the whole run -- so the `LOADERR` console
lines are re-bucketed here using the same stage boundaries the scripts use:
<20s -> 10 VUs, <60s -> 50, <100s -> 100, <140s -> 200, then ramp-down.
"""

from __future__ import annotations

import argparse
import json
from contextlib import suppress
from pathlib import Path

LEVELS = [
    ("10", 0.0, 20.0),
    ("50", 20.0, 60.0),
    ("100", 60.0, 100.0),
    ("200", 100.0, 140.0),
    ("rampdown", 140.0, 160.0),
]

SCENARIOS = [
    ("anonymous", "Anonymous read mix"),
    ("auth-warm", "Authenticated read mix, warm home cache"),
    ("auth-cold", "Authenticated read mix, cold home cache"),
    ("write", "Write mix"),
]


def level_of(elapsed_ms: float) -> str:
    seconds = elapsed_ms / 1000.0
    for name, start, end in LEVELS:
        if start <= seconds < end:
            return name
    return "rampdown"


def level_seconds(name: str) -> float:
    for candidate, start, end in LEVELS:
        if candidate == name:
            return end - start
    return 30.0


def endpoint_of(metric: str) -> str | None:
    for suffix in {name for name, _, _ in LEVELS}:
        marker = f"_{suffix}"
        if metric.endswith(marker):
            base = metric[: -len(marker)]
            if base in ("load_errors", "load_requests"):
                return None
            return base
    return None


def parse_errors(log: Path) -> dict:
    """First error, per endpoint and per level, from the LOADERR lines."""
    first: dict[str, dict] = {}
    kinds: dict[tuple[str, str], int] = {}
    if not log.exists():
        return {"first": first, "kinds": kinds, "total": 0}
    total = 0
    for line in log.read_text(errors="replace").splitlines():
        if "LOADERR\t" not in line:
            continue
        parts = line.split("LOADERR\t", 1)[1].split("\t")
        if len(parts) < 4:
            continue
        try:
            elapsed = float(parts[0])
        except ValueError:
            continue
        endpoint, status = parts[1], parts[2]
        total += 1
        kind = status + (f" {parts[3].strip()}" if len(parts) > 3 else "")
        level = level_of(elapsed)
        kinds[(endpoint, level)] = kinds.get((endpoint, level), 0) + 1
        entry = first.setdefault(endpoint, {"ms": elapsed, "status": kind})
        if elapsed < entry["ms"]:
            entry = {"ms": elapsed, "status": kind}
            first[endpoint] = entry
    return {"first": first, "kinds": kinds, "total": total}


def trend_value(values: dict, key: str) -> float | None:
    for candidate in (key, key.replace("p(50)", "med")):
        if candidate in values:
            return float(values[candidate])
    return None


def scenario_table(out: Path, name: str, title: str) -> list[str]:
    summary_path = out / f"{name}.json"
    if not summary_path.exists():
        return [f"## {title}", "", f"`{summary_path.name}` missing.", ""]
    data = json.loads(summary_path.read_text())
    metrics = data.get("metrics", {})
    errors = parse_errors(out / f"{name}.log")
    meta_path = out / f"{name}.meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else {}

    lines = [
        f"## {title}",
        "",
        f"k6 `{meta.get('k6_image', '?')}`, server `{meta.get('server_image', '?')}`.",
        "",
        "| endpoint | step | requests | req/s | p50 ms | p95 ms | p99 ms | max ms | errors |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    for metric in sorted(metrics):
        endpoint = endpoint_of(metric)
        if endpoint is None:
            continue
        entry = metrics[metric]
        if entry.get("type") != "trend":
            continue
        level = metric.rsplit("_", 1)[1]
        values = entry.get("values", {})
        count_metric = f"{endpoint}_{level}_count"
        count = int(metrics.get(count_metric, {}).get("values", {}).get("count", 0))
        error_count = errors["kinds"].get((endpoint, level), 0)
        p50 = trend_value(values, "p(50)")
        p95 = trend_value(values, "p(95)")
        p99 = trend_value(values, "p(99)")
        lines.append(
            "| {ep} | {lv} | {n} | {rps:.1f} | {p50} | {p95} | {p99} | {mx} | {err} |".format(
                ep=endpoint,
                lv=level,
                n=count,
                rps=count / level_seconds(level),
                p50=f"{p50:.1f}" if p50 is not None else "?",
                p95=f"{p95:.1f}" if p95 is not None else "?",
                p99=f"{p99:.1f}" if p99 is not None else "?",
                mx=f"{float(values.get('max', 0)):.1f}",
                err=error_count,
            )
        )

    lines.append("")
    if errors["first"]:
        lines.append("First error per endpoint (elapsed, status/kind):")
        lines.append("")
        for endpoint, entry in sorted(errors["first"].items()):
            lines.append(
                f"- `{endpoint}` at {entry['ms'] / 1000:.1f}s, "
                f"level {level_of(entry['ms'])}: `{entry['status']}`"
            )
    else:
        lines.append("No request errors were logged in this run.")
    lines.append("")

    resources = out / f"{name}.resources.tsv"
    if resources.exists():
        rows = [row.split("\t") for row in resources.read_text().splitlines() if row]
        connections = []
        active = []
        locks = []
        cpu: dict[str, float] = {}
        for row in rows:
            if len(row) < 2:
                continue
            numbers = row[1].split()
            if len(numbers) >= 3:
                with suppress(ValueError):
                    connections.append(int(numbers[0]))
                    active.append(int(numbers[1]))
                    locks.append(int(numbers[2]))
            if len(row) >= 3:
                for item in row[2].split(","):
                    if "=" not in item:
                        continue
                    key, value = item.split("=", 1)
                    percent = value.split("/", 1)[0].rstrip("%")
                    with suppress(ValueError):
                        cpu[key] = max(cpu.get(key, 0.0), float(percent))
        if connections:
            lines.append(
                "`pg_stat_activity` (database `nodusload`, including this sampler's "
                f"own session): connections max {max(connections)}, active max "
                f"{max(active)}, waiting on a lock max {max(locks)}."
            )
        if cpu:
            lines.append("")
            lines.append(
                "Peak container CPU: "
                + ", ".join(f"`{key}` {value:.0f}%" for key, value in sorted(cpu.items()))
                + "."
            )
    lines.append("")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("out"))
    args = parser.parse_args()

    lines = [
        "<!-- generated by integration/load/report.py; paste into RESULTS.md -->",
        "",
    ]
    for name, title in SCENARIOS:
        lines.extend(scenario_table(args.out, name, title))

    text = "\n".join(lines)
    (args.out / "report.md").write_text(text + "\n")
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
