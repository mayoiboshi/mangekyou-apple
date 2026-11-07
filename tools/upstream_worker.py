#!/usr/bin/env python3
"""Isolated, read-only adapter. Does not call upstream output/extraction APIs."""
import argparse
import hashlib
import io
import json
import mmap
from pathlib import Path
import resource
import sys

if __package__:
    from .dpng_audit import audit_pixels,MAX_SOURCE
    from .mangekyou_p0 import (ROOT, MAX_BYTES, MAX_PIXELS, ProbeError, collision_key,
                              dpng_metadata, footer_probe, read_bounded, safe_member_name, safe_open)
else:
    from dpng_audit import audit_pixels,MAX_SOURCE
    from mangekyou_p0 import (ROOT, MAX_BYTES, MAX_PIXELS, ProbeError, collision_key,
                              dpng_metadata, footer_probe, read_bounded, safe_member_name, safe_open)


def validate_source(source):
    lock = json.loads((ROOT / 'docs/upstream-lock.json').read_text())
    entry = next(x for x in lock['upstreams'] if x['repository'] == 'rafi441/qlie-unpack')
    for item in entry['files']:
        if item['path'].startswith('qlie_unpacker/'):
            data = read_bounded(source / item['path'], 4 * 1024 * 1024)
            if hashlib.sha256(data).hexdigest() != item['sha256']:
                raise ProbeError('upstream_source_digest_mismatch:' + item['path'])
    # Reject unmanifested package modules and symlinks, including stale bytecode.
    allowed = {x['path'] for x in entry['files']}
    for path in (source / 'qlie_unpacker').rglob('*'):
        if path.is_symlink():
            raise ProbeError('upstream_symlink_rejected')
        if path.suffix in {'.py', '.so', '.dylib', '.pyc'} and path.relative_to(source).as_posix() not in allowed:
            raise ProbeError('unmanifested_upstream_module')
    return entry['commit']


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, required=True)
    ap.add_argument('--operation', choices=['index', 'dpng', 'dpng-audit'], required=True)
    ap.add_argument('--input', type=Path, required=True)
    args = ap.parse_args()
    result = dict(status='unsupported', errors=[], resource_limits={})
    try:
        for label, kind, value in [('cpu_seconds', resource.RLIMIT_CPU, 20),
                                   ('data_bytes', resource.RLIMIT_DATA, 768 * 1024 * 1024),
                                   ('file_output_bytes', resource.RLIMIT_FSIZE, 0)]:
            _, hard = resource.getrlimit(kind)
            effective = min(value, hard) if hard != resource.RLIM_INFINITY else value
            try:
                resource.setrlimit(kind, (effective, effective))
                result['resource_limits'][label] = dict(status='verified', value=effective)
            except (OSError, ValueError) as exc:
                if kind != resource.RLIMIT_DATA:
                    raise
                result['resource_limits'][label] = dict(status='unsupported', reason=str(exc),
                    fallback='bounded input, index count, canvas pixels, CPU and wall time; no hard RSS cap')
        commit = validate_source(args.source)
        sys.dont_write_bytecode = True
        sys.path.insert(0, str(args.source))
        result['upstream_commit'] = commit
        if args.operation == 'index':
            import os
            from qlie_unpacker.parser import parse_bytes
            with os.fdopen(safe_open(args.input), 'rb') as stream:
                size = stream.seek(0, 2)
                stream.seek(max(0, size - 28))
                preflight = footer_probe(stream.read(28), size)
                with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
                    archive = parse_bytes(data, args.input)
                    entries, seen = [], set()
                    total = 0
                    for entry in archive.entries:
                        safe_member_name(entry.name)
                        key = collision_key(entry.name)
                        if key in seen:
                            raise ProbeError('case_or_unicode_path_collision')
                        seen.add(key)
                        if entry.offset + entry.compressed_size > preflight['table_offset']:
                            raise ProbeError('entry_overlaps_index')
                        # No decompression here. Record sizes even for unsupported payloads.
                        total += entry.original_size
                        entries.append(dict(index=entry.index, name=entry.name, offset=entry.offset,
                            compressed_size=entry.compressed_size, original_size=entry.original_size,
                            compressed=entry.compressed, encryption_method=entry.encryption_method,
                            hash_value=entry.hash_value, content_status='not_tested'))
                    result.update(status='verified', version=archive.version, entries=entries,
                                  total_declared_output_bytes=total, payload_decode_status='not_tested',
                                  key_signature_status='not_tested', writes_performed=False)
        elif args.operation == 'dpng-audit':
            from qlie_unpacker.dpng import decode_dpng
            result.update(audit_pixels(read_bounded(args.input,MAX_SOURCE),decode_dpng))
            result['writes_performed']=False
        else:
            from PIL import Image
            from qlie_unpacker.dpng import decode_dpng
            data = read_bounded(args.input)
            metadata = dpng_metadata(data)
            Image.MAX_IMAGE_PIXELS = MAX_PIXELS
            converted = decode_dpng(data)
            if len(converted) > MAX_BYTES:
                raise ProbeError('converted_output_limit')
            with Image.open(io.BytesIO(converted)) as image:
                image.load()
                result.update(status='verified', width=image.width, height=image.height, mode=image.mode,
                    alpha_extrema=list(image.getextrema()[3]), tile_count=len(metadata['tiles']),
                    output_sha256=hashlib.sha256(converted).hexdigest(),
                    rgba_sha256=hashlib.sha256(image.tobytes()).hexdigest(),
                    blend_semantics_status='not_tested', writes_performed=False)
    except Exception as exc:
        result['errors'].append(dict(category=type(exc).__name__, detail=str(exc)))
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
