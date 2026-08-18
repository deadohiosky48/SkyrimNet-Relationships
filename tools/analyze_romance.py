#!/usr/bin/env python3
"""
Romance ledger analysis - what actually drove each bond, and how fast.

Answers the balance questions the ledger exists for:
  * How long did it take this NPC to reach Lover, in game days and real hours?
  * Which channel supplied the points - passive adventuring, authored moments,
    or the SeverActions rapport bridge?
  * Which single activities dominated, and is any one of them running away
    with the economy?

Reads SNRom_Bridge's ledger.jsonl (one JSON object per point change; see
README "Logging" for the schema). Optionally enriches from SkyrimNet's own
SQLite DB for playtime correlation.

Usage:
    python analyze_romance.py <ledger.jsonl> [--npc NAME] [--db PATH] [--csv OUT]

Default ledger location:
    <Skyrim>/Data/SKSE/Plugins/SkyrimNet Romantasy/logs/ledger.jsonl
"""

import argparse
import json
import sqlite3
import sys
from collections import defaultdict

TIERS = ["Stranger", "Acquaintance", "Friend", "Confidant", "Lover", "Spouse"]
CHANNELS = {
    "passive": "Adventuring (Romantasy's own ledger)",
    "moment":  "Authored moments (LLM)",
    "sever":   "Conversation (SeverActions rapport)",
    "enroll":  "Enrollment (authored spark)",
    "recruit": "Auto-enrolled on becoming a follower",
    "spark":   "Crossed into romance (background assessment)",
    "talk":    "Conversation (what was actually said)",
    "seed":    "Retroactive seeding (pre-existing history)",
    "end":     "Deliberate ending",
}
# Seeded points were never earned in play. They are excluded from the balance
# diagnostics below, or a save that started married would read as though
# conversation and adventuring were wildly overtuned.
SYNTHETIC = {"seed"}


def _ch(event):
    """Channel name, lowercased.

    The Papyrus compiler mangles the case of some string literals on its way
    into the .pex, unpredictably and with no error: "auto" was written to the
    ledger as "AUTO", "spark" as "Spark", while "moment", "enroll", "recruit"
    and "passive" round-tripped intact. Three attempts to characterise the
    rule were wrong, so this stops trying to predict it. Whatever case the
    game emits, the analysis reads it the same way.
    """
    return str(event.get("ch", "?")).lower()

# Activities firing this often will dominate regardless of authorial intent.
# Kept in sync with the frequency table in the plan.
HIGH_FREQUENCY = {
    "ROM_CriticalStrikes", "ROM_PeopleKilled", "ROM_CreaturesKilled",
    "ROM_ChestsLooted", "ROM_Barters", "ROM_SkillIncreases",
    "ROM_SneakAttacks", "ROM_Backstabs", "ROM_LocksPicked",
    "ROM_ItemsStolen", "ROM_AnimalsKilled",
}


def load(path):
    """Tolerant JSONL read - a torn final line from a hard crash is expected."""
    rows, bad = [], 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                bad += 1
    if bad:
        print(f"  (skipped {bad} unparseable line(s) - likely a crash-torn tail)\n",
              file=sys.stderr)
    return rows


def by_npc(rows):
    out = defaultdict(list)
    for r in rows:
        out[r.get("npc", "?")].append(r)
    for v in out.values():
        v.sort(key=lambda r: r.get("gd", 0.0))
    return out


def fmt_days(d):
    return f"{d:.1f}d" if d < 100 else f"{d:.0f}d"


def tier_timeline(events):
    """First arrival at each tier. Uses 'ta' (tier after) on each row."""
    start = events[0].get("gd", 0.0)
    seen, out = set(), []
    for e in events:
        ta = e.get("ta")
        if ta is None or ta in seen:
            continue
        seen.add(ta)
        out.append((ta, e.get("gd", 0.0) - start, e.get("rt", 0.0)))
    return out


def report_npc(name, events, verbose=False):
    print(f"\n{'=' * 68}\n{name}\n{'=' * 68}")

    gained = sum(e["d"] for e in events if e.get("d", 0) > 0)
    lost = sum(e["d"] for e in events if e.get("d", 0) < 0)
    net = gained + lost
    span = events[-1].get("gd", 0) - events[0].get("gd", 0)
    final_tier = events[-1].get("ta", 0)

    print(f"  Current   : {TIERS[final_tier] if 0 <= final_tier < 6 else '?'} "
          f"({events[-1].get('tot', 0)} pts)")
    print(f"  Tracked   : {fmt_days(span)} of game time, {len(events)} point changes")
    print(f"  Gained    : +{gained}")
    print(f"  Lost      : {lost}")
    print(f"  Net       : {net}")

    if events[0].get("ocr") is not None:
        print(f"  At enroll : OCR ratio {events[0]['ocr']:.2f}, "
              f"ardor {events[0].get('ard', '?')}")

    # ---- Time to each tier ------------------------------------------------
    timeline = tier_timeline(events)
    if len(timeline) > 1:
        print("\n  Time to reach each tier (from first tracked point):")
        for tier, days, _ in timeline:
            if tier == 0:
                continue
            label = TIERS[tier] if 0 <= tier < 6 else f"tier {tier}"
            print(f"    {label:<14} {fmt_days(days):>8}")

    # ---- Where the points came from ---------------------------------------
    print("\n  Contribution by channel:")
    chan = defaultdict(int)
    chan_n = defaultdict(int)
    for e in events:
        chan[_ch(e)] += e.get("d", 0)
        chan_n[_ch(e)] += e.get("n", 1)
    for ch, total in sorted(chan.items(), key=lambda kv: -abs(kv[1])):
        share = (total / net * 100) if net else 0
        print(f"    {CHANNELS.get(ch, ch):<42} {total:>+7}  "
              f"({share:>5.1f}%, {chan_n[ch]} events)")

    # ---- Which activities did the work ------------------------------------
    # 'n' is the occurrence count on coalesced rows (the bridge merges repeated
    # same-activity awards inside a short window to keep write volume sane).
    # Absent means a single occurrence.
    acts = defaultdict(int)
    acts_n = defaultdict(int)
    for e in events:
        a = e.get("act")
        if a:
            acts[a] += e.get("d", 0)
            acts_n[a] += e.get("n", 1)
    if acts:
        print("\n  Top activities:")
        ranked = sorted(acts.items(), key=lambda kv: -abs(kv[1]))
        for a, total in ranked[: (None if verbose else 10)]:
            flag = "  <-- high-frequency" if a in HIGH_FREQUENCY else ""
            print(f"    {a:<34} {total:>+7}  ({acts_n[a]}x){flag}")

        # ---- Balance diagnostics ------------------------------------------
        # Measured against EARNED points only. A save seeded at Spouse would
        # otherwise read as though every other channel were negligible.
        earned = [e for e in events if _ch(e) not in SYNTHETIC]
        gained = sum(e["d"] for e in earned if e.get("d", 0) > 0)
        net = sum(e.get("d", 0) for e in earned)
        chan = defaultdict(int)
        for e in earned:
            chan[_ch(e)] += e.get("d", 0)
        seeded = sum(e.get("d", 0) for e in events if _ch(e) in SYNTHETIC)
        if seeded:
            print(f"\n  ({seeded:+} points were seeded from prior history and "
                  f"are excluded from the notes below)")

        warn = []
        top_act, top_val = ranked[0]
        if net and abs(top_val) / max(abs(net), 1) > 0.5:
            warn.append(
                f"'{top_act}' alone is {abs(top_val) / abs(net) * 100:.0f}% of net "
                f"movement. One activity is carrying this romance.")
        hf = sum(v for a, v in acts.items() if a in HIGH_FREQUENCY and v > 0)
        if gained and hf / gained > 0.6:
            warn.append(
                f"{hf / gained * 100:.0f}% of gains come from high-frequency "
                f"activities. This is the frequency trap - pacing is set by "
                f"grind rate, not by character.")
        # LLM sycophancy check. A judge asked "did this conversation matter?"
        # drifts toward yes-and-positive. Real relationships produce refusals
        # and wounds; a moment channel that never goes negative is flattering
        # the player, not reading the character.
        mom = [e for e in earned if _ch(e) == "moment"]
        if len(mom) >= 8:
            pos = sum(1 for e in mom if e.get("d", 0) > 0)
            neg = sum(1 for e in mom if e.get("d", 0) < 0)
            zero = sum(1 for e in mom if e.get("d", 0) == 0)
            if neg == 0:
                warn.append(
                    f"{len(mom)} authored moments, none negative. The judge is "
                    f"agreeing rather than assessing - check that the prompt "
                    f"permits and encourages wounds.")
            elif pos / max(pos + neg, 1) > 0.85:
                warn.append(
                    f"{pos / (pos + neg) * 100:.0f}% of authored moments are "
                    f"positive. Plausible for a warm arc, suspicious as a "
                    f"steady state.")
            if zero == 0:
                warn.append(
                    "No authored moment scored zero. Most exchanges should "
                    "move nothing; a judge that always finds significance has "
                    "no threshold.")

        if chan.get("passive", 0) and net:
            p = chan["passive"] / net
            if p > 0.9:
                warn.append(
                    "Over 90% of movement is passive adventuring. Authored "
                    "moments are not landing - check MarkMoment eligibility.")
            elif p < 0.15:
                warn.append(
                    "Under 15% of movement is passive. The LLM is driving almost "
                    "everything; consider lowering award.maxPoints.")
        if warn:
            print("\n  ! Balance notes:")
            for w in warn:
                print(f"    - {w}")


def enrich_playtime(db_path):
    """Map game_time -> real playtime seconds from SkyrimNet's events table."""
    try:
        con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
        rows = con.execute(
            "SELECT game_time, playtime FROM events "
            "WHERE playtime IS NOT NULL ORDER BY game_time").fetchall()
        con.close()
        return rows
    except sqlite3.Error as exc:
        print(f"  (could not read SkyrimNet DB: {exc})", file=sys.stderr)
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("ledger", help="path to ledger.jsonl")
    ap.add_argument("--npc", help="report on one NPC only")
    ap.add_argument("--db", help="SkyrimNet-<saveid>.db, for playtime correlation")
    ap.add_argument("--csv", help="also dump the flattened ledger to CSV")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="show all activities, not just the top 10")
    args = ap.parse_args()

    try:
        rows = load(args.ledger)
    except FileNotFoundError:
        sys.exit(f"No ledger at {args.ledger}\n"
                 f"Has SNRom_Bridge run yet, and is log.ledgerEnabled true?")
    if not rows:
        sys.exit("Ledger is empty - no point changes recorded yet.")

    groups = by_npc(rows)
    if args.npc:
        match = {k: v for k, v in groups.items() if args.npc.lower() in k.lower()}
        if not match:
            sys.exit(f"No NPC matching '{args.npc}'. Present: "
                     f"{', '.join(sorted(groups))}")
        groups = match

    print(f"Romance ledger - {len(rows)} point changes across "
          f"{len(groups)} NPC(s)")

    for name, events in sorted(groups.items(),
                               key=lambda kv: -kv[1][-1].get("tot", 0)):
        report_npc(name, events, args.verbose)

    if args.db:
        pt = enrich_playtime(args.db)
        if pt:
            print(f"\n(SkyrimNet DB: {len(pt)} timestamped events available "
                  f"for playtime correlation)")

    if args.csv:
        import csv
        cols = ["t", "gd", "rt", "npc", "fid", "ch", "act", "d", "n",
                "tot", "tb", "ta", "why", "ard", "ocr"]
        with open(args.csv, "w", newline="", encoding="utf-8") as fh:
            w = csv.DictWriter(fh, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            w.writerows(rows)
        print(f"\nWrote {len(rows)} rows to {args.csv}")


if __name__ == "__main__":
    main()
