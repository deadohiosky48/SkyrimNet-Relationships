# The Relationships dashboard page

`relationships/` is the dashboard's web front-end: plain HTML, CSS and JS, with
no framework, no build step and nothing fetched from the network. The same
files run under Meridian UI and PrismaUI, and in an ordinary browser against
mock data.

| file | what |
|---|---|
| `relationships/bridge.js` | `window.snrom`, the only way the page talks to the game. **The window functions the DLL implements are documented at the top of this file.** |
| `relationships/snapshot.schema.json` | Everything the page renders, as one JSON document. Each field says where its value lives in Papyrus today. |
| `relationships/actions.js` | Every operation the page can ask for, and the `SNRom_Bridge` function each maps to. |
| `relationships/labels.js` | Every word shown for a number or an enum, including the tier names per track. |
| `relationships/mode.js` | Player mode, and the one switch for developer mode. |
| `relationships/display.js` | How big the page is drawn: the scale and the text size. |
| `relationships/mock/` | The mock host (`host.js`, with its MOCK HOST strip) and the invented snapshots it serves. Never shipped: `tools/package.ps1` stages the page without `mock/` and refuses if any of it turns up. |
| `tests/` | Headless tests and the mock generator. Development only. |

## Player mode and developer mode

The page opens in **player mode**. It shows what the player could know: depth,
points, track, traits, and only the states that have been spoken between them
(courting, declined, ended, foreclosed). It hides what a character has not
said: an unspoken spark, the spark date, a question they owe, points held or
banked while it waits, and the assessor's unspoken verdicts. A sparked but
unanswered bond reads as any other friendship.

**Developer mode** shows all of that, plus the developer tools in
`actions.js`, and says so in the header. The tools have their own labelled
places, never among a player's repairs: a **Developer tools…** button in the
footer for those about the whole playthrough, and a **Developer tools** section
in each person's detail for those about one person. It is one switch with three ways to
throw it: in game, the SkyrimNet setting `dashboardDeveloperView`, which arrives
in every snapshot as `settings.developer`; `?developer=1` on the URL in a
browser; or `DEVELOPER` in `mode.js`, which stays false in anything shipped.

## Scale, text size and wide screens

Two SkyrimNet settings size the page, and they arrive in every snapshot as
`settings.scale` and `settings.textSize`. SkyrimNet's settings screen and the
dashboard are never open together, so in play a change shows the next time
the dashboard opens. The page applies them from any snapshot, so the mock strip
can change them live.

- **Scale** (`dashboardScale`) sizes everything. It is the root font size, and
  every length in `style.css` is in rem. Auto follows the view's height, 1080
  lines being 100%, and stays between 75% and 200%.
- **Text size** (`dashboardTextSize`) is on top of the scale. It is `--t` in
  `style.css`: every font size, and every box sized to hold text, is
  multiplied by it; spacing is not. A new font size is written
  `calc(Nrem * var(--t))`.

The roster's columns are as wide as the widest thing each can show:
`roster.js` measures them (`fit`), from the whole vocabulary for the chip
columns and from the roster for the name and the points. `app.js` then decides
the layout (`layout`), since a media query can't see the scale. If the roster
at that width and the detail at its minimum both fit, they sit side by side:
the list keeps its width, the detail takes the rest up to its maximum, and past
that the panel sits centred with even margins. Otherwise the detail slides over
the roster.

In a browser, `?scale=125&text=large` sets them from the URL, and the mock strip
has a select for each.

## Roster status

In game the page opens at once with whatever the DLL last heard, and the DLL
then asks Papyrus for the roster again. `roster.status` in the snapshot says
where that stands: `reading`, `current`, `not ready` (with the game's reason) or
`no answer` (nothing within ten seconds). The page shows a line for anything
that isn't current, and an empty roster that isn't current never reads as
"nobody". Everything stays usable while it waits. The `reading`, `refreshing`,
`no-answer` and `not-ready` mocks show each one.

## Run it in a browser

The mock host loads `mock/*.json` with `fetch`, which browsers refuse from a
`file:` URL, so serve the folder over http. Either of these works:

```
npx http-server ui/relationships -p 8080
python -m http.server 8080 --directory ui/relationships
```

Then open `http://127.0.0.1:8080/index.html`. A strip at the bottom left picks
the mock; `?mock=states` picks one from the URL and `?devbar=0` hides the strip.
Actions are answered by the mock host the way Papyrus would answer them,
refusals included.

## Test it

```
cd ui/tests
npm install
npm test
```

The tests use the browser in `$CHROME_PATH` if that file exists, and otherwise
the Chromium Playwright manages (`npx playwright install chromium` fetches it
once). They render every mock at 1920x1080 and 1280x720, and the dev save at
1920x1080, 2560x1440, 3440x1440 and 5120x1440 at Auto and 150%. They send every action
through the mock host, drive a fake native host through the real window
functions, validate every snapshot against the schema, and fail on any console
error or any request that leaves the page. Screenshots land in
`tests/screenshots/`.

`npm run mocks` regenerates `relationships/mock/` from `tests/gen-mocks.mjs`.
Every name in the mocks is invented; never paste a real save's roster in.

## What the tests cannot tell you

They run in Chromium. Meridian embeds Chromium too, but PrismaUI renders with
Ultralight, so the first look under Prisma is a local check: scrolling a long
roster, focus outlines, and the dialog.
