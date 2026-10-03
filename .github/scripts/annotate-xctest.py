#!/usr/bin/env python3
"""Turn XCTest output into GitHub Actions annotations.

Job logs on this repo are not readable without admin. Annotations are.
"""

import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(errors="replace") if path.exists() else ""
text = re.sub(r"(?m)^\d{4}-\d{2}-\d{2}T[0-9:.]+Z ", "", text)

case_re = re.compile(r"Test Case '-\[(?P<name>[^\]]+)\]' failed")
err_re = re.compile(
    r"(?:^|\s)(?:(?P<file>\S+?\.swift):(?P<line>\d+): )?error: -\[(?P<name>[^\]]+)\] : (?P<msg>.*)$",
    re.M,
)

errors: dict[str, list[str]] = {}
for match in err_re.finditer(text):
    errors.setdefault(match.group("name"), []).append(match.group("msg").strip())

failed: list[str] = []
seen: set[str] = set()
for match in case_re.finditer(text):
    name = match.group("name")
    if name in seen:
        continue
    seen.add(name)
    failed.append(name)
for name in errors:
    if name in seen:
        continue
    seen.add(name)
    failed.append(name)


def esc(value: str) -> str:
    return (
        value.replace("%", "%25")
        .replace("\r", "%0D")
        .replace("\n", "%0A")
        .replace("::", " ")
    )


def emit(message: str) -> None:
    print(f"::error::{esc(message)}")


if failed:
    emit("Failed tests: " + ", ".join(failed))
    print("EVIDENCE_FAILED_TESTS")
    for name in failed:
        msgs = errors.get(name) or ["failed"]
        detail = name + " | " + " || ".join(msgs)
        if len(detail) > 800:
            detail = detail[:800] + "..."
        emit(detail)
        print("EVIDENCE_FAIL " + name)
else:
    compile_hits = [
        line.strip()
        for line in text.splitlines()
        if ": error:" in line or line.startswith("error:")
    ]
    if compile_hits:
        emit("Compile errors: " + " || ".join(compile_hits[:8]))
        print("EVIDENCE_COMPILE_ERRORS")
        for line in compile_hits[:20]:
            print("EVIDENCE_COMPILE " + line)

summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
if summary_path and failed:
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write("## Failed tests\n")
        for name in failed:
            handle.write(f"- `{name}`\n")
            for msg in errors.get(name, []):
                handle.write(f"  - {msg}\n")
