# Working with M.A.R.A.S

[MARAS](https://github.com/tetherball88/maras) is an optional dependency. Absent,
everything here is inert and nothing errors. Present, this mod reads it and
defers to it — it never writes to it.

## The rule: cooperate, never gate

**Spouse tier is depth, not marriage.** A shield-sister who will never be a lover
has to be able to reach the top of the ladder, because that is the whole two-track
design. So nothing in this mod is gated on MARAS. Reaching Spouse means the bond
is deep enough that marriage would make sense; whether it can actually happen is
MARAS's question, and MARAS answers it.

What we do instead is **state the facts and let the character judge them** — the
same principle everything else here follows.

## What we read

Papyrus, through `MARAS.psc`, guarded by `Game.IsPluginInstalled("TT_MARAS.esp")`:

| call | used for |
|---|---|
| `IsNPCStatus(npc, "married")` | part of `IsMarriedToPlayer`, alongside vanilla `PlayerMarriedFaction` |
| `IsNPCStatus(npc, "engaged")` | seeding evidence, and asserted to the assessors |
| `IsNPCStatus(npc, "candidate")` | whether a wedding is possible at all |
| `GetStatusCount("married")` | how many spouses the player already has |
| `GetPermanentAffection(npc)` | logged for calibration only; nothing reads it |

Inja, inside a block already guarded by `maras_present`:

- `get_global_value("TTM_EnablePolygamyToggle")` — 1.0 once the polygamy quest is
  complete or the MCM override is set. There is no Papyrus route to this without
  the global's FormID, which is why it is read in the template instead.

## What we pass to the assessors

`MarasContext()` appends these to the JSON context of the talk, spark and drift
prompts. They are **Ints, not strings** — a context boolean fed by a String is the
case-fold trap wearing a different coat, and `check.ps1` fails the build over it.

    maras_present  npc_married  npc_engaged  npc_candidate  player_spouse_count

`npc_married` is computed outside the MARAS guard, because `IsMarriedToPlayer`
reads vanilla `PlayerMarriedFaction` first and a vanilla marriage is still a fact
when MARAS is absent.

## Why this exists

A companion reached Spouse tier while the player was already married to someone
else and the polygamy quest was incomplete. The talk assessor had no marriage
vocabulary at all, so when the conversation reached an agreed wedding it matched
*THE ONE THING THAT IS ALWAYS LARGE* — an explicit mutual decision to become
something new — and paid a LANDMARK award for a marriage that had not happened
and, at that moment, could not happen. Those points then carried her toward
Spouse, which is the tier that is supposed to mean marriage is *possible*.

The prompt was working exactly as designed. It simply did not know that marriage
has an external gate. So the facts now travel with the question, and a
conversation about marrying reads as a hope or a plan unless the world records
otherwise.

This is the `npc_married` lesson generalised. Jarl Elisif, married to the player
through MARAS, was authored `ORIENTATION: WOMEN / BASIS: STATED` — the one
confidence level allowed to refuse — because her static bio says nothing about who
she married, so the model was asked to infer with no evidence and obliged. Papyrus
knew all along. **Anything Papyrus can assert should be asserted rather than
inferred.**

## MARAS behaviour worth knowing

Findings from reading MARAS 1.x, correct at the time of writing:

- **Candidacy comes from a vanilla dialogue topic**, not from conversation.
  `MARAS.RegisterCandidate()` is called from the `maras_enable_candidate`
  TopicInfo. None of MARAS's four SkyrimNet actions registers candidacy, so a
  player who interacts mostly through AI conversation can discuss marriage at
  length without the NPC ever becoming a candidate.
- **The polygamy gate is advisory.** `0501_marriage_chances.prompt` tells an NPC
  she "might respond with confusion" when the player is already committed and
  polygamy is off. It is prompt guidance, not a hard block.
- **That guidance only renders for tracked NPCs.** The whole block is wrapped in
  `is_in_faction(npc.UUID, "TTM_TrackedNpcs")`, so an NPC who is not yet a
  candidate receives no marriage context at all.
- **Completing the polygamy quest removes the PLAYER from `PlayerMarriedFaction`**
  so they can marry again. It does not remove the spouse, so `IsMarriedToPlayer`
  is unaffected — it tests the NPC's membership, not the player's.

## What we deliberately do not do

- **We do not call `RegisterCandidate()`.** It is a public native and it would
  make a Spouse-tier companion marriageable in one line. It also writes into
  another mod's data and takes a decision away from both the player and MARAS. If
  this is ever added it belongs behind an explicit, default-off setting.
- **We do not try to enforce MARAS's proposal gate.** Not ours to enforce, and
  MARAS may add a hard check of its own.
- **We do not gate any tier, award or assessment on marital state.** Only describe
  it.
