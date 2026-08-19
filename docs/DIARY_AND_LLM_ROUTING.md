# Diary entries, and which model sees what

Notes for anyone building on SkyrimNet, written because the same two questions
keep coming up: *what makes diary entries appear on their own*, and *which model
is actually serving a given call*.

## Where diary entries come from

Diary entries are not produced by an action or a trigger. They come from a
background subsystem inside SkyrimNet itself, in the same family as memory
generation, and it runs whether or not anything asked it to.

It is gated by thresholds in the `Diary` section of SkyrimNet's settings:

| setting | default | effect |
|---|---|---|
| `enabled` | `true` | on out of the box — this is why entries appear unprompted |
| `min_events_for_generation` | `5` | at least this many qualifying events must be banked |
| `min_importance_score` | `0.3` | only events scoring at or above this count toward that total |
| `respect_day_boundary` | `true` | generation aligns to in-game day rollover |
| `max_recent_events` | `200` | how much event history is fed to the prompt |
| `max_recent_memories` | `5` | recent memories added as context |
| `target_entry_length` | `1000` | target length of the entry |
| `exclude_from_recall` | `true` | entries do not feed back into memory recall |

So an entry appears when a day boundary passes with enough sufficiently
important events behind it. It renders `prompts/diary_entry.prompt` — first
person, per NPC — and afterwards emits a `diary_entry_created` event, which is
persistent but has `allowNPCReaction: false`, so it is recorded without NPCs
reacting to it.

`exclude_from_recall` is worth understanding rather than changing. It stops
entries from being fed back in as memories, which would otherwise let an NPC
reflect on their own reflections and drift further from events each cycle.

There is a manual path too: the `generateDiaryBio` hotkey, unbound by default.
Bind it if you need entries on demand for testing.

## The three ways SkyrimNet runs an LLM

Worth having straight before integrating, because they fail differently:

- **Actions** — the model picks from eligible options during interaction.
  Selection is two-stage: the category is chosen from a one-line blurb *before*
  any action text is shown, so the category is a router and the action is a gate.
- **Triggers** — game events inject prompts or behavior. Templating here uses
  flat tokens such as `{{ player_name }}`, not the object form.
- **Background subsystems** — diary and memory generation, owned by the DLL and
  driven by timers and thresholds. Nothing in your mod invokes them, and nothing
  in your mod can stop them.

Diary generation is the third kind, which is why it looks spontaneous.

## Why this mod treats a diary as its best source

Relationships reads diaries in four of its prompts, through
`get_diary_entries(npc_uuid, 5)`.

The reason is that a diary is the one place a character has no reason to
perform. Dialogue is what someone was willing to say aloud to a person standing
in front of them, and people are guarded there precisely when it matters most. A
private entry naming a feeling outranks an hour of careful conversation.

## Position beats instructions

The most useful thing we learned, and it cost real debugging time.

Telling the model which source to trust does not reliably beat *where that
source sits in the prompt*. Demonstrated on `snrom_talk_assess` in July 2026:
moving a block, with no wording change at all, changed which source the model
quoted.

Our prompts order the diary in two opposite ways, for two different reasons.

**Assessments put the diary last.** `snrom_spark_assess` and
`snrom_disposition_drift` render dialogue, then memories, then the diary —
least guarded last, closest to the question. These prompts had always *said*
"weigh their diary above everything else" while rendering memories nearest the
question, so the stated priority had been losing to the layout the entire time.

**Authoring puts the diary first.** `snrom_author_disposition` reverses it,
because the competition there is different. A character whose diary described
going to bed with the player, waking warm in the sheets, and a kindness she
"didn't think she was allowed to expect anymore" was authored as ORIENTATION:
NONE, INTIMACY: NEVER — justified as "no indication of personal desire or
vulnerability". Twice, identically.

The diary was rendering correctly and sat about thirty lines above the
questions, so distance was never the problem. What beat it was SkyrimNet's
`## What You Know About <player>` familiarity block, which reported that they
barely knew each other, under a header announcing THIS IS WHO YOU ARE
ROLEPLAYING AS. An authoritative-sounding stale counter outranked a character's
own account of her own life.

That block is generated from an interaction counter, not from what has happened.
It routinely claims two people are near strangers while their diary describes
years of intimacy. Our prompts now call it out by name as unreliable, and the
diary is placed first so it frames everything after it.

**The general rule:** if a source must win, put it adjacent to the question, and
if a source must be discounted, say so explicitly and by name. Stating a
priority alone is not enough.

## Which model is serving the call

Every background LLM call this mod makes — disposition authoring, conversation
scoring, the romance assessment, and drift reviews — runs on the single variant
named by the `llmVariant` setting.

Three things about that are easy to get wrong:

**Prefer a low temperature.** These prompts emit labeled lines that get parsed,
not prose. Creative sampling is how they come back malformed. A variant tuned
for diary or dialogue writing — warm, long, high temperature — is the wrong
shape for this work even on a large model. Model capability scales up safely;
sampling settings do not travel with it.

**Do not borrow another subsystem's variant.** This defaulted to
`DiaryGeneration` until 2026-08-19. Anyone who decided their diary entries were
too terse and warmed that variant up would have silently retuned every
assessment this mod makes, with nothing on screen connecting cause to effect.
The default is now `CharacterProfileGeneration`, which is at least the same kind
of work.

**Know whether your variant is local or paid.** Variant names are user-defined
and a name says nothing about where it runs. Whichever one you point this at may
resolve to a commercial endpoint, and disposition authoring fires on every
enrollment. If you run local models for background work, point this there.

Two failure modes that look identical from Papyrus and are not:

- `LLM returned empty response` covers both a genuine provider failure **and** a
  prompt missing its `[ system ]` / `[ user ]` markers, which produces an empty
  messages array and never reaches a provider at all. Only `SkyrimNet.log`
  distinguishes them, with `Messages array is empty`.
- What matters is the **provider**, not `model_name`. KoboldCPP-style backends
  ignore the requested model and serve whatever is loaded, so a variant's
  `model_name` can disagree with reality without any error anywhere.

Finally: a template that fails to parse takes down every assessor sharing it and
still returns success to Papyrus. Verify template edits with a live render.
