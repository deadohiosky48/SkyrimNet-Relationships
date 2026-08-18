# Relationships

### A SkyrimNet-Romantasy Integration Mod

Every companion forms their own opinion of you — and it changes.

---

## What this is

[Romantasy](https://www.nexusmods.com/skyrimspecialedition/mods/186060) is a
scoreboard. It converts 58 vanilla statistics into a six-tier bond and climbs a
ladder toward romance. It ships no dialogue and no personality, because that was
never its job.

**Relationships takes that framework and extends it across the whole spectrum of
human connection.** Romance is one of the ways a bond can go, not the only one
and not the destination. A shield-sister who will never be a lover and would die
for you is a first-class outcome here, tracked with the same care as a marriage.
Two people who become inseparable without ever being in love is a story this mod
is built to tell.

The difference in one line:

> **Romantasy scores what you did. Relationships is about who each person becomes
> to you.**

Where Romantasy asks *how far up the ladder are we*, this asks *what kind of
person is this, what do they want, what will they refuse, and has any of that
changed*.

## The principle everything follows from

**Describe objectively, let each NPC judge.**

There is no central "how good is the player" score — not for deeds, not for
looks. Every NPC receives the same objective facts and their own disposition
decides what those facts mean. The same act earns warmth from one companion,
nothing from another, and contempt from a third, because they are different
people rather than the same person at different tiers.

That is why there are no archetypes. Each companion's character is written from
their own bio by an LLM, once, and is theirs.

## What it does

**Enrolls automatically.** Anyone who becomes a follower starts being observed at
Stranger with zero points. Enrollment means "this person is being watched", not
"something has started".

**Writes a character for each of them.** From their actual bio: what they are
drawn to, what closeness requires of them, how much of what they feel they show,
how singular they need a bond to be, one line explaining why, and one line they
will not cross whatever they feel. Plus a set of likes and dislikes drawn from
Romantasy's own activity list, so the same deed routes through their opinions
rather than a global table.

**Two tracks, not one ladder.** Bond depth is earned by shared experience and is
open to everyone. The romantic track is separate and gated: without a moment
where something actually crossed, a companion stays platonic forever however deep
the bond runs. Travelling together for a year does not make someone fall in love.

**Scores conversation.** Talking matters. A background judge reads what actually
passed between you and decides whether it moved anything — usually it did not.
Pacing lives in code, not in the prompt: daily caps, cooldowns, and a rarity
limit on the moments where two people redefine what they are.

**Asks before it assumes.** When someone reaches the point of wanting more, they
raise it themselves, in their own words, and you answer plainly. Declining is a
real answer with real cost, and it does not end the friendship.

**Lets people change.** Dispositions are reviewed as companions live, and can
move in either direction — but only on a pattern of behaviour across days, never
on one memorable evening, and only one step at a time. Someone who swore off
commitment can come to want it. Someone badly treated can close up.

## Requirements

| | |
|---|---|
| [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/151960) | required |
| [Romantasy](https://www.nexusmods.com/skyrimspecialedition/mods/186060) | required |
| SKSE64 | required |
| PapyrusUtil SE | required — StorageUtil, JsonUtil, MiscUtil |
| Papyrus MessageBox ([Nexus 83578](https://www.nexusmods.com/skyrimspecialedition/mods/83578)) | required for the consent prompt; bundled by MARAS |
| An LLM backend SkyrimNet can reach | required — local or hosted |

### Optional, and genuinely optional

Each of these is detected at runtime. Absent, the feature it powers is simply
inert; nothing errors and no prompt breaks.

| | adds |
|---|---|
| SeverActions | follower detection and rapport-based head starts for companions you already know |
| OStim Community Resource | physical attraction as an input, for characters whose disposition allows it to matter |
| MARAS | marriage and engagement are read as facts rather than judged |
| [SkyrimNet-Kinship](https://github.com/deadohiosky48/SkyrimNet-Kinship) | your own children are barred from the romantic and sexual ladders |

## Installation

Install with a mod manager, or copy the contents over your `Data` folder.
`SNRom_Integration.esl` is ESL-flagged and does not consume a load-order slot.

Settings appear in SkyrimNet's plugin panel under **SkyrimNet Romantasy**.

## Configuration

Everything is tunable from SkyrimNet's settings page. The defaults are calibrated
so that an authored emotional beat is worth roughly what clearing a dungeon is
worth, and so that nothing moves quickly.

Notable knobs: how much conversation can move a bond in a day, how long between
moments where a relationship is allowed to be redefined, how long two people must
travel together before romance can begin at all, whether personalities are
allowed to change over time and how much must have happened first.

## Status

**In development, not yet released.** The four subsystems — enrollment,
authoring, conversational scoring, and the romantic gate — are built and
confirmed working in live play across dozens of companions. Disposition drift and
the consent prompt are newer and have fewer hours on them.

Known gaps, honestly:

- **Preferences are append-only.** Romantasy restores its own copy on load, so a
  companion's likes and dislikes can be added to but never removed. A re-author
  therefore only ever adds.
- **Enrollment is not live until the next game load.** Romantasy reads its
  follower configuration once at load, so a companion recruited mid-session is
  observed but does not score until you reload. A fix is expected from Romantasy.
- **There is no in-game repair tool yet.** If an authored character reads wrong,
  correcting it currently requires the SkyrimNet web API.

## Credits

Built on [Romantasy](https://www.nexusmods.com/skyrimspecialedition/mods/186060)
by ColdSun and [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/151960)
by MinLL. Neither is vendored here; both are required separately.
