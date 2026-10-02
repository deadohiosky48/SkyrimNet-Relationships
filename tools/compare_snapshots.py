"""Compare two dashboard snapshots bond by bond.

The WP4 import check (design 8.4): every bond's points after the one-time
import must equal what the dashboard showed before it. Save
SkyrimNetRelationships.snapshot.json (written beside the DLL's log on every
refresh) before installing the new build, open the dashboard again after the
import's notification, and compare:

    py -3 tools/compare_snapshots.py BEFORE.json AFTER.json

Exit code 0 when every bond in BEFORE has the same points and tier in AFTER,
1 otherwise. Bonds that exist on only one side are listed, not failed: the
roster can change between the two opens.
"""

import json
import sys


def bonds(path):
    with open(path, encoding="utf-8") as f:
        snap = json.load(f)
    return {b["subject"]["formId"]: b for b in snap.get("bonds", [])}, snap


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    before, snap_before = bonds(argv[1])
    after, snap_after = bonds(argv[2])
    print(f"before: {len(before)} bonds at game day {snap_before.get('generatedAt')}")
    print(f"after:  {len(after)} bonds at game day {snap_after.get('generatedAt')}")

    mismatched = []
    for form_id, b in sorted(before.items(), key=lambda kv: kv[1]["subject"].get("name", "")):
        a = after.get(form_id)
        if a is None:
            continue
        was, now = b["depth"], a["depth"]
        if was.get("points") != now.get("points") or was.get("tier") != now.get("tier"):
            mismatched.append((b["subject"].get("name", hex(form_id)), was, now))

    only_before = [before[k]["subject"].get("name") for k in before.keys() - after.keys()]
    only_after = [after[k]["subject"].get("name") for k in after.keys() - before.keys()]
    compared = len(before.keys() & after.keys())

    print(f"compared {compared} bonds; {len(mismatched)} differ")
    for name, was, now in mismatched:
        print(f"  DIFFERS  {name}: {was.get('points')} pts tier {was.get('tier')} -> "
              f"{now.get('points')} pts tier {now.get('tier')}")
    if only_before:
        print(f"  only before ({len(only_before)}): {', '.join(sorted(only_before))}")
    if only_after:
        print(f"  only after ({len(only_after)}): {', '.join(sorted(only_after))}")
    return 1 if mismatched else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
