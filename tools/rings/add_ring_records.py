"""Add (or refresh) the ring records in SNRom_Integration.esl.

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

# (FormID of the ARMO, of its ARMA, EditorID stem, name, worn model, ground model, enchantment)
RINGS = [
    (0xD66, 0xD65, 'SNRom_EngagementRingGold', 'Gold Engagement Ring',
     r'Relationships\Rings\EngagementRingGold.nif', r'Relationships\Rings\EngagementRingGoldGO.nif', 0xD6A),
    (0xD68, 0xD67, 'SNRom_WeddingRingGold', 'Gold Wedding Ring',
     r'Relationships\Rings\WeddingRingGold.nif', r'Relationships\Rings\WeddingRingGoldGO.nif', 0xD6B),
]

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

# The enchantments (the author, 2026-10-18: option B). Each effect is
# (effect, magnitude, together), where "together" holds only while husband
# and wife are together: for an NPC wearer, the player within 2048 units; for
# the player, a spouse here (SPOUSE_HERE).
ENCHANTMENTS = [
    (0xD6A, 'SNRom_EnchEngagementPromise', 'A Promise Kept', [(FORTIFY_HEALTH, 15.0, False)]),
    (0xD6B, 'SNRom_EnchMarasGrace', "Mara's Grace", [(FORTIFY_RESTORATION, 10.0, False),
                                                     (FORTIFY_HEAL_RATE, 10.0, False),
                                                     (FORTIFY_HEALTH, 25.0, True)]),
]

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


def make_armo(header, body, form_id, arma_id, edid, name, ground, ench_id):
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
    new = {'ARMO': [], 'ARMA': [], 'GLOB': [], 'ENCH': []}
    ours = set()
    glob_id = own | SPOUSE_HERE[0]
    new['GLOB'].append(make_global(glob_id, SPOUSE_HERE[1]))
    ours.add(glob_id)
    for ench_id, edid, name, effects in ENCHANTMENTS:
        new['ENCH'].append(make_ench(own | ench_id, edid, name, effects, glob_id))
        ours.add(own | ench_id)
    for armo_id, arma_id, edid, name, worn, ground, ench_id in RINGS:
        assert 0x800 <= armo_id <= 0xFFF and 0x800 <= arma_id <= 0xFFF, 'ESL FormIDs are 0x800-0xFFF'
        new['ARMA'].append(make_arma(arma_h, arma_b, own | arma_id, edid, worn))
        new['ARMO'].append(make_armo(armo_h, armo_b, own | armo_id, own | arma_id, edid, name, ground, own | ench_id))
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
