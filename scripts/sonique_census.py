#!/usr/bin/env python3
"""Structural census of Sonique .sgf skins: one summary over a directory, read-only.

usage: python3 -I scripts/sonique_census.py [<dir>]   (default: the corpus in Application Support)

Pre-engine tooling. It is replaced by the engine's own census probe once the loader exists;
reference/harness.md says which one is current.
"""
import collections, hashlib, os, re, struct, sys

ENTRY_TABLE, ENTRY_SIZE, NAME_SIZE = 0x70, 0x64, 0x54


def entries(data):
    """Yield (name, payload) for each directory entry; raises on a malformed archive."""
    if data[:4] != b'DAF\0':
        raise ValueError('magic is not DAF')
    count = struct.unpack_from('<I', data, 0x68)[0]
    for i in range(count):
        at = ENTRY_TABLE + i * ENTRY_SIZE
        name = data[at:at + NAME_SIZE].split(b'\0')[0].decode('latin1')
        offset, size = struct.unpack_from('<II', data, at + NAME_SIZE)
        if offset + size > len(data):
            raise ValueError(f'{name}: entry past EOF')
        yield name, data[offset:offset + size]


def region_ok(payload):
    """A region is u16 count, u16 l,t,r,b bounds, then count u16 l,t,r,b rectangles."""
    return len(payload) >= 2 and len(payload) == 10 + 8 * struct.unpack_from('<H', payload)[0]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser(
        '~/Library/Application Support/NullPlayer/SoniqueSkins')
    paths = sorted(os.path.join(d, f) for d, _, fs in os.walk(root) for f in fs if f.lower().endswith('.sgf'))
    seen, failed = set(), []
    names, versions, sections = collections.Counter(), collections.Counter(), collections.Counter()
    bad_regions = 0
    for path in paths:
        data = open(path, 'rb').read()
        digest = hashlib.sha256(data).digest()
        if digest in seen:
            continue
        seen.add(digest)
        try:
            skin = dict(entries(data))
        except Exception as e:
            failed.append(f'{os.path.relpath(path, root)}: {e}')
            continue
        names.update(skin.keys())
        bad_regions += sum(1 for n, p in skin.items() if n.startswith('/rgn/') and not region_ok(p))
        ini = skin.get('/skin.ini', b'').decode('latin1').lower()
        m = re.search(r'^\s*version\s*=\s*(\d+)', ini, re.M)
        versions[m.group(1) if m else ('none' if ini else 'no skin.ini')] += 1
        sections.update(s.strip() for s in re.findall(r'^\[([^\]]+)\]', ini, re.M))
    print(f'files={len(paths)} unique={len(seen)} parsed={len(seen) - len(failed)} failed={len(failed)} '
          f'malformed_regions={bad_regions}')
    print('version', dict(versions.most_common()))
    print('sections', dict(sections.most_common()))
    for name, n in names.most_common():
        print(f'entry {n:4} {name}')
    for line in failed:
        print('FAIL', line)


if __name__ == '__main__':
    main()
