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

# (FormID of the ARMO, of its ARMA, EditorID stem, name, worn model, ground model)
RINGS = [
    (0xD66, 0xD65, 'SNRom_EngagementRingGold', 'Gold Engagement Ring',
     r'Relationships\Rings\EngagementRingGold.nif', r'Relationships\Rings\EngagementRingGoldGO.nif'),
    (0xD68, 0xD67, 'SNRom_WeddingRingGold', 'Gold Wedding Ring',
     r'Relationships\Rings\WeddingRingGold.nif', r'Relationships\Rings\WeddingRingGoldGO.nif'),
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


def make_armo(header, body, form_id, arma_id, edid, name, ground):
    out = b''
    for t, v in subrecords(body):
        if t == 'EDID':
            out += pack_sub('EDID', zstr(edid))
        elif t == 'FULL':
            out += pack_sub('FULL', zstr(name))   # this plugin is not localized
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
    new = {'ARMO': [], 'ARMA': []}
    ours = set()
    for armo_id, arma_id, edid, name, worn, ground in RINGS:
        assert 0x800 <= armo_id <= 0xFFF and 0x800 <= arma_id <= 0xFFF, 'ESL FormIDs are 0x800-0xFFF'
        new['ARMA'].append(make_arma(arma_h, arma_b, own | arma_id, edid, worn))
        new['ARMO'].append(make_armo(armo_h, armo_b, own | armo_id, own | arma_id, edid, name, ground))
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
