# Relationships

### A SkyrimNet-Romantasy Integration Mod

Every companion forms their own opinion of you — and it changes.

**[How it works, in pictures](https://deadohiosky48.github.io/SkyrimNet-Relationships/)**

---

> ### Requires Romantasy 1.1.1 or newer
>
> Earlier Romantasy versions cannot see a follower enrolled mid-session until the
> game is reloaded, and cannot remove a preference once it is written. This mod
> degrades gracefully on them rather than breaking — but two of its central
> promises, that a companion starts scoring the moment they join you and that an
> authored character can be corrected, are simply not deliverable there.
>
> **1.1.0 specifically** treated every follower this mod enrolled as though a mod
> author had written their preferences, and refused to let anything set them. If
> you enrolled companions on 1.1.0 they may have no likes or dislikes at all, and
> updating alone does not fix them — see *Troubleshooting* below.

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

**Nothing creeps past the question while it is unanswered.** The gate is on
romance, not on depth: a companion who has sparked but whose question you have not
answered is held just short of marriage-eligible, so nobody arrives there by
accumulation alone. The points are banked, not lost, and return in full when you
answer. A purely platonic companion has no question to answer and climbs to the
top of the ladder freely.

**Spouse is the rung that makes marriage possible.** It is not a claim to be
married — the proposal itself happens through whatever marriage system you use.
This mod's job is making sure you both meant it before you get that far.

## Requirements

| | |
|---|---|
| [SkyrimNet](https://www.nexusmods.com/skyrimspecialedition/mods/151960) | required |
| [Romantasy](https://www.nexusmods.com/skyrimspecialedition/mods/186060) | required — **1.1.1 or newer** |
| SKSE64 | required |
| PapyrusUtil SE | required — StorageUtil, JsonUtil, MiscUtil |
| Papyrus MessageBox ([Nexus 83578](https://www.nexusmods.com/skyrimspecialedition/mods/83578)) | required for the consent prompt; bundled by MARAS |
| An LLM backend SkyrimNet can reach | required — local or hosted |

### Optional, and genuinely optional

Each of these is detected at runtime. Absent, the feature it powers is simply
inert; nothing errors and no prompt breaks.

| | adds |
|---|---|
| SeverActions | follower detection and rapport-based head starts for companions you already know. From **3.9.11** it detects this mod and steps its own Intimacy & Consent section aside, so nobody is handed two ideas of how receptive they are |
| OStim Community Resource | physical attraction as an input, for characters whose disposition allows it to matter |
| MARAS | marriage and engagement are read as facts rather than judged |
| [SkyrimNet-Kinship](https://github.com/deadohiosky48/SkyrimNet-Kinship) | your own children are barred from the romantic and sexual ladders |

What this mod reads from MARAS, and why it never gates on it, is written up in
[Working with M.A.R.A.S](docs/MARAS_INTEGRATION.md).

## Installation

Install with a mod manager, or copy the contents over your `Data` folder.
`SNRom_Integration.esl` is ESL-flagged and does not consume a load-order slot.

Settings appear in SkyrimNet's plugin panel under **SkyrimNet Relationships**.

## Configuration

Everything is tunable from SkyrimNet's settings page. The defaults are calibrated
so that an authored emotional beat is worth roughly what clearing a dungeon is
worth, and so that nothing moves quickly.

**Bond Pace** is the setting most people will want. Slow, Normal or Fast, under *Pacing*
— roughly twice as long, as-is, or roughly half. It multiplies what is earned in
both directions, so on Slow a misstep also costs less, and it never changes where
a relationship can end up: only how long the road is. Fourteen finer knobs sit
underneath it and all of them still work; this moves them together.

Notable knobs: how much conversation can move a bond in a day, how long between
moments where a relationship is allowed to be redefined, how long two people must
travel together before romance can begin at all, whether personalities are
allowed to change over time and how much must have happened first.

The setting that matters most to whether the mod works at all is **LLM Variant**, which chooses the model
serving every background assessment this mod makes. See
[Diary entries, and which model sees what](docs/DIARY_AND_LLM_ROUTING.md) for
what to point it at and why — and for how SkyrimNet's automatic diary entries
work, since this mod leans on them harder than on anything else.

## Status

**Released.** Enrollment, authoring, conversational scoring, the romantic gate,
disposition drift and the consent prompt are all built and confirmed in live play
across dozens of companions.

Known limitations, honestly:

- **Preferences are shared ground, and first writer keeps them.** If another mod
  or a follower's own author has already given someone likes and dislikes, this
  mod leaves them alone and authors only the character. It will not overwrite
  another author's work, and it will not overwrite preferences you have set by
  hand in Romantasy's own editor.
- **Preferences do not yet change over time.** They are written once, when a
  companion is first authored. Dispositions drift; likes and dislikes do not, yet.
- **There is no in-game repair tool.** If an authored character reads wrong,
  correcting it means the SkyrimNet web API — see Troubleshooting below.
- **Uninstalling does not fully reverse it.** The character data this mod writes
  lives in the co-save, and Romantasy keeps its own record of points and
  preferences. Removing the mod stops anything new from happening; it does not
  return a save to the state it was in before.

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

**They were enrolled but have no likes or dislikes.** This is the Romantasy
1.1.0 bug: that version treated every follower this mod enrolled as
author-managed and refused all preference writes. **Update Romantasy to 1.1.1
first** — the repair cannot work on 1.1.0, it will simply be refused again.

Then, once per affected follower:

```json
{"questEditorId":"SNRom_Quest","scriptName":"SNRom_Bridge",
 "functionName":"RepairPreferences","arguments":["0x000A2C95"]}
```

They must be loaded and near you. Existing likes and dislikes are kept — nothing is
wiped — but this re-runs the full authoring pass, so **their character is rewritten**:
orientation, intimacy, ardor and exclusivity all come back fresh. That is usually
what you want, since anything authored before 1.0.5 used the old exclusivity scale.
If you like a character as-is and only want the gates adjusted, use
`ReauthorCharacter` or `SetCharacterField` instead.

The log confirms it with `Repairing preferences for …`, then `Disposition authored
for …`, then the individual preference writes.

If the log instead shows `SetPreference refused`, Romantasy is still rejecting
the writes and the version is the thing to check.

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

## License and permissions

**Source-available, not open source** — see [LICENSE](LICENSE) for the full text.

Freely permitted, no need to ask: use it, modify your own copy, and publish
patches, add-ons or translations that *require* this mod rather than containing
it. **Interoperating is expressly permitted and encouraged** — read its
StorageUtil keys, call its decorators, render its submodules, build a mod that
depends on it. None of that needs permission.

Ask first for: redistributing it or a substantial part of it, publishing a
modified version, or including its files in a collection or modpack. Permission
is usually given quickly; the point is to keep one canonical version so users
are not split across divergent copies.

Not permitted: commercial use, or presenting the work as your own. Videos,
streams, guides and reviews are all fine, including monetized ones.

Covers this mod's own code and content only. Every mod it integrates with keeps
its own terms, and none is redistributed here.
