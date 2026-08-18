#!/usr/bin/env python3
"""
Attraction model - calibration for the Romantasy romance gate.

Design intent:
    Physical and social appeal are SEPARATE axes. 5/5, 5/1, 1/5 and 3/3 are
    four different people, not four points on one line. 25 archetypes, not 5.

OCR (OStim Community Resource) collects both on a 1-5 scale but then stores
only their SUM in OCR_AttractivenessBase, discarding the distinction - and
6 of the 19 distinct sums are ambiguous (34 is either 5/1 or 3/4). So the
axes have to be captured by us, not recovered from OCR.

This models three independent axes weighted per NPC:
    physical  how they look
    social    charm, warmth, ease with people
    renown    fame, accomplishment, standing

Compared against her own bar, derived from OCR's social-class thresholds.

Usage:
    python attraction_curve.py                  # 5x5 grid per NPC profile
    python attraction_curve.py --ocr-compare    # show why OCR's own sum fails
    python attraction_curve.py --floor 0.6
"""

import argparse

# Questionnaire scales, parsed from OStimCommunityResource.esp MESG records.
PHYSICAL = {1: 6, 2: 12, 3: 18, 4: 24, 5: 30}
SOCIAL = {1: 4, 2: 8, 3: 12, 4: 16, 5: 20}

# GetAttractivenessThreshold(), settled values. (female, male)
# NOTE OCR disagrees with itself between the assign-on-first-contact branch
# and the IsInFaction branch: CitizenLowest 20/10 then 25/15, CitizenLow
# 50/20 then 50/24. An NPC's bar changes between her first and second
# evaluation, so cache the ratio at enrollment rather than recomputing.
THRESHOLDS = {
    "CitizenNoble":   (80, 60),
    "Other":          (70, 50),
    "SoldierOrGuard": (60, 40),
    "CitizenMiddle":  (60, 40),
    "CitizenLow":     (50, 24),
    "CitizenLowest":  (25, 15),
}

RENOWN_MAX = 130       # race+skill (~65) + fame 10 + leader 15 + main quest 30
BAR_LO, BAR_HI = 0.25, 0.75   # compresses OCR's 15-80 spread (5.3x -> 3x)

# How each NPC weights the three axes. Authored per NPC by the disposition
# pass, alongside her activity preferences. Must sum to 1.0.
PROFILES = [
    ("farm girl - looks and warmth",   0.45, 0.45, 0.10),
    ("vain noble - status above all",  0.25, 0.15, 0.60),
    ("shield-sister - deeds, not face", 0.10, 0.35, 0.55),
    ("bard - charm above all",         0.20, 0.65, 0.15),
    ("balanced",                       0.34, 0.33, 0.33),
]


def norm_physical(p):
    return (PHYSICAL[p] - 6) / 24.0


def norm_social(s):
    return (SOCIAL[s] - 4) / 16.0


def race_bonus(skill):
    """OCR: major/4 + sum(5 minors)/20. With even skills this is skill/2."""
    return skill / 4 + (skill * 5) / 20


def norm_renown(skill, fame, leader, main_quest):
    raw = race_bonus(skill) + fame + leader + (30 if main_quest else 0)
    return min(1.0, raw / RENOWN_MAX)


def bar(threshold):
    return BAR_LO + (BAR_HI - BAR_LO) * (threshold - 15) / (80 - 15)


def band(r, floor):
    if r < floor:
        return "shut out"
    if r < 1.0:
        return "uphill"
    if r < 1.5:
        return "open"
    if r < 2.2:
        return "drawn"
    return "fawning"


def ocr_compare():
    from collections import defaultdict
    m = defaultdict(list)
    for p in range(1, 6):
        for s in range(1, 6):
            m[PHYSICAL[p] + SOCIAL[s]].append((p, s))
    print("Why OCR's stored value is not enough\n" + "=" * 60)
    print(f"25 combinations collapse to {len(m)} distinct sums; "
          f"{sum(1 for v in m.values() if len(v) == 1)} are uniquely recoverable.\n")
    print("Ambiguous - indistinguishable from OCR_AttractivenessBase alone:")
    for k in sorted(k for k, v in m.items() if len(v) > 1):
        print(f"  {k}: " + " or ".join(f"{p}/{s}" for p, s in m[k]))
    print("\nSo the two answers must be captured by us, not inferred.\n")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--floor", type=float, default=0.6)
    ap.add_argument("--ocr-compare", action="store_true")
    ap.add_argument("--skill", type=int, default=90,
                    help="player average skill (default 90, endgame)")
    ap.add_argument("--fame", type=int, default=10)
    ap.add_argument("--leader", type=int, default=15)
    ap.add_argument("--no-main-quest", action="store_true")
    ap.add_argument("--against", default="CitizenMiddle",
                    help="NPC social class (default CitizenMiddle)")
    ap.add_argument("--male", action="store_true",
                    help="NPC is male (lower bar in OCR)")
    args = ap.parse_args()

    if args.ocr_compare:
        ocr_compare()

    renown = norm_renown(args.skill, args.fame, args.leader,
                         not args.no_main_quest)
    thr = THRESHOLDS[args.against][1 if args.male else 0]
    b = bar(thr)

    print(f"Player renown {renown:.2f}  (skill {args.skill}, fame {args.fame}, "
          f"leader {args.leader}, MQ {not args.no_main_quest})")
    print(f"NPC: {args.against} {'male' if args.male else 'female'}, "
          f"OCR bar {thr} -> normalised {b:.2f}   floor {args.floor}\n")

    for name, wp, ws, wr in PROFILES:
        print(f"{'=' * 66}\n{name}   (physical {wp} / social {ws} / renown {wr})")
        print(f"{'=' * 66}")
        print("        " + "".join(f"  social {s}  " for s in range(1, 6)))
        for p in range(5, 0, -1):
            row = f"  phys {p} "
            for s in range(1, 6):
                score = wp * norm_physical(p) + ws * norm_social(s) + wr * renown
                r = score / b
                row += f"{r:>5.2f} {band(r, args.floor):<6}"
            print(row)
        print()

    print("Read down a column to vary looks at fixed charm; across a row for")
    print("the reverse. A profile that produces the same band everywhere is")
    print("badly weighted - the axes should visibly disagree.")


if __name__ == "__main__":
    main()
