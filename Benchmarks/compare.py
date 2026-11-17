#!/usr/bin/env python3
"""Compare recorded medians without turning performance drift into a test failure."""

import argparse
import json
import math
from pathlib import Path


def read(path):
    report = json.loads(Path(path).read_text(encoding="utf-8"))
    if report["schemaVersion"] != 1:
        raise ValueError(f"Unsupported schema: {path}")
    results = {}
    for result in report["results"]:
        value = result["medianMS"]
        if not math.isfinite(value) or value < 0 or result["id"] in results:
            raise ValueError(f"Invalid result: {path}: {result['id']}")
        results[result["id"]] = value
    return report, results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("base")
    parser.add_argument("new")
    parser.add_argument("--threshold", type=float, default=20)
    args = parser.parse_args()
    if not math.isfinite(args.threshold) or args.threshold < 0:
        parser.error("threshold must be a finite nonnegative percentage")
    base_report, base = read(args.base)
    new_report, new = read(args.new)
    for key in ("model", "cpuCount", "macOS", "xcode", "configuration", "runs"):
        if base_report.get(key) != new_report.get(key):
            print(f"環境差 {key}: {base_report.get(key)} -> {new_report.get(key)}")
    print(f"基準: {args.base}\n比較: {args.new}\n印: +{args.threshold:g}% を超える遅延（合否には使いません）")
    print("場面 | BASE ms | NEW ms | 差 % | 印")
    for name in sorted(base.keys() | new.keys()):
        if name not in base or name not in new:
            print(f"{name} | {'追加' if name not in base else '欠落'}")
            continue
        old, latest = base[name], new[name]
        delta = (latest / old - 1) * 100 if old else (math.inf if latest else 0)
        print(f"{name} | {old:.2f} | {latest:.2f} | {delta:+.2f}% | {'*' if delta > args.threshold else ''}")


if __name__ == "__main__":
    main()
