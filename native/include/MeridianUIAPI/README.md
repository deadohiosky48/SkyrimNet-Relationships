# Meridian UI public API headers (vendored, MIT)

These three headers and `LICENSE-MIT` are copied **unmodified** from Meridian UI's
public API folder:

- Repository: `https://github.com/heathbrownkeyworks/MeridianUI`
- Folder: `src/UIPlatform/MeridianUIAPI/`
- Commit: `5707877322c85a1bd1c2e3309487f266d0647ca9` (2026-09-10, Meridian UI 1.5.0)

| file | what we use it for |
|---|---|
| `ViewDllLoader.h` | `Meridian::UI::View::Query`, which finds a running `MeridianUI.dll` and asks it for `Meridian.View/1` |
| `ViewAPI.h` | `IViewAPI`: create, listen, execute JavaScript, show, focus, hide |
| `Settings.h` | the `Settings` struct `Query` takes; `ViewAPI.h` includes it |

They are MIT-licensed; `LICENSE-MIT` beside them is that license and must stay
with them. Meridian UI's implementation is `GPL-3.0-or-later`, and **nothing
else from Meridian UI or Romantasy may be copied into this repository** (design
section 1). Our adapter, `native/src/MeridianHost.cpp`, is written from these
headers and Meridian's public author guide only.

To update: copy the same three files and the license from a newer commit, change
the commit above, and never edit them in place. A local change would be lost on
the next copy and would make "unmodified" untrue.
