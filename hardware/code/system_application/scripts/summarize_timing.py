"""Summarize every PDS timing corner; incomplete reports never pass.

Unlike the build's first-clock WNS field, this includes all clock rows and
setup, hold, recovery, removal and minimum pulse width in both corners.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


def summarize(path):
    path = Path(path)
    raw = path.read_bytes()
    text = raw.decode("utf-8", errors="replace")
    tables = []
    pattern = (r"^(Setup|Hold|Recovery|Removal|Minimum Pulse Width) "
               r"Summary\((Slow|Fast) Corner\):[^\n]*\n(.*?)(?=^=+)")
    for match in re.finditer(pattern, text, re.MULTILINE | re.DOTALL):
        rows = []
        for line in match[3].splitlines():
            cells = line.split()
            if len(cells) not in (5, 6):
                continue
            try:
                slack, total = float(cells[-4]), float(cells[-3])
                failing, endpoints = int(cells[-2]), int(cells[-1])
            except ValueError:
                continue
            rows.append(dict(clocks=cells[:-4], slack_ns=slack,
                             total_negative_slack_ns=total,
                             failing_endpoints=failing, endpoints=endpoints))
        tables.append(dict(check=match[1], corner=match[2], rows=rows))
    required = {(check, corner) for check in
                ("Setup", "Hold", "Recovery", "Removal", "Minimum Pulse Width")
                for corner in ("Slow", "Fast")}
    found = {(t["check"], t["corner"]) for t in tables if t["rows"]}
    complete = found == required and len(tables) == 10
    violations = [dict(check=t["check"], corner=t["corner"], **r)
                  for t in tables for r in t["rows"]
                  if r["slack_ns"] < 0 or r["failing_endpoints"] > 0]
    overall = re.search(r"Design Summary\s*:\s*([^\r\n]+)", text)
    verdict = overall[1].strip() if overall else "MISSING"
    return dict(report=str(path), sha256=hashlib.sha256(raw).hexdigest(),
                tool_verdict=verdict, complete=complete,
                meets_constraints=complete and not violations and
                verdict.rstrip(".") == "All Constraints Met",
                violations=violations, tables=tables)


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args()
    result = summarize(args.report)
    rendered = json.dumps(result, indent=2) + "\n"
    if args.json:
        args.json.write_text(rendered, encoding="utf-8")
    print(json.dumps({k: v for k, v in result.items() if k != "tables"}, indent=2))
    return 0 if result["meets_constraints"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
