"""Add (or refresh) the marriage records in SNRom_Integration.esl: the rings,
their enchantments, and the factions the marriage actions' eligibility reads.

    python tools/rings/add_ring_records.py <Skyrim.esm> <SNRom_Integration.esl>

Each ring is a copy of vanilla's gold diamond ring (ARMO JewelryRingGoldDiamond,
0x000877C9) and its armor addon (ARMA RingGoldDiamondAA, 0x0008E83C): the same
slot, keywords, races, value and weight, with our models and names. Vanilla's
addon has a male model only, so rings never show on women; ours sets the male
and female models, third person and first.

Idempotent: records with our EditorIDs are replaced, so running it again after
a change to RINGS rewrites them. ESL: every FormID is in 0x800-0xFFF.
"""
import struct
import sys
import zlib

VANILLA_ARMO = 0x000877C9
VANILLA_ARMA = 0x0008E83C

# THE RINGS (2.5). Each shape in three metals (the author, 2026-10-20): the
# resource's engagement ring, its wedding ring (the engagement ring with its
# band, made only at a wedding), its band alone, and the wide plain band we
# make ourselves (build_rings.py), traditionally a man's. Values are base values
# before the enchantment, about vanilla's (its gold diamond ring is 900):
# silver lower, ebony higher. FormIDs: the gold engagement and wedding rings and
# the gold band kept their first ones; the rest run from 0xD75.
ENGAGEMENT_ENCH, WEDDING_ENCH = 0xD6A, 0xD6B
# (ARMO, ARMA, EditorID, name, model stem, metal, enchantment, value)
RING_TABLE = [
    (0xD66, 0xD65, 'SNRom_EngagementRingGold', 'Gold Engagement Ring', 'EngagementRing', 'Gold', ENGAGEMENT_ENCH, 900),
    (0xD76, 0xD75, 'SNRom_EngagementRingSilver', 'Silver Engagement Ring', 'EngagementRing', 'Silver', ENGAGEMENT_ENCH, 550),
    (0xD78, 0xD77, 'SNRom_EngagementRingEbony', 'Ebony Engagement Ring', 'EngagementRing', 'Ebony', ENGAGEMENT_ENCH, 1500),
    (0xD68, 0xD67, 'SNRom_WeddingRingGold', 'Gold Wedding Ring', 'WeddingRing', 'Gold', WEDDING_ENCH, 1200),
    (0xD7A, 0xD79, 'SNRom_WeddingRingSilver', 'Silver Wedding Ring', 'WeddingRing', 'Silver', WEDDING_ENCH, 750),
    (0xD7C, 0xD7B, 'SNRom_WeddingRingEbony', 'Ebony Wedding Ring', 'WeddingRing', 'Ebony', WEDDING_ENCH, 1900),
    (0xD74, 0xD73, 'SNRom_WeddingBandGold', 'Gold Wedding Band', 'WeddingBand', 'Gold', WEDDING_ENCH, 300),
    (0xD7E, 0xD7D, 'SNRom_WeddingBandSilver', 'Silver Wedding Band', 'WeddingBand', 'Silver', WEDDING_ENCH, 180),
    (0xD80, 0xD7F, 'SNRom_WeddingBandEbony', 'Ebony Wedding Band', 'WeddingBand', 'Ebony', WEDDING_ENCH, 550),
    (0xD82, 0xD81, 'SNRom_WideBandGold', 'Wide Gold Wedding Band', 'WideBand', 'Gold', WEDDING_ENCH, 400),
    (0xD84, 0xD83, 'SNRom_WideBandSilver', 'Wide Silver Wedding Band', 'WideBand', 'Silver', WEDDING_ENCH, 240),
    (0xD86, 0xD85, 'SNRom_WideBandEbony', 'Wide Ebony Wedding Band', 'WideBand', 'Ebony', WEDDING_ENCH, 700),
]
RINGS = [(armo, arma, edid, name, 'Relationships\\Rings\\' + stem + metal + '.nif',
          'Relationships\\Rings\\' + stem + metal + 'GO.nif', ench, value)
         for armo, arma, edid, name, stem, metal, ench, value in RING_TABLE]

# A spouse is here with the player: 1 or 0, kept by the DLL (Rings.cpp) on
# every change of the player's location and of a marriage. What the wedding
# ring's "together" effect asks when the player wears it.
SPOUSE_HERE = (0xD69, 'SNRom_SpouseHere')

# Vanilla's constant-effect enchantment effects (Skyrim.esm), and the keyword
# that stops a ring being disenchanted.
FORTIFY_HEALTH = 0x000493AA       # EnchFortifyHealthConstantSelf
FORTIFY_HEAL_RATE = 0x0007A0F8    # EnchFortifyHealRateConstantSelf
FORTIFY_RESTORATION = 0x0007A101  # EnchFortifyRestorationConstantSelf
NO_DISENCHANT = 0x000C27BD        # MagicDisallowEnchanting
PLAYER_REF = 0x00000014

# OUR OWN EFFECTS, copies of vanilla's with our names and words. The item card
# shows an effect's description, never an enchantment's name (in game,
# 2026-10-18: "Increases Health by 15 points", no "A Promise Kept"), so the
# wording has to live here. <mag> is the game's own placeholder.
# (FormID, vanilla effect copied, EditorID, name, description)
EFFECTS = [
    (0xD6C, FORTIFY_HEALTH, 'SNRom_MgefPromiseHealth', "Mara's Promise",
     "Mara's Promise: Health is increased by <mag> points."),
    (0xD6D, FORTIFY_RESTORATION, 'SNRom_MgefGraceRestoration', "Mara's Grace",
     "Mara's Grace: Restoration spells cost <mag>% less to cast."),
    (0xD6E, FORTIFY_HEAL_RATE, 'SNRom_MgefGraceHealRate', "Mara's Grace",
     "Mara's Grace: Health regenerates <mag>% faster."),
    (0xD6F, FORTIFY_HEALTH, 'SNRom_MgefGraceTogether', 'Together',
     'Together: Health is increased by <mag> more points while you are with your spouse.'),
]

# The enchantments (the author, 2026-10-18: option B). Each effect is
# (effect, magnitude, together), where "together" holds only while husband
# and wife are together: for an NPC wearer, the player within 2048 units; for
# the player, a spouse here (SPOUSE_HERE).
# Effects by our local FormID (EFFECTS above).
ENCHANTMENTS = [
    (0xD6A, 'SNRom_EnchEngagementPromise', "Mara's Promise", [(0xD6C, 15.0, False)]),
    (0xD6B, 'SNRom_EnchMarasGrace', "Mara's Grace", [(0xD6D, 10.0, False),
                                                     (0xD6E, 10.0, False),
                                                     (0xD6F, 25.0, True)]),
]

# FACTIONS FOR ELIGIBILITY. SkyrimNet's eligibility rules evaluate
# get_faction_rank, not our own decorators (measured 2026-10-17), so the DLL
# keeps what the marriage actions need as faction ranks:
# - SNRom_Marriage: the actor's marriage to the player, rank = the state's
#   number (Marriage.h), -1 for none (Marriage.cpp, SyncFaction);
# - SNRom_Ceremony: the step of the wedding under way (Ceremony.cpp);
# - SNRom_Officiant: rank 0 on every priest, priestess and jarl, put on their
#   records at kDataLoaded (Officiant.cpp, MarkAll), since vanilla lists jarls
#   in JobJarlFaction at rank -1, which reads as not a member.
# - SNRom_WeddingPlanner: rank 0 on the wedding planners (Build B).
# (FormID, EditorID, name, rank titles from 0)
FACTIONS = [
    (0xD70, 'SNRom_Marriage', 'Relationships Marriage',
     ['None', 'Engaged', 'Married', 'Broken Off', 'Divorced', 'Widowed', 'Separated']),
    (0xD71, 'SNRom_Officiant', 'Relationships Officiant', ['Officiant']),
    # The wedding under way (Ceremony.h): its step, on the officiant and the
    # betrothed; -1 when none.
    (0xD72, 'SNRom_Ceremony', 'Relationships Ceremony', ['None', 'Opening', 'Player Vows', 'Betrothed Vows',
                                                          'Asking the Player', 'Player Answers',
                                                          'Asking the Betrothed', 'Betrothed Answers',
                                                          'Pronouncing', '', 'Address', 'Reading',
                                                          'Rings']),
    # Build B (M4p): the wedding planners, rank 0, put on their records at
    # kDataLoaded (Officiant.cpp, MarkPlanners).
    (0xD87, 'SNRom_WeddingPlanner', 'Relationships Wedding Planner', ['Planner']),
]


# THE WEDDING PLANNER'S BOOK (Build B; the author, 2026-10-25). Planning is
# by conversation, so the choices are set down here, given when a planner is
# hired (SNRom_Bridge.HireWeddingPlanner). Its model and art are The Dowry's;
# its text ours. The officiants are listed by hand (Skyrim.esm's names live in
# its string tables, not the plugin); the DLL logs any name here that is not an
# officiant it knows (Officiant.cpp, kBookOfficiants), and the planner accepts
# any priest, priestess or jarl by name besides. THE JARLS BY HOLD (wpm48; the
# author, 2026-10-26): who rules a hold depends on the civil war, so the book
# names the hold, and the DLL finds whoever rules it (Officiant.cpp, kHolds).
# LAYOUT (the author's read in play, 2026-10-26): every paragraph in its own
# <p>, since a paragraph that ran onto the next page took the title's
# centring there; a [pagebreak] wherever one would otherwise split; and lists
# of short lines under centred headings, since a list item that wrapped could
# not be told from the next. AND THE BOOK MENU CENTRES THE FIRST PARAGRAPH OF
# EVERY PAGE, whatever its <p> says (seen in play, wpm48): a page that opens
# with body text opens with an empty line inside its <p align="left">, which
# takes the centring, as other mods' books do.
VANILLA_BOOK = 0x0001ACF2   # Book3ValuableTheDowry
BOOKS = [
    (0xD88, 'SNRom_WeddingPlannerBook', "A Wedding Planner's Book", 25),
]
BOOK_TEXT = """<p align="center"><font size='40'>A Wedding Planner's Book</font></p>
<p align="center">Kept by the planners of the temples of Skyrim</p>

<p align="left">Everything a wedding can hold is set down here, with the choices for each.</p>
[pagebreak]
<p align="left">
Read it at your leisure, then tell your planner, or the one you are to marry, what you want.</p>

<p align="left">Nothing is settled until you say it, and anything can be changed the same way.</p>
[pagebreak]
<p align="center"><font size='30'>The Day</font></p>

<p align="left">Choose a day, and a time: morning, noon, afternoon, evening or night. Your planner will see that everyone knows it.</p>

<p align="left">If the day will not do after all, say so before it comes, and another is set. There is no shame in that.</p>
[pagebreak]
<p align="left">
A wedding missed without a word is another matter.</p>

<p align="left">On the day, those who are coming make their way to the place a few hours ahead. Be there in good time; you will be waited for, but not forever.</p>
[pagebreak]
<p align="center"><font size='30'>The Place</font></p>

<p align="left">Any place you can both walk to, and that means something to you. Among those often chosen, city by city:</p>

<p align="center">Riften</p>
<p align="left">The Temple of Mara
Mistveil Keep</p>
[pagebreak]
<p align="center">Solitude</p>
<p align="left">The Temple of the Divines
The Blue Palace</p>
<p align="center">Whiterun</p>
<p align="left">The Temple of Kynareth
Dragonsreach</p>
<p align="center">Markarth</p>
<p align="left">The Temple of Dibella
Understone Keep</p>
<p align="center">Windhelm</p>
<p align="left">The Temple of Talos
The Palace of the Kings</p>
[pagebreak]
<p align="center"><font size='30'>Who Marries You</font></p>

<p align="left">Any priest or priestess of Skyrim. Your planner sends word, and they come on the day.</p>

<p align="center">Of Mara, in Riften</p>
<p align="left">Maramal
Dinya Balu</p>
[pagebreak]
<p align="center">Of the Divines, in Solitude</p>
<p align="left">Rorlund
Silana Petreia
Freir</p>

<p align="center">Of Kynareth, in Whiterun</p>
<p align="left">Danica Pure-Spring</p>

<p align="center">Of Dibella, in Markarth</p>
<p align="left">Hamal
Senna</p>
[pagebreak]
<p align="center">Of Talos, in Windhelm</p>
<p align="left">Jora
Lortheim</p>

<p align="center">Of Arkay</p>
<p align="left">Andurs, in Whiterun
Styrr, in Solitude
Brother Verulus, in Markarth
Helgird, in Windhelm
Runil, in Falkreath</p>
[pagebreak]
<p align="center"><font size='30'>The Jarls</font></p>

<p align="left">Or the jarl of any hold. Name the hold; whoever holds its hall on the day is the one who comes.</p>
[pagebreak]
<p align="left">
The Jarl of Whiterun
The Jarl of Solitude
The Jarl of Windhelm
The Jarl of Riften
The Jarl of Markarth
The Jarl of Falkreath
The Jarl of Morthal
The Jarl of Dawnstar
The Jarl of Winterhold</p>
[pagebreak]
<p align="center"><font size='30'>The Guests</font></p>

<p align="left">Anyone you know: friends, family, companions of the road. Name them, and each is told.</p>

<p align="left">Each decides for themselves whether to come; those who do will keep their places until you are wed.</p>
[pagebreak]
<p align="center"><font size='30'>The Ceremony</font></p>

<p align="left">At its heart, always: your vows, then each of you asked, "Do you take...?", then the pronouncement.</p>
<p align="left">Beyond that, by your choice:</p>
<p align="left">An address to all gathered
A reading, or a blessing
The rings exchanged
The kiss</p>

<p align="left">All four, unless you say otherwise.</p>
[pagebreak]
<p align="center"><font size='30'>The Rings</font></p>

<p align="left">For the one you marry: a wedding ring, the engagement ring and its band together, in gold, silver or ebony.</p>

<p align="left">For you: a band, in gold, silver or ebony, wide and plain, or braided.</p>

<p align="left">They are made for the wedding, and put on during it.</p>
[pagebreak]
<p align="center"><font size='30'>What You Wear</font></p>

<p align="left">Ask the one you marry to choose what they will wear; they will keep it for the day.</p>

<p align="left">What you wear is yours to choose; do not leave it to the morning.</p>
"""


def make_book(header, body, form_id, edid, name, value):
    out = b''
    for t, d in subrecords(body):
        if t == 'EDID':
            out += pack_sub('EDID', zstr(edid))
        elif t == 'FULL':
            out += pack_sub('FULL', zstr(name))
        elif t == 'DESC':
            out += pack_sub('DESC', zstr(BOOK_TEXT))
        elif t == 'DATA':
            # flags, type, unused, teaches (none), value, weight.
            weight = struct.unpack_from('<f', d, 12)[0] if len(d) >= 16 else 1.0
            out += pack_sub('DATA', struct.pack('<BBHiIf', 0, 0, 0, -1, value, weight))
        elif t in ('VMAD', 'CNAM'):
            continue   # no scripts; CNAM is a localized string id in Skyrim.esm
        else:
            out += pack_sub(t, d)
    return record(header, form_id, out)


def make_fact(form_id, edid, name, ranks):
    # As SNRom_Bond is: no flags, no crime values, no vendor.
    body = (pack_sub('EDID', zstr(edid)) + pack_sub('FULL', zstr(name)) + pack_sub('DATA', bytes(4)) +
            pack_sub('CRVA', bytes([1, 1]) + bytes(18)))
    for i, title in enumerate(ranks):
        body += pack_sub('RNAM', struct.pack('<I', i)) + pack_sub('MNAM', zstr(title)) + pack_sub('FNAM', zstr(title))
    body += pack_sub('VENV', bytes(12))
    return raw_record('FACT', form_id, body)


# The game reads top-level groups in this order (UESP, TES5 Mod: Mod File Format).
GROUP_ORDER = ('GMST KYWD LCRT AACT TXST GLOB CLAS FACT HDPT HAIR EYES RACE SOUN ASPC MGEF SCPT LTEX ENCH SPEL '
               'SCRL ACTI TACT ARMO BOOK CONT DOOR INGR LIGH MISC APPA STAT SCOL MSTT PWAT GRAS TREE CLDC FLOR '
               'FURN WEAP AMMO NPC_ LVLN KEYM ALCH IDLM COBJ PROJ HAZD SLGM LVLI WTHR CLMT SPGD RFCT REGN NAVI '
               'CELL WRLD DIAL QUST IDLE PACK CSTY LSCR LVSP ANIO WATR EFSH EXPL DEBR IMGS IMAD FLST PERK BPTD '
               'ADDN AVIF CAMS CPTH VTYP MATT IPCT IPDS ARMA ECZN LCTN MESG RGDL DOBJ LGTM MUSC FSTP FSTS SMBN '
               'SMQN SMEN DLBR MUST DLVW WOOP SHOU EQUP RELA SCEN ASTP OTFT ARTO MATO MOVT SNDR DUAL SNCT SOPM '
               'COLL CLFM REVB').split()


def subrecords(body):
    p = 0
    while p + 6 <= len(body):
        t = body[p:p + 4].decode('latin1')
        sz = struct.unpack_from('<H', body, p + 4)[0]
        yield t, body[p + 6:p + 6 + sz]
        p += 6 + sz


def pack_sub(t, data):
    return t.encode('latin1') + struct.pack('<H', len(data)) + data


def zstr(text):
    return text.encode('cp1252') + b'\0'


def find_record(data, form_id):
    """(header bytes, decompressed body) of a record anywhere in a plugin."""
    def walk(off, end):
        while off < end:
            typ = data[off:off + 4]
            size = struct.unpack_from('<I', data, off + 4)[0]
            if typ == b'GRUP':
                hit = walk(off + 24, off + size)
                if hit:
                    return hit
                off += size
                continue
            flags, fid = struct.unpack_from('<II', data, off + 8)
            if fid == form_id:
                body = data[off + 24:off + 24 + size]
                if flags & 0x40000:
                    body = zlib.decompress(body[4:])
                return data[off:off + 24], body
            off += 24 + size
        return None
    hs = struct.unpack_from('<I', data, 4)[0]
    return walk(24 + hs, len(data))


def record(header, form_id, body):
    """A record with vanilla's header fields, our FormID, uncompressed."""
    typ = header[:4]
    rest = bytearray(header[16:24])
    return typ + struct.pack('<III', len(body), 0, form_id) + bytes(rest) + body


def raw_record(typ, form_id, body):
    """A record of our own: uncompressed, form version 44 as the CK writes."""
    return typ.encode('latin1') + struct.pack('<III', len(body), 0, form_id) + struct.pack('<IHH', 0, 44, 0) + body


def make_global(form_id, edid):
    body = pack_sub('EDID', zstr(edid)) + pack_sub('FNAM', b's') + pack_sub('FLTV', struct.pack('<f', 0.0))
    return raw_record('GLOB', form_id, body)


def ctda(op, function, param1, value, or_next=False):
    """A condition on the wearer (run on Subject). op: 0 ==, 1 !=, 4 <."""
    kind = (op << 5) | (0x01 if or_next else 0)
    return pack_sub('CTDA', struct.pack('<B3xfHHIIIIi', kind, value, function, 0, param1, 0, 0, 0, -1))


GET_DISTANCE = 1
GET_GLOBAL_VALUE = 74
GET_IS_REFERENCE = 136


def together(global_id):
    """Husband and wife are together. Skyrim reads ORs before ANDs, so this is
    (player OR player within 2048) AND (not player OR a spouse here): for an
    NPC wearer, the player near; for the player, SNRom_SpouseHere."""
    return (ctda(0, GET_IS_REFERENCE, PLAYER_REF, 1.0, or_next=True) +
            ctda(4, GET_DISTANCE, PLAYER_REF, 2048.0) +
            ctda(0, GET_IS_REFERENCE, PLAYER_REF, 0.0, or_next=True) +
            ctda(0, GET_GLOBAL_VALUE, global_id, 1.0))


def make_ench(form_id, edid, name, effects, global_id):
    # ENIT as vanilla's armour enchantments have it (EnchArmorFortifyHealth01):
    # constant effect on self, an "enchantment", worn-restricted to armour.
    enit = struct.pack('<IIIIIIfII', 202, 0, 0, 202, 0, 6, 0.0, 0, 0x0010FB77)
    body = (pack_sub('EDID', zstr(edid)) + pack_sub('OBND', bytes(12)) + pack_sub('FULL', zstr(name)) +
            pack_sub('ENIT', enit))
    for effect, magnitude, only_together in effects:
        body += pack_sub('EFID', struct.pack('<I', effect)) + pack_sub('EFIT', struct.pack('<fII', magnitude, 0, 0))
        if only_together:
            body += together(global_id)
    return raw_record('ENCH', form_id, body)


def make_mgef(header, body, form_id, edid, name, description):
    out = b''
    for t, v in subrecords(body):
        if t == 'EDID':
            out += pack_sub('EDID', zstr(edid))
        elif t == 'FULL':
            out += pack_sub('FULL', zstr(name))           # this plugin is not localized
        elif t == 'DNAM':
            out += pack_sub('DNAM', zstr(description))
        else:
            out += pack_sub(t, v)
    return record(header, form_id, out)


def make_arma(header, body, form_id, edid, worn):
    out = b''
    for t, v in subrecords(body):
        if t == 'EDID':
            out += pack_sub('EDID', zstr(edid + 'AA'))
        elif t in ('MO2T', 'MO3T', 'MO4T', 'MO5T', 'MOD3', 'MOD4', 'MOD5'):
            continue
        elif t == 'MOD2':
            # Male and female, third person and first: the same model, which is
            # skinned to the finger and so fits either skeleton.
            for m in ('MOD2', 'MOD3', 'MOD4', 'MOD5'):
                out += pack_sub(m, zstr(worn))
        else:
            out += pack_sub(t, v)
    return record(header, form_id, out)


def make_armo(header, body, form_id, arma_id, edid, name, ground, ench_id, value):
    out = b''
    for t, v in subrecords(body):
        if t == 'EDID':
            out += pack_sub('EDID', zstr(edid))
        elif t == 'FULL':
            out += pack_sub('FULL', zstr(name))   # this plugin is not localized
            out += pack_sub('EITM', struct.pack('<I', ench_id))
        elif t == 'KSIZ':
            out += pack_sub('KSIZ', struct.pack('<I', struct.unpack('<I', v)[0] + 1))
        elif t == 'KWDA':
            out += pack_sub('KWDA', v + struct.pack('<I', NO_DISENCHANT))
        elif t == 'MOD2':
            out += pack_sub('MOD2', zstr(ground))
        elif t in ('MO2T', 'MOD4', 'MO4T'):
            continue
        elif t == 'MODL':
            out += pack_sub('MODL', struct.pack('<I', arma_id))
        elif t == 'DESC':
            out += pack_sub('DESC', struct.pack('<I', 0))
        elif t == 'DATA':
            out += pack_sub('DATA', struct.pack('<i', value) + v[4:])   # value, then vanilla's weight
        else:
            out += pack_sub(t, v)
    return record(header, form_id, out)


def main(esm_path, esl_path):
    esm = open(esm_path, 'rb').read()
    esl = bytearray(open(esl_path, 'rb').read())
    armo_h, armo_b = find_record(esm, VANILLA_ARMO)
    arma_h, arma_b = find_record(esm, VANILLA_ARMA)

    # Our own records are master index 1 (Skyrim.esm is 0).
    own = 0x01000000
    new = {'ARMO': [], 'ARMA': [], 'GLOB': [], 'ENCH': [], 'MGEF': [], 'FACT': [], 'BOOK': []}
    ours = set()
    for fact_id, edid, name, ranks in FACTIONS:
        assert 0x800 <= fact_id <= 0xFFF, 'ESL FormIDs are 0x800-0xFFF'
        new['FACT'].append(make_fact(own | fact_id, edid, name, ranks))
        ours.add(own | fact_id)
    for mgef_id, vanilla, edid, name, description in EFFECTS:
        mh, mb = find_record(esm, vanilla)
        new['MGEF'].append(make_mgef(mh, mb, own | mgef_id, edid, name, description))
        ours.add(own | mgef_id)
    book_h, book_b = find_record(esm, VANILLA_BOOK)
    for book_id, edid, name, value in BOOKS:
        assert 0x800 <= book_id <= 0xFFF, 'ESL FormIDs are 0x800-0xFFF'
        new['BOOK'].append(make_book(book_h, book_b, own | book_id, edid, name, value))
        ours.add(own | book_id)
    glob_id = own | SPOUSE_HERE[0]
    new['GLOB'].append(make_global(glob_id, SPOUSE_HERE[1]))
    ours.add(glob_id)
    for ench_id, edid, name, effects in ENCHANTMENTS:
        effects = [(own | e, magnitude, together_only) for e, magnitude, together_only in effects]
        new['ENCH'].append(make_ench(own | ench_id, edid, name, effects, glob_id))
        ours.add(own | ench_id)
    for armo_id, arma_id, edid, name, worn, ground, ench_id, value in RINGS:
        assert 0x800 <= armo_id <= 0xFFF and 0x800 <= arma_id <= 0xFFF, 'ESL FormIDs are 0x800-0xFFF'
        new['ARMA'].append(make_arma(arma_h, arma_b, own | arma_id, edid, worn))
        new['ARMO'].append(make_armo(armo_h, armo_b, own | armo_id, own | arma_id, edid, name, ground, own | ench_id,
                                     value))
        ours.update({own | armo_id, own | arma_id})

    # Split the plugin into its header and its top-level groups, dropping any
    # of our ring records from a previous run.
    hs = struct.unpack_from('<I', esl, 4)[0]
    header = bytes(esl[:24 + hs])
    groups = {}
    off = 24 + hs
    while off < len(esl):
        size = struct.unpack_from('<I', esl, off + 4)[0]
        label = esl[off + 8:off + 12].decode('latin1')
        body = bytes(esl[off + 24:off + size])
        kept = b''
        p = 0
        while p < len(body):
            rsize = struct.unpack_from('<I', body, p + 4)[0]
            fid = struct.unpack_from('<I', body, p + 12)[0]
            if fid not in ours:
                kept += body[p:p + 24 + rsize]
            p += 24 + rsize
        groups[label] = (bytes(esl[off:off + 24]), kept)
        off += size
    for label, recs in new.items():
        gh, body = groups.get(label, (b'GRUP' + struct.pack('<I', 0) + label.encode() + struct.pack('<i', 0) + b'\0' * 8, b''))
        groups[label] = (gh, body + b''.join(recs))

    out = bytearray()
    count = 0
    for label in sorted(groups, key=lambda g: GROUP_ORDER.index(g)):
        gh, body = groups[label]
        gh = bytearray(gh)
        struct.pack_into('<I', gh, 4, 24 + len(body))
        out += gh + body
        count += 1
        p = 0
        while p < len(body):
            count += 1
            p += 24 + struct.unpack_from('<I', body, p + 4)[0]

    # HEDR: the number of records and groups.
    header = bytearray(header)
    p = 24
    while p < len(header):
        t = header[p:p + 4]
        sz = struct.unpack_from('<H', header, p + 4)[0]
        if t == b'HEDR':
            struct.pack_into('<I', header, p + 6 + 4, count)
        p += 6 + sz
    open(esl_path, 'wb').write(bytes(header) + bytes(out))
    print('wrote', esl_path, 'groups+records', count, 'bytes', len(header) + len(out))


if __name__ == '__main__':
    main(*sys.argv[1:3])
