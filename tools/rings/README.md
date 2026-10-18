# The rings

The Gold Engagement Ring and Gold Wedding Ring (2.5) are built from
**"Women's wedding ring and engagement ring combo modder's resource 3D model"**
by ModdersResources (Nexus Mods, Skyrim Special Edition, mod 60450). Its
permissions allow use of the assets without asking or crediting, outside paid
mods; Relationships credits it anyway.

Only the models are used. The resource's own textures are not: its page says
some of its assets belong to other authors, and the rings look like the rest of
Skyrim's jewellery with vanilla's ring sheet
(`textures\armor\amuletsandrings\Genericrings.dds`) and vanilla's ring shader.

## What is built

| File | What |
|---|---|
| `meshes\Relationships\Rings\EngagementRing<Metal>.nif` | worn: the engagement ring alone, skinned to the left ring finger (`NPC L Finger30 [LF30]`), partition 36 (ring) |
| `meshes\Relationships\Rings\EngagementRing<Metal>GO.nif` | on the ground, with vanilla's ring collision fitted to it |
| `meshes\Relationships\Rings\WeddingRing<Metal>.nif` | worn: the engagement ring with its band, the band nearer the hand |
| `meshes\Relationships\Rings\WeddingRing<Metal>GO.nif` | on the ground |

Male and female skeletons share their finger bones, so one worn model serves
both, in third person and first. Its hole (0.97 units) was measured against the
installed female and male hands (`measure_finger.py`): vanilla's 0.72 is sized
for vanilla's male fingers and disappears inside both.

## Rebuilding

Needs Blender 5.2 and PyNifly (BadDogSkyrim/PyNifly, 29.1.0) unpacked into an
add-ons folder of its own; nothing is installed into Blender's settings.

1. Extract the templates from the game's archives with `bsa_extract.py`:
   `meshes\armor\amuletsandrings\goldringdiamondgo.nif` and
   `goldringdiamond_1.nif` (Skyrim - Meshes0.bsa).
2. Run Blender in the background on the resource's `.blend` for the metal, with
   `BLENDER_USER_SCRIPTS` pointing at the PyNifly folder:
   `blender -b --factory-startup --disable-autoexec "Ring Gold.blend" --python build_rings.py -- <templates> <out> Gold <PyNifly>\skeletons\Skyrim`
3. Check them: `verify.py` (bones, partition, collision, shader, UVs) and
   `render_fit.py` (renders the worn ring on a hands mesh).
4. Copy the NIFs into `meshes\Relationships\Rings\`, and add or refresh the
   records with `add_ring_records.py <Skyrim.esm> SNRom_Integration.esl`.

`--disable-autoexec` matters: a `.blend` can carry Python that would otherwise
run when it opens.
