# Relationships

### A SkyrimNet-Romantasy Integration Mod

Every companion forms their own opinion of you — and it changes.

---

> ### ⚠ Beta — read this before installing
>
> **Some of what this mod does cannot be undone, and that is why it is beta.**
>
> Romantasy stores each companion's likes and dislikes itself and restores its own
> copy whenever you load. This mod can add to them; **nothing can remove them** —
> not this mod, not uninstalling, not reverting to an earlier save once they have
> been written. If a companion is authored with preferences you dislike, they keep
> those preferences.
>
> Uninstalling stops anything new from happening. It does not return a save to the
> state it was in before. Character data written here lives in the co-save, and
> applied preferences stay applied.
>
> **Use it on a save you are willing to keep it on, and back that save up first.**
> It will stay beta until Romantasy ships the ability to modify preferences, at
> which point these become reversible and the label comes off.
>
> ---
>
> **A companion you recruit does not start scoring until your next game load.**
>
> Romantasy reads its follower configuration once, at load. This mod enrolls
> people the moment they join you, but Romantasy cannot see that enrollment until
> the game is loaded again — so for the rest of that session the companion is
> observed and nothing accrues. Points earned in the gap are rejected rather than
> banked.
>
> Nothing is broken and nothing is lost: reload, and they score normally from then
> on. Recruit, save, reload is the reliable pattern.
>
> This is the reason for the beta label. ColdSun has a Romantasy release in
> progress that adds the entry point needed to fix it, at which point this
> disappears entirely and the change here is one line.

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
open to everyone. The romantic track is separate, and getting onto it takes more
than time — see below.

**Scores conversation.** Talking matters. A background judge reads what actually
passed between you and decides whether it moved anything — usually it did not.
Pacing lives in code, not in the prompt: daily caps, cooldowns, and a rarity
limit on the moments where two people redefine what they are.


**Lets people change.** Dispositions are reviewed as companions live, and can
move in either direction — but only on a pattern of behavior across days, never
on one memorable evening, and only one step at a time. Someone who swore off
commitment can come to want it. Someone badly treated can close up.

## The gate between friendship and romance

This is the part that most distinguishes the mod from the framework underneath
it, and there are two locks on it.

**Nothing becomes romantic on its own.** Traveling together for a year does not
make someone fall in love with you. A background assessor watches for a moment
where something between you actually crossed, and until it finds one, a companion
stays platonic no matter how deep the bond runs. Someone can climb the whole
ladder as a friend and remain one. That is a real ending, not a failure state.

**And crossing takes both of you.** A spark is only their half of it. When a
companion reaches the point of wanting more, they raise it themselves, in their
own words, and you answer plainly:

| your answer | what happens |
|---|---|
| you feel the same | the romantic track opens and the bond can keep climbing |
| you do not | they stay a friend, and the bond steps back to make room |
| say nothing for now | the question stays open; they will raise it again later |

**You can turn someone down.** Declining is a real answer with real weight. It
does not erase what they feel, it does not end the friendship, and it does not
make them cold toward you — but the bond does step back to the middle of Friend,
because a refusal that left them one good conversation short of asking again
would be no refusal at all. The friendship grows again from there, on its own
terms, and they may raise it once more when there is real ground for it.

**Nothing creeps past the question while it is unanswered.** Depth is held one
point below Spouse until you have answered, so no companion arrives at
marriage-eligible by accumulation alone.

**Spouse is the rung that makes marriage possible.** It is not a claim to be
married — the proposal itself happens through whatever marriage system you use.
This mod's job is making sure you both meant it before you get that far.

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

Settings appear in SkyrimNet's plugin panel under **SkyrimNet Relationships**.

## Configuration

Everything is tunable from SkyrimNet's settings page. The defaults are calibrated
so that an authored emotional beat is worth roughly what clearing a dungeon is
worth, and so that nothing moves quickly.

Notable knobs: how much conversation can move a bond in a day, how long between
moments where a relationship is allowed to be redefined, how long two people must
travel together before romance can begin at all, whether personalities are
allowed to change over time and how much must have happened first.

## Status

**Beta.** The four subsystems — enrollment, authoring, conversational scoring and
the romantic gate — are built and confirmed working in live play across dozens of
companions. Disposition drift and the consent prompt are newer and have fewer
hours on them.

Known limitations, honestly:

- **Enrollment is not live until the next game load.** See the notice at the top.
  This is the headline caveat and the reason for the beta label.
- **Preferences are append-only.** Romantasy restores its own copy on load, so a
  companion's likes and dislikes can be added to but never removed. A re-author
  only ever adds. Romantasy's next release is expected to change this.
- **There is no in-game repair tool yet.** If an authored character reads wrong,
  correcting it means the SkyrimNet web API — see Troubleshooting below.
- **Uninstalling does not fully reverse it.** Preferences already applied stay
  applied, because Romantasy restores them; the character data this mod writes
  lives in the co-save. Removing the mod stops anything new from happening, but a
  save that has run it does not return to a pristine state. Try it on a save you
  are willing to keep it on.

## Troubleshooting

There is no in-game menu yet, so repairs go through SkyrimNet's web API while the
game is running. Every call is a POST to
`http://127.0.0.1:8080/game-data?api=execute-quest-script-function`.

**Find someone's FormID** — open `http://127.0.0.1:8080/game-data?api=nearby-actors`
in a browser with the game running. It lists everyone loaded, with their IDs.

**Someone was enrolled who should not have been.** Takes the display name exactly
as it appears in game, and works even if they are nowhere near you:

```json
{"questEditorId":"SNRom_Quest","scriptName":"SNRom_Bridge",
 "functionName":"UnenrollByName","arguments":["Lydia"]}
```

**An authored character reads wrong.** Rewrites who they are without touching
their likes and dislikes. They must be loaded and near you, or the model has
nothing to read:

```json
{"questEditorId":"SNRom_Quest","scriptName":"SNRom_Bridge",
 "functionName":"ReauthorCharacter","arguments":["0x000A2C95"]}
```

**One field is wrong and the rest are right.** Field 0 is intimacy (0 casual,
1 romantic, 2 guarded, 3 never), 1 is ardor (0–4), 2 is exclusivity (0–100).
All three arguments are required:

```json
{"questEditorId":"SNRom_Quest","scriptName":"SNRom_Bridge",
 "functionName":"SetCharacterField","arguments":["0x000A2C95",2,60]}
```

**Nothing seems to be happening at all.** Check
`Data\SKSE\Plugins\SkyrimNet Relationships\logs\snrom.log`. A healthy log shows
follower sweeps, `Talk assessment sent`, and verdicts. If it is silent, the usual
causes are that SkyrimNet cannot reach an LLM backend, or that a model preset was
applied in the SkyrimNet UI and dropped this mod's `snrom_background` variant.

## Credits

Built on [Romantasy](https://www.nexusmods.com/skyrimspecialedition/mods/186060)
by ColdSun and [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/151960)
by MinLL. Neither is vendored here; both are required separately.

## License

MIT — see [LICENSE](LICENSE). Covers this mod's own code and content only; every
mod it integrates with retains its own license, and none is redistributed here.
