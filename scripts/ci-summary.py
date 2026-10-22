#!/usr/bin/env python3
"""Turn an ansible-playbook log into the Markdown for the run's summary page.

    scripts/ci-summary.py site|platform check|apply <log> <exit status>

Called by scripts/ci-playbook.sh in CI. For each box and task that changed (or
would), it lists the loop items, for example the addresses a firewall rule
was added for, and puts any --diff output in a collapsed block. Tasks with
no_log print neither, so nothing here is not already in the job's log.
"""
import re
import sys
from collections import OrderedDict

MAX_ITEM = 120  # characters of one loop item
MAX_DIFF = 200  # lines of diff per box and task

playbook, mode, log, status = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
check = mode == "check"

ansi = re.compile(r"\x1b\[[0-9;]*m")
result = re.compile(r"(ok|changed|skipping|fatal|failed): \[([^\]]+)\](?: => \(item=(.*)\)\s*$)?")

task, diff, in_diff, in_recap = "", [], False, False
changes = OrderedDict()  # (box, task) -> {"count", "items", "diff"}
failures, recap = [], []

for raw in open(log, errors="replace"):
    line = ansi.sub("", raw.rstrip("\n"))
    if m := re.match(r"TASK \[(.*)\]", line):
        task, diff, in_diff = m.group(1), [], False
    elif line.startswith("PLAY RECAP"):
        in_recap, in_diff = True, False
    elif in_recap:
        if line.strip():
            recap.append(line)
        else:
            in_recap = False
    elif m := result.match(line):
        state, box, item = m.group(1), m.group(2).split(" -> ")[0], m.group(3)
        if state == "changed":
            entry = changes.setdefault((box, task), {"count": 0, "items": [], "diff": []})
            entry["count"] += 1
            if item and item != "None":
                entry["items"].append(item)
            entry["diff"] += diff
        elif state in ("fatal", "failed"):
            failures.append(f"{box}: {task}")
        diff, in_diff = [], False
    elif line.startswith("--- before"):
        in_diff = True
        diff.append(line)
    elif in_diff:
        diff.append(line)


def cell(text):
    text = text if len(text) <= MAX_ITEM else text[: MAX_ITEM - 1] + "…"
    return "`" + text.replace("`", "'").replace("|", "\\|") + "`"


if check:
    print(f"### {playbook}.yml dry run (`--check --diff`)\n")
else:
    print(f"### {playbook}.yml apply\n")

if failures:
    print("**Failed:** " + "; ".join(failures) + "\n")
elif status != 0:
    print(f"**ansible-playbook exited with {status}**; see this job's log.\n")

if changes:
    if check:
        print("Would change on the boxes. Approve the apply only if this is what you expect:\n")
    else:
        print("Changed on the boxes:\n")
    print("| Box | Task | What |\n|---|---|---|")
    for (box, name), entry in changes.items():
        if entry["items"]:
            what = "<br>".join(cell(i) for i in entry["items"])
        elif entry["diff"]:
            what = "See the diff below"
        else:
            what = "1 change" if entry["count"] == 1 else f"{entry['count']} changes"
        name = name.replace("|", "\\|")
        print(f"| {box} | {name} | {what} |")
    print()
    for (box, name), entry in changes.items():
        if not entry["diff"]:
            continue
        lines = entry["diff"]
        while lines and not lines[-1].strip():
            lines = lines[:-1]
        more = len(lines) - MAX_DIFF
        body = "\n".join(lines[:MAX_DIFF]).replace("```", "'''")
        print(f"<details><summary>Diff: {box}, {name}</summary>\n\n```diff\n{body}\n```\n")
        if more > 0:
            print(f"{more} more lines in this job's log.\n")
        print("</details>\n")
elif status == 0:
    if check:
        print("Nothing would change on the boxes, so on a merge the apply is skipped.\n")
    else:
        print("Nothing changed on the boxes.\n")

if recap:
    print("<details><summary>PLAY RECAP</summary>\n\n```\n" + "\n".join(recap) + "\n```\n</details>\n")
print("Full output: this job's log.")
