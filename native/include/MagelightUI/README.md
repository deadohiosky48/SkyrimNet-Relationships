# Magelight UI public API header (vendored, unmodified)

`MagelightUI_API.h` is copied **unmodified** from Magelight UI's repository:

- Repository: `https://github.com/Severause/MagelightUI`
- File: `api/MagelightUI_API.h`
- Tag: `v0.30.5`, the release SeverActions 4.2.0 bundles

Magelight UI is **MIT licensed** (`LICENSE` beside it): the header may ship
inside this mod's source with that notice kept. It is left unedited anyway, so
a newer copy can replace it whole.

Our adapter, `native/src/MagelightHost.cpp`, uses the v4 interface and asks for
host 0.30.5 or newer (`minHostVersion`): v4 has been served since 0.10.0, and
`PostGameTask`, which the adapter needs, since 0.30.1. We never ship
`Magelight.dll`: players have it through SeverActions 4.x, or install it
themselves.
