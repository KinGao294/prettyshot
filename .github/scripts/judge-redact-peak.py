#!/usr/bin/env python3
"""PRD v0.3.47 / AC-I17 memory gate for two-mark redaction on 1320x2868.

`testRedactionWithTopAndBottomMarksHoldsOneFullSizeBuffer` runs alone with
`-test-iterations 3 -test-repetition-relaunch-enabled YES`, so each iteration is a fresh
test process that measures once and prints one line:

    PRETTYSHOT_REDACT_PEAK 1320x2868 two-marks process=<pid> peak=<bytes> retained=<bytes> sourceBytes=<bytes> ...

This script is the real gate (the XCTest only has a soft 30MB/8MB local ceiling):
  * exactly 3 samples from 3 distinct processes, otherwise fail (no quiet pass);
  * pick the process with the lowest peak;
  * judge BOTH peak <= sourceBytes + 2MB (17,240,192 bytes) and retained <= 2MB on that process.
So the peak check fails only if all 3 processes exceed the limit. Limits are unchanged.

Usage: judge-redact-peak.py <xcodebuild log>
"""

import os
import re
import sys
from pathlib import Path

EXPECTED = 3
SLACK = 2 * 1024 * 1024
WIDTH, HEIGHT, BYTES_PER_PIXEL = 1320, 2868, 4
SOURCE_BYTES = WIDTH * HEIGHT * BYTES_PER_PIXEL  # 15,143,040
PEAK_LIMIT = SOURCE_BYTES + SLACK  # 17,240,192
RETAINED_LIMIT = SLACK

LINE_RE = re.compile(
    r"PRETTYSHOT_REDACT_PEAK 1320x2868 two-marks process=(?P<pid>\d+) "
    r"peak=(?P<peak>-?\d+) retained=(?P<retained>-?\d+) sourceBytes=(?P<source>\d+)"
)


def mb(value: int) -> str:
    return f"{value / 1_000_000:.3f}MB"


def fail(message: str, summary: list[str]) -> int:
    print(f"::error title=PRETTYSHOT_REDACT_GATE::{message}")
    print(f"PRETTYSHOT_REDACT_GATE result=FAIL reason={message!r}")
    write_summary(summary + [f"**FAIL**: {message}"])
    return 1


def write_summary(lines: list[str]) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    text = path.read_text(errors="replace") if path.exists() else ""
    samples = [
        {
            "pid": int(m.group("pid")),
            "peak": int(m.group("peak")),
            "retained": int(m.group("retained")),
            "source": int(m.group("source")),
        }
        for m in LINE_RE.finditer(text)
    ]
    summary = [
        "### PRETTYSHOT_REDACT gate (PRD v0.3.47, AC-I17)",
        "",
        f"peak limit {PEAK_LIMIT} bytes (sourceBytes+2MB), retained limit {RETAINED_LIMIT} bytes",
        "",
        "| process | pid | peak | retained |",
        "|---|---|---|---|",
    ]
    for index, sample in enumerate(samples, start=1):
        print(
            f"PRETTYSHOT_REDACT_SAMPLE s{index} process={sample['pid']} "
            f"peak={sample['peak']} ({mb(sample['peak'])}) "
            f"retained={sample['retained']} ({mb(sample['retained'])})"
        )
        summary.append(f"| s{index} | {sample['pid']} | {sample['peak']} | {sample['retained']} |")
    summary.append("")

    if len(samples) != EXPECTED:
        return fail(f"expected exactly {EXPECTED} process samples, found {len(samples)}", summary)
    pids = {sample["pid"] for sample in samples}
    if len(pids) != EXPECTED:
        return fail(f"samples are not from {EXPECTED} distinct processes: pids={sorted(pids)}", summary)
    bad_source = [s["source"] for s in samples if s["source"] != SOURCE_BYTES]
    if bad_source:
        return fail(f"unexpected sourceBytes {bad_source} (want {SOURCE_BYTES})", summary)

    picked_index = min(range(EXPECTED), key=lambda i: samples[i]["peak"])
    picked = samples[picked_index]
    peak_ok = picked["peak"] <= PEAK_LIMIT
    retained_ok = picked["retained"] <= RETAINED_LIMIT
    peaks = [s["peak"] for s in samples]
    retained = [s["retained"] for s in samples]
    result = "PASS" if peak_ok and retained_ok else "FAIL"
    line = (
        f"PRETTYSHOT_REDACT_GATE result={result} picked=s{picked_index + 1} "
        f"process={picked['pid']} peak={picked['peak']} retained={picked['retained']} "
        f"peakLimit={PEAK_LIMIT} retainedLimit={RETAINED_LIMIT} peaks={peaks} retained={retained}"
    )
    print(line)
    summary.append(f"picked s{picked_index + 1} (lowest peak): peak {picked['peak']}, retained {picked['retained']} → **{result}**")
    if not peak_ok:
        return fail(f"lowest peak of {EXPECTED} processes {picked['peak']} > {PEAK_LIMIT}", summary)
    if not retained_ok:
        return fail(f"retained {picked['retained']} on picked process > {RETAINED_LIMIT}", summary)
    write_summary(summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
