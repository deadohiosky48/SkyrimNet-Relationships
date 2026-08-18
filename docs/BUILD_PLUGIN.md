# Building `SNRom_Integration.esp` in the Creation Kit

One quest, one alias, no masters beyond vanilla. About ten minutes.

The plugin is deliberately tiny: the bridge resolves `ROM_RomanceLevel` at
runtime with `Game.GetFormFromFile(0x800, "CS_Romantasy.esp")`, so **Romantasy
is not a master** and the plugin loads (inert) without it. Nothing else
references a foreign form.

---

## You almost certainly do not need this

**`SNRom_Integration.esl` is prebuilt.** It ships in this repository and in every
release archive. Install the release and it works. Nothing below is required to
play, and nothing below is required to change a prompt, a trigger, or a setting.

Follow this only if you are changing the **plugin record itself** — the quest,
the player alias, or the script bindings.

## Before you start — two things the repository does not contain

**1. Vendored Papyrus headers.** Our scripts compile against types owned by other
mods, and those files are not ours to redistribute, so they are gitignored. Get
them from the mods themselves and drop them in `src\scripts\`:

| File | Where it comes from |
|---|---|
| `SkyrimNetApi.psc` | SkyrimNet, in its `Source\Scripts\` folder |
| `MARAS.psc` | MARAS, in its script sources |

Without them `tools\build.ps1` fails with unresolved-type errors on the first
script it touches.

**2. Compiled scripts.** `Scripts\*.pex` are build output and are gitignored too.
Step 0 below needs them, so run the build first:

```
powershell -ExecutionPolicy Bypass -File "tools\build.ps1"
```

That also wants `tools\local.settings.ps1` — copy `local.settings.ps1.example`
and set your Skyrim path. It is the only file permitted to contain absolute paths
from a particular machine, which is why it is not in the repository either.

---

## Step 0 — put the scripts where CK can see them

CK reads compiled `.pex` to discover a script's properties, and wants the
`.psc` alongside. Before launching it:

Copy from the repo into your **game Data folder**:

| From | To |
|---|---|
| `Scripts\SNRom_Bridge.pex` | `Data\Scripts\` |
| `Scripts\SNRom_PlayerAlias.pex` | `Data\Scripts\` |

**Copy the `.pex` only — do NOT copy our `.psc` into `Data\Scripts\Source`.**

CK reads the compiled `.pex` to discover a script's properties; it does not
need our source. And a copy of `SNRom_Bridge.psc` sitting in
`Data\Scripts\Source` will **shadow the build**: that folder is on the Papyrus
compiler's import path, so the compiler resolves the script name from the
stale copy there instead of the file it was handed, emitting a `.pex` that
silently does not match source. It compiles cleanly and reports success. The
symptom in-game is a script whose variables belong to a version you deleted.

These are temporary — the real install is packaged as a Vortex mod later.

> If CK cannot find `SNRom_Bridge` in the script list at step 3, this step is
> why.

---

## Step 1 — new plugin

1. Launch **CreationKit.exe**.
2. **File → Data…**
3. Tick **Skyrim.esm ONLY.**

   Not the DLC, not `CS_Romantasy.esp`, not `SkyrimNet.esp`. This plugin
   references exactly two things — a new quest and `PlayerRef` — and
   `PlayerRef` lives in Skyrim.esm. Loading anything else only adds load time
   and risks putting an unwanted master on the plugin.

4. Do **not** set an active file. Click **OK**.
5. Expect a couple of minutes and a pile of warnings. Dismiss them (holding
   **Enter**, or ticking "Yes to all", is fine).

> **If a "File in use" dialog appears** naming a path in the *game root*
> rather than `Data\` — e.g. `…\Skyrim Special Edition\Dawnguard.esm` — with
> an elapsed-time counter and only a **Cancel** button: that is CK's
> version-control checkout prompt polling a path that does not exist. It will
> wait forever. Check the status bar: if it reads "Finished validating forms"
> the load already completed, and **Cancel** simply dismisses it.
>
> Loading Skyrim.esm alone avoids this entirely, which is the other reason
> for step 3.

---

## Step 2 — create the quest

1. In the **Object Window**, expand **Character → Quest**.
2. Right-click in the list → **New**.
3. Set:
   - **ID**: `SNRom_Quest`
   - **Quest Name**: *leave empty* — otherwise it appears in the player's journal
   - **Priority**: `0`
   - ✅ **Start Game Enabled**
   - ❌ **Run Once** — must stay unchecked, or it will not restart
   - ❌ **Allow repeated stages** (irrelevant, no stages)
4. Leave every other tab alone. No stages, no objectives — this quest exists
   only to host a script.

---

## Step 3 — attach the bridge script

> **Create the quest first, THEN attach the script.** Filling in the quest and
> attaching a script in one pass before the first OK has been observed to
> crash CK 1.6.1378.1 on save. Doing it in two passes works.

1. With the quest from Step 2 created and saved, reopen `SNRom_Quest`.
2. Go to the **Scripts** tab.
3. **Add** → choose the existing `SNRom_Bridge` from the list (not
   *[New Script]*).
4. **There are no properties to fill.** The script deliberately declares none —
   `_romanceLevel` is a script variable resolved at runtime from
   `CS_Romantasy.esp`, and the rest are constants. If CK is prompting you for
   a property value, you have attached the wrong script.
5. Click **OK** to save the quest.

---

## Step 4 — the player alias

1. Reopen `SNRom_Quest` and go to **Quest Aliases**.
2. Right-click in the alias list → **New Reference Alias**.
3. Set:
   - **Alias Name**: `PlayerAlias`
   - **Fill Type**: select **Unique Actor**, then choose **Player** from the
     dropdown.
     *(**Forced Reference → PlayerRef** also works; either is fine.)*
   - ❌ **Optional**

   > **Allow Reserved** will be grayed out. That is correct — it only applies
   > to fill types that *search* for a reference another quest might have
   > reserved. Unique Actor targets one known reference, so there is nothing
   > to contend for. Leave it alone.
4. In that alias window's **Scripts** box, **Add** → `SNRom_PlayerAlias`.
5. **No properties to fill.** The alias finds the bridge through
   `GetOwningQuest()`, deliberately, so there is nothing here to get wrong.
6. **OK** out of the alias, then **OK** out of the quest.

---

## Step 5 — save

1. **File → Save**

   There is no *Save As…* in this CK. With no active file set, plain **Save**
   prompts for a filename — that is how a new plugin gets created. Ignore
   **Save and Push Plugin to PC**; that is the Creation Club / console
   deployment path.

2. Filename: `SNRom_Integration.esp`
3. It writes to your game `Data` folder.

> Clicking **OK** in the quest dialog commits the record in memory only. Until
> you do File → Save, nothing exists on disk.

---

## Step 6 — flag it ESL (optional, recommended)

Two new records will not trouble your plugin budget either way, but light is
tidier.

- **In CK:** with the plugin active, **File → Convert Active File to Light Master**.
- **In xEdit:** select the plugin header, right-click → **Add ESL flag to plugin**.

Either is safe here — a fresh plugin with no dependents.

---

## Step 7 — verify before playing

Load a save with the plugin active and open the console:

```
help SNRom_Quest 4
```

You should get a form ID. Then:

```
sqv SNRom_Quest
```

Expect the quest **Running** with the alias filled by the player.

Finally, check `Data\SKSE\Plugins\SkyrimNet Relationships\logs\snrom.log` for:

```
Bridge ready. Romantasy build check passed.
```

If instead you see *"CS_Romantasy.esp not loaded or ROM_RomanceLevel missing"*,
the plugin is running correctly but cannot see Romantasy — check load order.

If the log file does not exist at all, the quest is not running: re-check
**Start Game Enabled** and that **Run Once** is unchecked.

---

## Common failure modes

| Symptom | Cause |
|---|---|
| `SNRom_Bridge` missing from the script list | Step 0 skipped — `.pex` not in `Data\Scripts` |
| Quest never starts | **Start Game Enabled** unticked, or **Run Once** ticked |
| Works once, dead after reload | Alias missing, wrong fill type, or script not attached to it — that alias is the only thing re-registering decorators and ModEvents |
| CK refuses to save, complains about masters | A form from `CS_Romantasy.esp` got referenced somewhere; nothing in this plugin should reference it |
