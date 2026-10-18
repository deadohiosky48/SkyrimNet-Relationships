"""Extract named files from an SSE (v105) BSA. Reads only.
usage: bsa_extract.py <outdir> <bsa> <path-in-archive> [...]
Paths are matched case-insensitively with backslashes."""
import os
import struct
import sys

import lz4.frame

out, bsa, wanted = sys.argv[1], sys.argv[2], [w.lower().replace('/', '\\') for w in sys.argv[3:]]
f = open(bsa, 'rb')
magic, version, offset, flags, nfolders, nfiles, folder_names_len, file_names_len, file_flags = struct.unpack('<4sIIIIIIII', f.read(36))
assert magic == b'BSA\0' and version == 105, (magic, version)
has_dir_names = flags & 1
has_file_names = flags & 2
compressed_default = bool(flags & 4)
embed_names = bool(flags & 0x100)

folders = []
f.seek(offset)
for _ in range(nfolders):
    _hash, count, _pad, off = struct.unpack('<QIIQ', f.read(24))
    folders.append((count, off))

records = []  # (folder name, size, offset)
for count, off in folders:
    name = ''
    if has_dir_names:
        ln = f.read(1)[0]
        name = f.read(ln).rstrip(b'\0').decode('latin1')
    for _ in range(count):
        _hash, size, foff = struct.unpack('<QII', f.read(16))
        records.append([name, size, foff, None])

names = f.read(file_names_len).split(b'\0') if has_file_names else []
for rec, nm in zip(records, names):
    rec[3] = nm.decode('latin1')

found = 0
for folder, size, foff, nm in records:
    full = (folder + '\\' + nm).lower()
    if full not in wanted:
        continue
    compressed = compressed_default ^ bool(size & 0x40000000)
    size &= 0x3FFFFFFF
    f.seek(foff)
    if embed_names:
        ln = f.read(1)[0]
        f.read(ln)
        size -= ln + 1
    if compressed:
        _orig = struct.unpack('<I', f.read(4))[0]
        blob = lz4.frame.decompress(f.read(size - 4))
    else:
        blob = f.read(size)
    dest = os.path.join(out, nm)
    open(dest, 'wb').write(blob)
    print('extracted', full, len(blob), '->', dest)
    found += 1
print(found, 'of', len(wanted))
