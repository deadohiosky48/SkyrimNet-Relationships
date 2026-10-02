# SkyrimNetRelationships.dll

The dashboard's native host: a small SKSE plugin that opens the page in
`ui/relationships/` in Meridian UI and carries messages between it and the game
(design 6.5, 7.1, 7.3). It is **optional**. Without it, or without Meridian UI,
there is no dashboard and the rest of the mod works unchanged.

Modelled on SkyrimNet-Kinship's `SKSE_Source/`, with three differences: it builds
**/MD** (triplet `x64-windows-static-md`), it has no SKSE Menu Framework, and the
project and DLL are named `SkyrimNetRelationships`.

## Layout

| path | what |
|---|---|
| `CMakeLists.txt`, `vcpkg.json`, `cmake/` | the build; `cmake/` is the /MD overlay triplet |
| `PCH.h`, `plugin.cpp` | logging, SKSE startup, and the SKSE messages it acts on |
| `src/ViewHost.h` | the UI-framework interface: create, listen, show, focus, hide, send |
| `src/MeridianHost.cpp` | the Meridian implementation, from the vendored MIT headers |
| `src/Dashboard.cpp` | open and close, the page protocol, the refresh, the op table |
| `src/Model.cpp` | the read model Papyrus fills, and the snapshot built from it; free of game types |
| `src/Display.cpp` | display copies of three Papyrus rules, on probation (below); free of game types |
| `src/Hotkey.cpp` | the input sink, the modifier check, and virtual-key to scan-code conversion |
| `src/Settings.cpp` | the settings watcher: re-reads the dashboard settings when SkyrimNet saves them |
| `src/Natives.cpp` | the Papyrus natives in `src/scripts/SNRom_Native.psc` |
| `include/MeridianUIAPI/` | Meridian's MIT headers, unmodified; see the README there |
| `extern/`, `build/` | fetched and built locally, gitignored, never committed |

## Build

You need Visual Studio 2022 with **Desktop development with C++** and **C++ CMake
tools for Windows**, plus git. Run these from the repository root.

```
pwsh -ExecutionPolicy Bypass -File tools\build-dll.ps1 -Setup
pwsh -ExecutionPolicy Bypass -File tools\build-dll.ps1
```

`-Setup` runs once. It fetches vcpkg into `.tools\vcpkg` and CommonLibSSE-NG, with
submodules, into `native\extern\`, pinned to the commit the code was checked
against (`$commonLibRef` in the script). The first build also has vcpkg compile
the dependencies, which takes a while.

**Long paths.** CommonLibSSE-NG's submodules nest deep enough to pass Windows'
260-character path limit, and under a deep checkout the clone fails with
"Filename too long". `-Setup` clones with `core.longpaths` set and keeps it set
in the clone. If a clone made some other way fails like this, run
`git config core.longpaths true` inside it and
`git -c core.longpaths=true submodule update --init --recursive`, or move the
checkout to a shorter path.

The output is `native\build\Release\SkyrimNetRelationships.dll`.

## Deploy and package

```
pwsh -ExecutionPolicy Bypass -File tools\build-dll.ps1 -Deploy
```

This copies the DLL to `SKSE\Plugins\` and the page, without `mock\`, to
`MeridianUI\snrelationships\` in the staging folder named by `StagingRoot` in
`tools\local.settings.ps1`. Then deploy in your mod manager.

`tools\package.ps1` ships the same two things when the DLL is built. It refuses
to package if the DLL contains an absolute path or the build machine's user,
machine or domain name, if a `.pdb` is staged, or if any of the mock host reaches
the page.

## At runtime

- **Needs:** SKSE, Address Library for SKSE Plugins (every CommonLibSSE-NG
  plugin does, Meridian UI included), and Meridian UI 1.5.0 or newer for the
  dashboard itself.
- **Log:** `SkyrimNetRelationships.log`, beside SKSE's own logs in
  `My Games\Skyrim Special Edition\SKSE\`.
- **Settings:** SkyrimNet's plugin panel, under Dashboard.
  - `dashboardHotkey` ships unbound. It is a virtual-key code from the hotkey
    widget, which the DLL converts to a scan code; a key with no scan code is
    refused and logged, never bound to a different key.
  - `dashboardHotkeyModifier` is None, or one side of Shift, Ctrl or Alt, which
    must then be held when the key goes down. The DLL asks Windows whether it is
    held at that moment (`GetAsyncKeyState` on that side's virtual key) rather
    than tracking it from key events, so a modifier released while the game was
    alt-tabbed away can't stay "held". An option it doesn't know is refused,
    never treated as None. A modifier narrows when the dashboard opens; it does
    not stop another mod bound to the same key from reacting to it.
  - `dashboardDeveloperView` is the developer view (design 7.6).
  - `dashboardScale` is Auto, or 75% to 200%: how big the page is drawn, text
    and spacing alike. Auto follows the view's height, 1080 lines being 100%
    (1440 is about 133%), and stays between 75% and 200%.
  - `dashboardTextSize` is Normal, Large or Larger, on top of the scale. It
    sizes the text and the boxes that hold it, not the spacing.
  - Both are selects, so they arrive as the option's name, and the DLL reads
    the name with one table (`Settings::ScaleFromName` and `TextSizeFromName`)
    whichever way it comes. An option it doesn't know is logged, and that
    setting stays as it is.
- **Live settings:** the DLL watches
  `Data/SKSE/Plugins/SkyrimNet/config/plugins/SkyrimNet Relationships/settings.yaml`,
  resolved against the folder the game runs from, which SkyrimNet rewrites
  whenever its panel saves. A background thread checks the file's last-write
  time and size every 2 seconds. It uses a plain check rather than change
  notifications, which may not see writes under Mod Organizer's virtual file
  system. On a change it reads the five keys and applies them on the main
  thread, so a change lands within a couple of seconds. SkyrimNet's settings
  screen and the dashboard are never open together, so a player sees the change
  the next time the dashboard opens. The DLL would still send an open dashboard
  a snapshot carrying the developer view, the scale and the text size at once;
  that costs nothing and is left in.
  - A file that is missing, can't be read, or has none of the five keys leaves
    the current settings alone, and is logged once until it recovers.
  - A number or true/false it can't read is logged, and that one setting is
    left as it is. An unknown modifier is refused, as above.
  - It opens the file with every share flag, so it never blocks SkyrimNet's
    own save.
- **Papyrus:** hands the five settings over through `SNRom_Native` once per
  bootstrap (`SetDashboardHotkey`, `SetDeveloperView`, `SetDisplaySettings`),
  so they hold from the first load even if the file can't be read. It doesn't
  poll: the watcher covers changes. It calls nothing unless
  `SKSE.GetPluginVersion("SkyrimNetRelationships") > 0`, and nothing but
  `Version()` unless that returns 5 or more (version 2 added the modifier,
  version 3 the read model, version 4 `SetDisplaySettings`, version 5
  `RecordChange`, the bond history, and `Announce`, the held tier notices,
  version 6 `ObserversNear`).
- **`tools/check.ps1`** fails when a key Papyrus reads is missing from the live
  `settings.yaml`, which SkyrimNet writes once and never regenerates. After
  installing this version, add `dashboardScale: Auto` and
  `dashboardTextSize: Normal` to it.
- **Threads:** everything that touches the view runs on the main thread, where
  SKSE tasks run; the log prints the thread id so that can be checked. The input
  sink, the settings watcher, the Meridian listeners and the Papyrus natives all
  queue their work. The read model is the one exception: the natives write it
  from a Papyrus thread, under its lock.

### The roster: a read model Papyrus fills (design 7.3, WP2)

The DLL holds a **read model** of the roster: rows keyed by form id, plus which
store is live. Papyrus pushes values into it through `SNRom_Native` (version 3).
It is derived and never read back as truth, and it is cleared whenever a save
loads (`kPreLoadGame`, `kNewGame`), so it can't show one save's values in
another.

- **Opening** sends the page whatever the model holds, at once. On the first
  open after a load that is nothing, and the page says it is reading.
- **Then the DLL asks Papyrus to refresh it**, with the ModEvent
  `SNRom_DashboardRefresh`: `strArg` is `full` (the first open after a load) or
  `numbers`, and `numArg` is the refresh's generation. `SNRom_Bridge`'s
  `OnDashboardRefresh` calls `PutRefreshFacts` once, then pushes one
  `PutBondNumbers` per roster member, and on `full` one `PutBondText` each and
  one `PutPlaythrough`, then calls `RefreshDone`. The field order of both arrays
  is defined in `src/Model.h` and in `SNRom_Bridge.DashboardNumbers` /
  `DashboardText`, each citing the other.
- **Tier notices wait until the player can see them** (`src/Notices.h`).
  `SNRom_Bridge.AnnounceTier` words a tier change and posts it through
  `Announce`; the DLL holds it while the player is in combat, in an OStim or
  SexLab scene (their scene factions, by plugin-local FormID), in dialogue, on
  a loading screen or paused, looks again about once a second while anything
  waits, and sends `SNRom_ShowNotice` back for Papyrus to show. Nothing runs
  while nothing waits; a load drops what was waiting. Each hold is logged with
  its first reason, and each notice when it is shown.
- **Who can observe the player** (`ObserversNear`, version 6): the enrolled
  characters - in `SNRom_Bond` - whom the game keeps loaded near the player,
  alive and within a range, from the high process list in one call.
  `SNRom_Bridge.Observers` takes it once a tick, and the talk, spark and drift
  assessors pick from it instead of walking the roster (design 3.2: following
  is not a qualifier). A walk asked several frame-bound questions per
  character; this is one frame.
- **What moved each bond is the DLL's own** (`src/History.h`): the last 12
  changes per bond, recorded by `SNRom_Bridge.ApplyDepth` through
  `RecordChange` and kept in the SKSE co-save (record `HIST`, unique id
  `SNRH`), so loading an older save rolls the history back with the points.
  Every snapshot carries it as `bond.history`; no refresh pushes it.
- **A refresh makes no per-bond call that waits a frame** (design 7.3, measured
  in play: the first version took 55 seconds for 122 bonds). Per bond, Papyrus
  reads StorageUtil only - the points included, which are the mod's own from
  WP4 (`PointsOf`); the tier comes from the points. On a full refresh it also reads the text from the JsonUtil
  store, keyed by the form id it gets from `FormIdOf`, which answers without
  waiting where `GetFormID` may not. The DLL reads what the engine knows itself when it builds a
  snapshot: teammate, `CurrentFollowerFaction` and `PlayerMarriedFaction`
  membership, loaded, child, the name and the player's sex. What other mods
  know arrives once per refresh in `PutRefreshFacts`: MARAS's married, engaged
  and candidate lists, and SeverActions' active and dead tracked followers.
- **When `RefreshDone` arrives** for the refresh the DLL is waiting on, it sends
  the page the snapshot, writes the same snapshot to
  `SkyrimNetRelationships.snapshot.json` beside its log, and logs
  `Roster refreshed: <n> bonds (<full|numbers>) in <ms> ms`. That time runs from
  the ModEvent to `RefreshDone`, and it decides whether a refresh on every open
  stays after WP4.
- **Stale and missing answers.** An answer to any other refresh is ignored,
  and so is anything pushed for a refresh asked before the last load. No answer
  within 10 seconds is logged once, and the page gets a notice; a late answer is
  still taken. Papyrus answering `not ready` shows as that, not as an empty
  roster. `snapshot.roster.status` carries which of these the page is looking
  at.
- **Text between opens.** After a full refresh, Papyrus's text writers push
  what they change (`PutBondText`, generation 0), and an open dashboard shows it
  at once.

### Display copies, on probation

`src/Display.cpp` works out, **for display only**, what `IsFollowing`,
`CommitmentState` (with `IsMarriedToPlayer`) and `RomanceApplicability` answer,
from those facts. Each quotes its Papyrus original line for line, and each
original cites its copy; change one, change both. The gates keep calling
Papyrus. The copies stay only while the developer tool "Check the display
against the rules" finds no disagreement; in 2.0 the aim is one definition, with
the gates calling the native.

### Actions

The page asks; the DLL's fixed op table (`src/Dashboard.cpp`) decides whether
Papyrus hears about it. Unknown ops and bad arguments are refused at once, and so
are the developer tools unless the developer view is on. Papyrus refuses those
again by reading the setting itself, because a page can be edited.
`EnrollActor` stays `Not wired yet.` until WP7.

- What passes goes to Papyrus as the ModEvent `SNRom_DashboardAction`: `strArg`
  is the op, `numArg` the request id, and the actor is the event's sender form.
  `SNRom_Bridge.OnDashboardAction` maps the op again through its own table, gets
  any Int arguments from `SNRom_Native.ActionArgs`, and does it.
- It pushes the actor's row, then calls `ActionDone`. The DLL answers the page
  and sends a fresh snapshot.
- A re-read, re-author or preference repair answers that it has **started**. Its
  LLM callback pushes the row when it lands, and the DLL tells the page it has
  finished.
- No answer in 10 seconds is reported to the page, and a late answer arrives as a
  notice. Loading a save answers anything still waiting.
- **The re-read works for anyone** from WP4. Before it, Romantasy moved points
  only for an active follower, so a re-read of anyone else changed nothing and
  was refused; the points are the mod's own now.
- **"Check the display against the rules"** (developer view, playthrough
  repairs) runs the real `IsFollowing`, `CommitmentState` and
  `RomanceApplicability` for every bond and hands each answer to `CheckBond`,
  which compares it with the display copy worked out from fresh facts and logs
  every disagreement. About a minute with 120 bonds. The page is answered at
  once and gets the count as a notice.

The page protocol, including the window-function names, is documented at the top
of `ui/relationships/bridge.js`.
