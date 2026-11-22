"""Feed damaged and extreme documents to every reader and keep the inputs that crash or hang one.

The readers run in a child process (the ReaderFuzzChild test, started with `swift test --skip-build`). When the
child dies, the input it wrote before reading tells which input ended it; the driver saves that input under
build/robustness/failures/<format>/ and starts a new child after it. Cases are numbered: first the hand-written
edge cases, then the committed regressions, then seeded mutations, so (format, seed, index) names one input.
"""

import argparse
import hashlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

FORMATS = [
    "markdown", "org", "plainText", "html", "pdf", "image", "csv", "zipArchive", "latex", "asciidoc", "quarto",
    "rmarkdown", "djot", "textile", "mediawiki", "rst", "docx", "notebook", "graphviz", "plantuml",
]


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def run_shard(args, work, fmt, start, budget, count=None, replay=None):
    for name in ("case.json", "finding.json", "progress.json", "done.json", "setup-failure.json"):
        (work / name).unlink(missing_ok=True)
    env = dict(os.environ)
    env.update(
        SURIMONO_ROBUSTNESS_CHILD="1", SURIMONO_ROBUSTNESS_DIR=str(work), SURIMONO_ROBUSTNESS_FORMAT=fmt,
        SURIMONO_ROBUSTNESS_SEED=str(args.seed), SURIMONO_ROBUSTNESS_START=str(start),
        SURIMONO_ROBUSTNESS_BUDGET=str(budget), SURIMONO_ROBUSTNESS_LONG="0" if args.short else "1",
        SURIMONO_ROBUSTNESS_MEMORY_MB=str(args.memory_mb), SURIMONO_ROBUSTNESS_REPLAY=replay or "",
        SURIMONO_ROBUSTNESS_FIXED_ONLY="1" if args.fixed_only else "0",
    )
    if count is not None:
        env["SURIMONO_ROBUSTNESS_COUNT"] = str(count)
    command = args.swift_test + ["--skip-build", "--filter", "ReaderFuzzChild"]
    child = subprocess.Popen(
        command, env=env, start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors="replace",
    )
    killed = False
    try:
        # A child normally stops itself after its budget; this only catches a process that no longer runs Swift code.
        output, _ = child.communicate(timeout=budget + args.grace)
    except subprocess.TimeoutExpired:
        killed = True
        os.killpg(child.pid, signal.SIGKILL)
        output, _ = child.communicate()
    return child.returncode, killed, output


def save_failure(args, work, fmt, kind, returncode, output):
    case = read_json(work / "case.json") or {}
    inputs = [path for path in (work / "current").glob("self.*")]
    data = inputs[0].read_bytes() if inputs else b""
    digest = hashlib.sha256(data).hexdigest()[:16]
    folder = Path(args.out) / "failures" / fmt
    folder.mkdir(parents=True, exist_ok=True)
    suffix = case.get("fileExtension") or "bin"
    target = folder / f"{digest}.{suffix}"
    target.write_bytes(data)
    finding = read_json(work / "finding.json") or {}
    record = dict(
        kind=kind, returncode=returncode, case=case, finding=finding, input=str(target),
        replay=f"make robustness FORMAT={fmt} REPLAY={target}",
        reproduce=f"make robustness FORMAT={fmt} SEED={case.get('seed')} START={case.get('index')} COUNT=1",
        output="\n".join(output.splitlines()[-80:]),
    )
    # `.report.json`: an input that is itself JSON (a notebook read as JSON, say) keeps its own name.
    (folder / f"{digest}.report.json").write_text(json.dumps(record, indent=2, ensure_ascii=False))
    return record


def classify(returncode, killed, work):
    # swift test reports the child's own exit status only as a failure, so the watchdog's note decides.
    if (work / "setup-failure.json").exists():
        return "setup-failure"
    finding = read_json(work / "finding.json")
    if finding:
        return finding.get("kind", "hang")
    if killed:
        return "timeout"
    if (work / "done.json").exists() and returncode == 0:
        return None
    if (work / "done.json").exists():
        return "test-failure"
    return "crash"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seconds", type=float, default=600, help="total time across formats")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--format", default="", help="one format (DocumentFormat raw value); default all")
    parser.add_argument("--shard-seconds", type=float, default=45, help="time one child reads before it stops")
    parser.add_argument("--grace", type=float, default=120, help="extra time before a silent child is killed")
    parser.add_argument("--memory-mb", type=int, default=4096, help="peak resident memory a child may reach")
    parser.add_argument("--start", type=int, default=0, help="first case index")
    parser.add_argument("--count", type=int, default=None, help="cases to run (with one format)")
    parser.add_argument("--replay", default="", help="read only this file (with --format)")
    parser.add_argument("--short", action="store_true", help="leave out the long hand-written cases")
    parser.add_argument("--fixed-only", action="store_true",
                        help="only the hand-written cases and regressions, once per format")
    parser.add_argument("--out", default="build/robustness")
    parser.add_argument("swift_test", nargs=argparse.REMAINDER, help="-- swift test --package-path ...")
    args = parser.parse_args()
    if args.swift_test[:1] == ["--"]:
        args.swift_test = args.swift_test[1:]
    if not args.swift_test or not 0 <= args.seed < 2**64:
        parser.error("expected a UInt64 seed and a swift test command after --")
    formats = [args.format] if args.format else FORMATS
    if any(fmt not in FORMATS for fmt in formats):
        parser.error(f"unknown format; choose from {', '.join(FORMATS)}")

    # A replay input is read once, before anything is created or removed: it may sit in an earlier run's work folder.
    replay_bytes = None
    if args.replay:
        if len(formats) != 1:
            parser.error("--replay needs --format")
        try:
            replay_bytes = Path(args.replay).read_bytes()
        except OSError as error:
            # An input that cannot be read is a mistake in the command, not a clean read of an empty file.
            print(f"replay {args.replay}: cannot read it ({error.strerror})", file=sys.stderr)
            return 2

    out = Path(args.out).resolve()
    args.out = str(out)
    out.mkdir(parents=True, exist_ok=True)
    # A work folder of its own for each run, so that no run removes another's inputs.
    work = Path(tempfile.mkdtemp(prefix="work-", dir=out))
    (work / "current").mkdir(parents=True)
    try:
        return run(args, formats, work, out, replay_bytes)
    finally:
        # Inputs that took over a second, kept beside the summaries.
        if (work / "slow.jsonl").exists():
            shutil.copy(work / "slow.jsonl", out / f"slow-{time.strftime('%Y%m%d-%H%M%S')}.jsonl")
        shutil.rmtree(work, ignore_errors=True)


def run(args, formats, work, out, replay_bytes):
    if replay_bytes is not None:
        suffix = Path(args.replay).suffix
        copy = work / f"replay{suffix}"
        copy.write_bytes(replay_bytes)
        returncode, killed, output = run_shard(args, work, formats[0], 0, 600, count=1, replay=str(copy))
        kind = classify(returncode, killed, work)
        if kind == "setup-failure":
            print(f"replay {args.replay}: the child could not read its copy", file=sys.stderr)
            return 2
        print(f"replay {args.replay}: {kind or 'read without failure'}")
        if kind:
            print("\n".join(output.splitlines()[-40:]))
        return 1 if kind else 0

    state = {fmt: dict(next=args.start, ran=0, read=0, findings=[], shards=0, seconds=0.0, done=False)
             for fmt in formats}
    began = time.monotonic()
    turn = 0
    while time.monotonic() - began < args.seconds:
        pending = [fmt for fmt in formats if not state[fmt]["done"]]
        if not pending:
            break
        fmt = pending[turn % len(pending)]
        turn += 1
        entry = state[fmt]
        remaining = args.seconds - (time.monotonic() - began)
        budget = max(5, min(args.shard_seconds, remaining))
        shard_start = time.monotonic()
        returncode, killed, output = run_shard(args, work, fmt, entry["next"], budget, count=args.count)
        entry["seconds"] += time.monotonic() - shard_start
        entry["shards"] += 1
        kind = classify(returncode, killed, work)
        progress = read_json(work / "done.json") or read_json(work / "progress.json")
        if progress:
            entry["read"] += progress.get("read", 0)
        if kind is None:
            entry["ran"] += progress["ran"]
            entry["next"] = progress["next"]
            # A fixed-only child that read nothing has reached the mutations.
            if args.fixed_only and progress["ran"] == 0:
                entry["done"] = True
        elif kind in ("test-failure", "setup-failure"):
            print("\n".join(output.splitlines()[-60:]), file=sys.stderr)
            raise SystemExit(f"{fmt}: the child failed without a crash (see output above)")
        else:
            case = read_json(work / "case.json") or {}
            index = case.get("index", entry["next"])
            entry["ran"] += index - entry["next"] + 1
            entry["next"] = index + 1
            record = save_failure(args, work, fmt, kind, returncode, output)
            entry["findings"].append(record)
            print(f"FINDING {fmt} {kind} index={index} name={case.get('name')} size={case.get('size')} -> {record['input']}",
                  flush=True)
        print(f"{fmt}: cases={entry['ran']} read={entry['read']} next={entry['next']} findings={len(entry['findings'])} "
              f"elapsed={time.monotonic() - began:.0f}s", flush=True)
        if args.count is not None and entry["ran"] >= args.count:
            break

    summary = dict(
        seed=args.seed, seconds=round(time.monotonic() - began, 1), long_cases=not args.short,
        formats={fmt: dict(cases=e["ran"], read=e["read"], next_index=e["next"], shards=e["shards"], seconds=round(e["seconds"], 1),
                           findings=[dict(kind=f["kind"], name=f["case"].get("name"), index=f["case"].get("index"),
                                          input=f["input"]) for f in e["findings"]])
                 for fmt, e in state.items()},
    )
    stamp = time.strftime("%Y%m%d-%H%M%S")
    (out / f"summary-{stamp}.json").write_text(json.dumps(summary, indent=2))
    print(f"summary: {out / f'summary-{stamp}.json'}")
    for fmt, e in state.items():
        print(f"  {fmt:11} cases={e['ran']:6} read={e['read']:6} findings={len(e['findings'])}")
    return 1 if any(e["findings"] for e in state.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
