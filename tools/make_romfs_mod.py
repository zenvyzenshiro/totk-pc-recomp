"""Turn a RomFS mod folder into a checked overlay for totk.exe (runtime/romfs.c, TOTK_ROMFS_MODS).

The runtime serves the files a manifest.tsv lists in place of the originals and stops the start when a size or hash
differs, so a mod made for another game version fails loudly instead of loading the wrong bytes. This script:

  - checks that the extracted RomFS is the version asked for (its size and SHA-256 against tools/data/expected-*.json),
  - copies each mod file whose path the RomFS has into <out>, with the original's SHA-256 in <out>/manifest.tsv,
  - skips mod files the RomFS lacks (another version's name; the game never opens them) and lists them,
  - checks that a replaced .zs file decompresses to the size of the original (when compression.zstd is available),
  - stops when the mod replaces a file the frame-rate overlay (romfs-patches) already replaces,
  - warns when the RomFS has sibling files of the same family the mod does not cover (USen.Product.<n> for a
    message mod: the game may load another one).

    .venv-py314\\Scripts\\python tools\\make_romfs_mod.py --mod <folder holding romfs files> --version v143 --name indonesian

Output goes under build/ (ignored by git). The mod folder is only read.
"""
import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path

try:
    from compression import zstd
except ImportError:
    zstd = None

ROOT = Path(__file__).resolve().parent.parent
DISPLAY = {'v121': '1.2.1', 'v143': '1.4.3'}


def fail(msg):
    sys.exit(f'make_romfs_mod: {msg}')


def sha_file(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def read_range(image, offset, size):
    image.seek(offset)
    data = image.read(size)
    if len(data) != size:
        fail(f'romfs.bin ends before {offset + size}')
    return data


def zstd_size(data):
    """The decompressed size a zstd frame header records, or None without the decoder. The game's .zs files use the
    dictionaries of Pack/ZsDic.pack.zs, so the header is read instead of decompressing."""
    if zstd is None:
        return None
    try:
        return zstd.get_frame_info(data).decompressed_size
    except zstd.ZstdError:
        fail('a .zs file is not a zstd frame')


def add(staging, lines, rel, data, original):
    dst = staging / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(data)
    lines.append(f'{rel}\t{len(data)}\t{hashlib.sha256(data).hexdigest()}\t{hashlib.sha256(original).hexdigest()}')
    print(f'  replace {rel} ({len(data):,} bytes)')


def mod_root(path):
    """The RomFS root inside a mod folder: the folder itself, a romfs/ below it, or the one <title>/<name>/romfs."""
    if (path / 'romfs').is_dir():
        return path / 'romfs'
    found = [p for p in path.rglob('romfs') if p.is_dir()]
    if len(found) == 1:
        return found[0]
    if len(found) > 1:
        fail(f'{path} holds {len(found)} romfs folders; pass the one to use with --mod')
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--mod', type=Path, required=True, help='mod folder (its romfs/ is found below it)')
    ap.add_argument('--version', default='v143', choices=sorted(DISPLAY))
    ap.add_argument('--name', default='mod', help='overlay folder name under build/<version>/mods')
    ap.add_argument('--romfs', type=Path, help='default build/extracted/<version>/romfs')
    ap.add_argument('--out', type=Path, help='default build/<version>/mods/<name>')
    ap.add_argument('--patches', type=Path, help='default build/<version>/romfs-patches')
    ap.add_argument('--map-family', action='store_true',
                    help='also serve a mod file for a sibling Product.<n> name the mod lacks when the decompressed sizes '
                         'match (for mods that ship one archive under several names)')
    args = ap.parse_args()

    romfs = args.romfs or ROOT / 'build/extracted' / args.version / 'romfs'
    out = args.out or ROOT / 'build' / args.version / 'mods' / args.name
    patches = args.patches or ROOT / 'build' / args.version / 'romfs-patches'
    src = mod_root(args.mod.resolve())

    index_path, image_path = romfs / 'index.json', romfs / 'romfs.bin'
    if not index_path.is_file() or not image_path.is_file():
        fail(f'{romfs} has no index.json and romfs.bin; run tools/extract.py first')
    index = json.loads(index_path.read_text())
    expected = json.loads((ROOT / 'tools/data' / f'expected-v{DISPLAY[args.version]}.json').read_text())
    if index.get('romfs_size') != expected['romfs']['size'] or index.get('romfs_sha256') != expected['romfs']['sha256']:
        fail(f'{romfs} is not the {DISPLAY[args.version]} RomFS (size or SHA-256 differs)')
    print(f'RomFS {DISPLAY[args.version]}: verified ({len(index["files"]):,} files)')
    files = {e['path']: e for e in index['files']}

    mod_files = sorted(p for p in src.rglob('*') if p.is_file())
    if not mod_files:
        fail(f'{src} holds no files')

    taken = set()
    if (patches / 'manifest.tsv').is_file():
        for line in (patches / 'manifest.tsv').read_text(encoding='utf-8').splitlines():
            if line and not line.startswith('#'):
                taken.add(line.split('\t', 1)[0])

    family = re.compile(r'(.*\.Product\.)\d+(\..*)$')   # one archive per game version: Mals/USen.Product.<n>.sarc.zs

    def check(rel, original, data):
        if rel in taken:
            fail(f'{rel} is also replaced by {patches}; the two overlays conflict')
        if rel.endswith('.zs'):
            want, got = zstd_size(original), zstd_size(data)
            if want is not None and want != got:
                return f'decompresses to {got} bytes, the original to {want}'
        return None

    lines, skipped, sources = [], [], {}
    staging = out.with_name(out.name + '.tmp')
    shutil.rmtree(staging, ignore_errors=True)
    with image_path.open('rb') as image:
        def original_of(rel):
            e = files[rel]
            return read_range(image, e['offset'], e['size'])

        for f in mod_files:
            rel = f.relative_to(src).as_posix()
            m = family.match(rel)
            if m:
                sources.setdefault((m.group(1), m.group(2)), f)
            if rel not in files:
                skipped.append(rel)
                continue
            original, data = original_of(rel), f.read_bytes()
            why = check(rel, original, data)
            if why:
                fail(f'{rel} {why}; the mod does not fit {DISPLAY[args.version]}')
            add(staging, lines, rel, data, original)
        for rel in skipped:
            print(f'  skip    {rel}: not in the {DISPLAY[args.version]} RomFS (the game does not open it)')

        covered = {line.split('\t', 1)[0] for line in lines}
        for (head, tail), f in sorted(sources.items()):
            pat = re.compile(re.escape(head) + r'\d+' + re.escape(tail) + '$')
            for rel in sorted(p for p in files if pat.match(p) and p not in covered):
                if not args.map_family:
                    print(f'  warning: the RomFS has {rel}, which the mod does not replace (see --map-family)')
                    continue
                original, data = original_of(rel), f.read_bytes()
                why = check(rel, original, data) or (None if zstd_size(original) else 'has no recorded size')
                if why:
                    print(f'  skip    {rel}: {why}')
                    continue
                print(f'  map     {f.name} -> {rel}')
                add(staging, lines, rel, data, original)

    if not lines:
        shutil.rmtree(staging, ignore_errors=True)
        fail(f'none of the mod files is in the {DISPLAY[args.version]} RomFS; the mod is for another version')
    (staging / 'manifest.tsv').write_text('# path\tsize\tsha256\toriginal_sha256 (tools/make_romfs_mod.py)\n'
                                          + '\n'.join(lines) + '\n', encoding='utf-8', newline='\n')
    if zstd is None:
        print('  note: compression.zstd unavailable (use .venv-py314); decompressed sizes not checked')
    shutil.rmtree(out, ignore_errors=True)
    staging.rename(out)
    print(f'overlay: {out} ({len(lines)} files); set romfs_mods = {out} in totk.ini')


if __name__ == '__main__':
    main()
