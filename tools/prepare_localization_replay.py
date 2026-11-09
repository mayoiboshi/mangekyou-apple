#!/usr/bin/env python3
"""Prepare a private replay using local, already decoded translation overlays."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time

from image_recipe import append_image_recipe
from mangekyou_p0 import ROOT, ProbeError, absolute, collision_key, read_bounded, safe_member_name, safe_open


ASCII_LOWER = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')


def logical_key(path):
    return safe_member_name(path).translate(ASCII_LOWER)


def prepare(assets, replay, overlays, audits=None):
    for path in (assets, replay, ROOT / 'private'):
        os.close(safe_open(path, directory=True))
    for path in (assets, replay, *((audits,) if audits else ())):
        if path == ROOT / 'private' or path in (ROOT / 'private').parents:
            raise ProbeError('private_output_would_be_inside_input')

    catalog_bytes = read_bounded(replay / 'combined-catalog.json', 32 * 1024 * 1024)
    catalog = json.loads(catalog_bytes)
    summary = json.loads(read_bounded(replay / 'summary.json', 32 * 1024 * 1024))
    recipe = read_bounded(replay / 'image-recipe.json', 1024 * 1024)
    if any(not isinstance(summary.get(key), list) for key in ('image_resources', 'audio_resources', 'wave_resources')):
        raise ProbeError('overlay_requires_replay_resource_receipts')
    if summary['corpus_report_sha256'] != hashlib.sha256(catalog_bytes).hexdigest():
        raise ProbeError('base_catalog_identity_mismatch')

    added_recipes = []
    selected = {}
    collisions = set()
    total = 0
    if not 1 <= len(overlays) <= 8:
        raise ProbeError('overlay_directory_count_limit')
    deadline = time.monotonic() + 15
    directory_count = 0

    def walk_error(error):
        raise error

    for overlay in overlays:
        prefix = safe_member_name(overlay)
        directory = assets / prefix
        os.close(safe_open(directory, directory=True))
        for parent, dirs, files in os.walk(directory, followlinks=False, onerror=walk_error):
            dirs.sort()
            directory_count += len(dirs) + 1
            if directory_count > 2048 or time.monotonic() > deadline:
                raise ProbeError('overlay_walk_limit')
            for name in dirs:
                os.close(safe_open(Path(parent) / name, directory=True))
            for name in sorted(files):
                if time.monotonic() > deadline:
                    raise ProbeError('overlay_walk_limit')
                path = Path(parent) / name
                logical = safe_member_name(path.relative_to(directory).as_posix())
                key = logical_key(logical)
                collision = collision_key(logical)
                extension = path.suffix.lower()
                if collision in collisions or key == 'startup.s' or extension not in {'.s', '.txt', '.png', '.ogv', '.b'}:
                    raise ProbeError(f'unsupported_or_duplicate_overlay: {logical}')
                if len(selected) >= 512:
                    raise ProbeError('overlay_file_count_limit')
                data = read_bounded(path, (48 if extension == '.ogv' else 16) * 1024 * 1024)
                total += len(data)
                if total > 128 * 1024 * 1024:
                    raise ProbeError('overlay_total_byte_limit')
                if extension in {'.s', '.txt'}:
                    data.decode('utf-16', errors='strict')
                    if not data.startswith((b'\xff\xfe', b'\xfe\xff')):
                        raise ProbeError(f'overlay_text_bom_missing: {logical}')
                elif extension == '.png' and not data.startswith(b'\x89PNG\r\n\x1a\n'):
                    raise ProbeError(f'overlay_png_signature_missing: {logical}')
                if extension == '.ogv' and not data.startswith(b'OggS'):
                    raise ProbeError(f'overlay_ogg_signature_missing: {logical}')
                if extension == '.b':
                    if audits is None:
                        raise ProbeError(f'overlay_abmp_audit_required: {logical}')
                    audit = json.loads(read_bounded((audits / logical).with_suffix('.json'), 1024 * 1024))
                    if audit.get('errors') != []:
                        raise ProbeError(f'overlay_abmp_audit_has_errors: {logical}')
                    append_image_recipe(added_recipes, data, audit)
                collisions.add(collision)
                selected[key] = dict(logical_path=logical, source_file=path.relative_to(assets).as_posix(),
                                     sha256=hashlib.sha256(data).hexdigest())

    if not selected:
        raise ProbeError('overlay_empty')
    by_source = {row['source_file']: row for row in catalog['items']}
    if len(by_source) != len(catalog['items']):
        raise ProbeError('duplicate_base_catalog_source')
    for row in selected.values():
        if row['source_file'] in by_source:
            raise ProbeError('overlay_source_already_in_base_catalog')
    catalog['items'].extend(selected.values())
    summary['selected_sources'] = [
        row for row in summary['selected_sources']
        if logical_key(by_source[row['source_file']]['logical_path']) not in selected
    ] + [{key: row[key] for key in ('source_file', 'sha256')} for row in selected.values()]
    catalog_bytes = json.dumps(catalog, ensure_ascii=False).encode()
    summary['corpus_report_sha256'] = hashlib.sha256(catalog_bytes).hexdigest()
    summary_bytes = json.dumps(summary, ensure_ascii=False).encode()
    if max(len(catalog_bytes), len(summary_bytes)) > 32 * 1024 * 1024:
        raise ProbeError('overlay_replay_size_limit')

    if added_recipes:
        replaced = {row['container_sha256'] for row in added_recipes}
        base = [row for row in json.loads(recipe) if row['container_sha256'] not in replaced]
        recipe = json.dumps(base + added_recipes, ensure_ascii=False, separators=(',', ':')).encode()
        if len(recipe) > 1024 * 1024:
            raise ProbeError('overlay_image_recipe_size_limit')

    output = Path(tempfile.mkdtemp(prefix='localization-replay-', dir=ROOT / 'private'))
    try:
        (output / 'combined-catalog.json').write_bytes(catalog_bytes)
        (output / 'summary.json').write_bytes(summary_bytes)
        (output / 'image-recipe.json').write_bytes(recipe)
    except OSError:
        shutil.rmtree(output)
        raise
    return output, len(selected)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets-dir', required=True)
    parser.add_argument('--replay-dir', required=True)
    parser.add_argument('--overlay', action='append', required=True, help='Decoded overlay directory relative to assets')
    parser.add_argument('--abmp-audit-dir', help='Private ABMP reports arranged by logical path')
    args = parser.parse_args()
    try:
        output, count = prepare(absolute(args.assets_dir), absolute(args.replay_dir), args.overlay, absolute(args.abmp_audit_dir) if args.abmp_audit_dir else None)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps(dict(replay_dir=str(output), selected=count), ensure_ascii=False))


if __name__ == '__main__':
    main()
