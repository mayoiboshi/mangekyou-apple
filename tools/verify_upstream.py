#!/usr/bin/env python3
"""Reproduce local synthetic upstream checks; never loads commercial fixtures."""
import argparse
import hashlib
import importlib
import io
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import unittest

from mangekyou_p0 import ROOT, run, script_probe, write_json, upstream_call
from upstream_worker import validate_source


def png_bytes(color, size=(2, 1)):
    from PIL import Image
    out = io.BytesIO()
    with Image.new('RGBA', size, color) as image:
        image.save(out, format='PNG')
    return out.getvalue()


def dpng_fixture():
    # Disjoint tiles: validates placement and preservation of alpha, not overlap blending.
    tiles = [(0, 0, png_bytes((12, 34, 56, 255))), (2, 0, png_bytes((90, 80, 70, 128)))]
    data = b'DPNG' + struct.pack('<4I', 1, 2, 4, 2)
    for x, y, png in tiles:
        data += struct.pack('<7I', x, y, 2, 1, len(png), 0, 0) + png
    return data


def index_fixture(crypto):
    # Parser-targeted fixture: real archive HashVer/QKEY signatures are NOT constructed.
    # It must never be described as a complete engine-accepted FilePack archive.
    payload = b'SYNTHETIC-P0-NOT-GAME'
    name = 'sample.bin'
    seed_bytes = bytes(range(256))
    key = crypto.derive_v31_key(seed_bytes) & 0x0fffffff
    # XOR name transform is involutive. Reuses upstream transform only in the test generator.
    encrypted_name = crypto.decrypt_name_v31(name.encode('utf-16-le'), key).encode('utf-16-le', errors='surrogatepass')
    table = struct.pack('<H', len(name)) + encrypted_name
    table += struct.pack('<QIIIII', 0, len(payload), len(payload), 0, 0, crypto.hash_v31(payload))
    key_trailer = bytes(36) + seed_bytes + bytes(768)
    footer = b'FilePackVer3.1'.ljust(16, b'\0') + struct.pack('<IQ', 1, len(payload))
    return payload + table + key_trailer + footer, payload


def execute(source, output):
    commit = validate_source(source)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(source))
    from qlie_unpacker import crypto
    from qlie_unpacker.dpng import decode_dpng
    from qlie_unpacker.compression import decompress
    from qlie_unpacker.parser import parse_bytes
    from qlie_unpacker.extractor import _decode_entry
    from PIL import Image
    checks = []
    def check(name, action, scope='synthetic'):
        try:
            detail = action()
            checks.append(dict(name=name, status='verified', scope=scope, detail=detail))
        except Exception as exc:
            checks.append(dict(name=name, status='unsupported', scope=scope, error=repr(exc)))
    with tempfile.TemporaryDirectory(prefix='mangekyou-p0-') as directory:
        root = Path(directory).resolve()
        game, assets = root / 'game', root / 'assets'
        game.mkdir(); assets.mkdir()
        data, expected_payload = index_fixture(crypto)
        (game / 'synthetic.pack').write_bytes(data)
        (assets / 'image.png').write_bytes(dpng_fixture())
        (assets / 'ordinary.png').write_bytes(png_bytes((1, 2, 3, 255)))
        # Original synthetic prose; lexical tokens derive from documented source grammar.
        script = '@@@avg\\header.s\r\n@@start\r\n【調査者】\r\n合成テストです。[n]実ゲームではありません。\r\n^opaque,"image.png",7\r\n％voice.ogg\r\n\\unknown,label:next\r\n^select,"進む","戻る"\r\n@@next\r\n'
        (assets / 'sample.s').write_bytes(script.encode('cp932'))
        def index_check():
            parsed = parse_bytes(data)
            assert parsed.version == 'FilePackVer3.1'
            assert len(parsed.entries) == 1 and parsed.entries[0].name == 'sample.bin'
            # _decode_entry includes hash and exact size validation; no writes/extraction.
            result = _decode_entry(parsed, data, parsed.entries[0], b'', b'')
            assert result == expected_payload
            return dict(entries=1, encryption_method=0, compressed=False,
                        complete_valid_archive=False, qkey_hash_metadata_validated=False)
        check('v31_parser_targeted_index_and_plain_payload', index_check)
        def dpng_check():
            converted = decode_dpng(dpng_fixture())
            with Image.open(io.BytesIO(converted)) as image:
                image.load()
                assert image.size == (4, 2) and image.mode == 'RGBA'
                assert image.getpixel((0, 0)) == (12, 34, 56, 255)
                assert image.getpixel((3, 0)) == (90, 80, 70, 128)
                assert image.getpixel((0, 1)) == (0, 0, 0, 0)
                expected = (bytes((12,34,56,255))*2 + bytes((90,80,70,128))*2 + bytes(16))
                assert image.tobytes() == expected
                return dict(width=4, height=2, rgba_sha256=hashlib.sha256(expected).hexdigest(),
                            alpha_values=[0,128,255], overlap_blending='not_tested')
        check('dpng_disjoint_rgba_tiles_exact_pixels', dpng_check)
        def overlap_check():
            base = png_bytes((255, 0, 0, 255), (1, 1))
            top = png_bytes((0, 0, 255, 128), (1, 1))
            dpng = b'DPNG' + struct.pack('<4I', 1, 2, 1, 1)
            for tile in (base, top):
                dpng += struct.pack('<7I', 0, 0, 1, 1, len(tile), 0, 0) + tile
            with Image.open(io.BytesIO(decode_dpng(dpng))) as image:
                assert image.getpixel((0, 0)) == (0, 0, 255, 128)
            return dict(observed_rgba=[0,0,255,128], implementation='tile replacement',
                        original_engine_agreement='not_tested')
        check('dpng_overlap_implementation_characterization', overlap_check)
        def compressed_check():
            # Identity dictionary and a nonempty literal block, no archive encryption involved.
            payload = b'SYNTHETIC-BPE'
            encoded = b'1PC\xff' + struct.pack('<II', 1, len(payload))
            encoded += b'\xfe\x7f\xfe\xff' + struct.pack('<H', len(payload)) + payload
            assert decompress(encoded, len(payload)) == payload
            return dict(decoded_bytes=len(payload), dictionary='identity literals only')
        check('bpe_nonempty_identity_dictionary', compressed_check)
        def adapter_check():
            listed = upstream_call(source, 'index', game / 'synthetic.pack')
            decoded = upstream_call(source, 'dpng', assets / 'image.png')
            assert listed['status'] == decoded['status'] == 'verified', (listed, decoded)
            assert len(listed['entries']) == 1 and decoded['width'] == 4
            return dict(index_worker=listed, dpng_worker=decoded)
        check('isolated_read_only_adapter', adapter_check)
        def scanner_check():
            before = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob('*') if p.is_file()}
            out = root / 'reports'
            run(game, assets, out, source, dataset='synthetic')
            after = {str(p):hashlib.sha256(Path(p).read_bytes()).hexdigest() for p in before}
            assert before == after
            return dict(input_files_sha256_unchanged=True)
        check('scanner_synthetic_input_integrity', scanner_check)
        # Re-run into ignored location: synthetic IR may include text, real runs redact it.
        run(game, assets, ROOT / '.research/synthetic-reports', source, dataset='synthetic')
        checks.append(dict(name='synthetic_script_lexical_structure', status='verified', scope='synthetic',
            detail=dict(records=len(script_probe(script.encode('cp932'), 'sample.s')['records']),
                        physical_order='verified', dialogue_accuracy_on_real_game='not_tested',
                        execution_semantics='unsupported')))
        synthetic_ir = script_probe(script.encode('cp932'), 'sample.s', include_text=True)
    # Existing upstream test suite, with all proprietary fixtures explicitly disabled.
    env = dict(os.environ, PYTHONPATH=str(source), QLIE_TEST_FIXTURES=str(ROOT / '.research/no-commercial-fixtures'),
               PYTHONDONTWRITEBYTECODE='1')
    proc = subprocess.run([sys.executable, '-m', 'unittest', 'discover', '-s', str(source / 'tests'), '-v'],
                          env=env, capture_output=True, timeout=60)
    log = (proc.stdout + proc.stderr).decode('utf-8', 'replace')
    ran = re.search(r'Ran (\d+) tests?', log)
    skipped = re.search(r'OK \(skipped=(\d+)\)', log)
    count = int(ran[1]) if ran else None
    skip_count = int(skipped[1]) if skipped else 0
    checks.append(dict(name='upstream_unittest_suite', status='verified' if proc.returncode == 0 else 'unsupported',
        scope='upstream_synthetic_and_mock_tests', tests_run=count, skipped=skip_count,
        passed=count-skip_count if count is not None and proc.returncode == 0 else None,
        log=log, real_game_tests='not_tested'))
    report = dict(schema_version=1, status='verified' if all(c['status']=='verified' for c in checks) else 'unsupported',
                  dataset='synthetic', real_game_status='not_tested', upstream_commit=commit,
                  python=sys.version.split()[0], machine=os.uname().machine, checks=checks,
                  synthetic_script_ir=synthetic_ir,
                  msg_tool_scope='Python verification only; see msg-build.json and script-report.json for Rust build and real extraction cross-check')
    write_json(output, report)
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, default=ROOT / '.research/upstream/qlie-unpack')
    ap.add_argument('--output', type=Path, default=ROOT / 'private/upstream-verification.json')
    args = ap.parse_args()
    report = execute(args.source.resolve(), args.output)
    print(json.dumps(dict(status=report['status'], checks=len(report['checks']), output=str(args.output))))
    return 0 if report['status'] == 'verified' else 1


if __name__ == '__main__':
    sys.exit(main())
