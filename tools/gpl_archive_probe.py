#!/usr/bin/env python3
"""Build and cross-check a pinned GPL archive reader locally; no filesystem extraction."""
import argparse
from collections import Counter
import hashlib
import io
import json
import os
from pathlib import Path
import re
import resource
import struct
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_open, safe_member_name, collision_key, footer_probe, write_json
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_open, safe_member_name, collision_key, footer_probe, write_json

PRIVATE = ROOT/'private/p1-round25'
TARGET = ROOT/'.research/gpl-archive-target'
MEMBER_LIMIT = 16*1024*1024
TOTAL_LIMIT = 128*1024*1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode()


def output_root(path):
    for parent in [path]+list(path.parents):
        if parent.is_symlink():
            raise ProbeError('gpl_output_symlink')
    path.mkdir(parents=True, exist_ok=True)
    fd = safe_open(path, directory=True)
    os.close(fd)


def private_bytes(path, data):
    output_root(path.parent)
    directory = safe_open(path.parent, directory=True)
    try:
        fd = os.open(path.name, os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW, 0o600, dir_fd=directory)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
    finally:
        os.close(directory)


def pinned_source(source):
    lock = json.loads(read_bounded(ROOT/'docs/upstream-lock.json'))
    upstream = next(u for u in lock['upstreams'] if u['repository'] == 'lifegpc/msg-tool')
    allowed = {r['path'] for r in upstream['files']}
    for row in upstream['files']:
        if sha(read_bounded(source/row['path'], 4*1024*1024)) != row['sha256']:
            raise ProbeError('gpl_source_digest_mismatch')
    for path in source.rglob('*'):
        if path.is_symlink() or (path.suffix == '.rs' and path.relative_to(source).as_posix() not in allowed):
            raise ProbeError('gpl_unmanifested_source_or_symlink')
    return upstream


def build(source):
    upstream = pinned_source(source)
    for directory in [PRIVATE, TARGET, ROOT/'reports/p1']:
        output_root(directory)
    if any(p.is_symlink() for p in TARGET.rglob('*')):
        raise ProbeError('gpl_build_target_symlink')
    env = dict(os.environ, CARGO_HOME=str(ROOT/'.research/cargo'), RUSTUP_HOME=str(ROOT/'.research/rustup'))
    env['PATH'] = str(ROOT/'.research/cargo/bin')+os.pathsep+env.get('PATH', '')
    cargo = ROOT/'.research/cargo/bin/cargo'
    rustc = ROOT/'.research/cargo/bin/rustc'
    args = [str(cargo), 'build', '--manifest-path', str(source/'Cargo.toml'), '--locked',
        '--no-default-features', '--features', 'qlie-arc', '--lib', '--release',
        '--target-dir', str(TARGET), '--message-format=json-render-diagnostics']
    p = subprocess.run(args, env=env, capture_output=True, timeout=300)
    private_bytes(PRIVATE/'cargo-build.jsonl', p.stdout)
    private_bytes(PRIVATE/'cargo-build.stderr', p.stderr)
    if p.returncode:
        raise ProbeError('gpl_library_build_failed')
    rows = [json.loads(line) for line in p.stdout.splitlines()]
    artifacts = {}
    compiled = set()
    for row in rows:
        if row.get('reason') != 'compiler-artifact':
            continue
        compiled.add(row['package_id'])
        name = row['target']['name']
        if name in {'msg_tool', 'serde_json'}:
            found = [absolute(f) for f in row['filenames'] if f.endswith('.rlib')]
            if len(found) == 1:
                if TARGET not in found[0].parents:
                    raise ProbeError('gpl_library_artifact_location')
                artifacts[name] = found[0]
    if set(artifacts) != {'msg_tool', 'serde_json'}:
        raise ProbeError('gpl_library_artifacts_missing')
    bridge = ROOT/'tools/rust_archive_probe.rs'
    binary = TARGET/'archive-probe'
    command = [str(rustc), '--edition', '2024', str(bridge), '-L', 'dependency='+str(TARGET/'release/deps')]
    for name, path in sorted(artifacts.items()):
        command += ['--extern', name+'='+str(path)]
    command += ['-o', str(binary)]
    p = subprocess.run(command, env=env, capture_output=True, timeout=120)
    private_bytes(PRIVATE/'bridge-build.log', p.stdout+p.stderr)
    if p.returncode:
        raise ProbeError('gpl_bridge_build_failed')
    data = read_bounded(binary)
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x0100000c:
        raise ProbeError('gpl_bridge_not_arm64_macho')
    versions = {}
    for name, executable in [('cargo', cargo), ('rustc', rustc)]:
        p = subprocess.run([str(executable), '--version'], env=env, capture_output=True, text=True, timeout=15)
        if p.returncode:
            raise ProbeError('gpl_toolchain_version_failed')
        versions[name] = p.stdout.strip()
    meta_args = [str(cargo), 'metadata', '--manifest-path', str(source/'Cargo.toml'), '--locked',
        '--no-default-features', '--features', 'qlie-arc', '--format-version', '1']
    p = subprocess.run(meta_args, env=env, capture_output=True, timeout=120)
    private_bytes(PRIVATE/'cargo-metadata.json', p.stdout)
    if p.returncode:
        raise ProbeError('gpl_dependency_metadata_failed')
    metadata = json.loads(p.stdout)
    dependencies = [dict(name=p['name'], version=p['version'], license=p.get('license'), source=p.get('source'))
        for p in metadata['packages'] if p['id'] in compiled]
    test_binary = TARGET/'archive-probe-tests'
    test_command = command[:-2]+['--test', '-o', str(test_binary)]
    tested = subprocess.run(test_command, env=env, capture_output=True, timeout=120)
    private_bytes(PRIVATE/'bridge-test-build.log', tested.stdout+tested.stderr)
    if tested.returncode:
        raise ProbeError('gpl_bridge_test_build_failed')
    tested = subprocess.run([str(test_binary)], capture_output=True, timeout=30)
    private_bytes(PRIVATE/'bridge-tests.log', tested.stdout+tested.stderr)
    if tested.returncode:
        raise ProbeError('gpl_bridge_tests_failed')
    match = re.search(rb'test result: ok\. (\d+) passed; 0 failed;', tested.stdout)
    if not match or int(match.group(1)) < 1:
        raise ProbeError('gpl_bridge_test_count_missing')
    pinned_source(source)
    report = dict(schema_version=1, status='verified', dataset='synthetic',
        scope='Pinned qlie-arc library and owned research bridge build only; not a game runtime',
        upstream_commit=upstream['commit'], license=upstream['license'], source_files_checked=len(upstream['files']),
        cargo_lock_sha256=sha(read_bounded(source/'Cargo.lock')), features=['qlie-arc'],
        architecture='arm64', versions=versions, dependencies=dependencies,
        bridge_source_sha256=sha(read_bounded(bridge)), binary_sha256=sha(data),
        bridge_tests=dict(status='verified', passed=int(match.group(1)), skipped=0, dataset='synthetic',
            scope='Owned read/seek/output-policy fixtures, not original engine execution'),
        binary=binary.relative_to(ROOT).as_posix(), redistribution_approval='not_tested',
        upstream_source_modified=False, complete_game_compatibility='not_tested')
    write_json(ROOT/'reports/p1/gpl-archive-build.json', report)
    return binary, report


def merge_spans(spans):
    out = []
    for a, b in sorted(spans):
        if out and a <= out[-1][1]:
            out[-1][1] = max(out[-1][1], b)
        else:
            out.append([a, b])
    return [dict(start=a, end=b) for a, b in out]


def request_for(archive, selected, size):
    entries = archive['index']['entries']
    if archive['version'] != 'FilePackVer3.1' or not 1 <= len(entries) <= 100000 or len(selected) > 512:
        raise ProbeError('gpl_archive_profile_or_count')
    if archive['declared_entry_count'] != len(entries) or not 0 <= archive['table_offset'] < size-28:
        raise ProbeError('gpl_archive_metadata_bounds')
    seen = set()
    keys = []
    for index, e in enumerate(entries):
        if any(type(e[k]) is not int for k in ['index', 'offset', 'compressed_size', 'original_size', 'encryption_method']):
            raise ProbeError('gpl_entry_integer_type')
        if e['index'] != index:
            raise ProbeError('gpl_index_sequence')
        name = safe_member_name(e['name'])
        key = collision_key(name)
        if key in seen:
            raise ProbeError('gpl_name_collision')
        seen.add(key)
        if (not 0 <= e['offset'] <= archive['table_offset'] or not 0 <= e['compressed_size'] <= archive['table_offset']-e['offset']
            or not 0 <= e['original_size'] <= 0xffffffff or e['encryption_method'] not in {0, 1, 2}):
            raise ProbeError('gpl_entry_bounds_or_method')
        if name == 'pack_keyfile_kfueheish15538fa9or.key':
            keys.append(e)
    if len(keys) != 1 or keys[0]['compressed'] or keys[0]['encryption_method'] != 1 or not (
        80 <= keys[0]['compressed_size'] == keys[0]['original_size'] <= 1024*1024):
        raise ProbeError('gpl_embedded_key_outside_bounded_profile')
    spans = [(archive['table_offset'], size), (keys[0]['offset'], keys[0]['offset']+keys[0]['compressed_size'])]
    output = []
    total = 0
    indexes = set()
    for row in selected:
        index = row['index']
        if type(index) is not int or not 0 <= index < len(entries) or index in indexes:
            raise ProbeError('gpl_selected_index')
        indexes.add(index)
        e = entries[index]
        if e in keys or any(row[k] != e[k] for k in ['name', 'offset', 'compressed_size', 'original_size', 'compressed', 'encryption_method']):
            raise ProbeError('gpl_selected_entry_identity_or_key_export')
        expected_path = Path(archive['path']).name+'/'+safe_member_name(e['name'])
        if safe_member_name(row['copy_path']) != expected_path:
            raise ProbeError('gpl_sample_copy_path')
        total += e['original_size']
        if max(e['original_size'], e['compressed_size']) > MEMBER_LIMIT or total > TOTAL_LIMIT:
            raise ProbeError('gpl_selected_output_limit')
        if e['compressed_size']:
            spans.append((e['offset'], e['offset']+e['compressed_size']))
        output.append(dict(index=index, decoded_size=e['original_size']))
    return dict(file_size=size, expected_count=len(entries), allowed_spans=merge_spans(spans), entries=output)


def parse_output(data, expected_names, selected):
    if len(data) > TOTAL_LIMIT+16*1024*1024:
        raise ProbeError('gpl_pipe_total_limit')
    stream = io.BytesIO(data)
    def frame():
        raw = stream.read(4)
        if len(raw) != 4:
            raise ProbeError('gpl_missing_protocol_frame')
        length, = struct.unpack('<I', raw)
        if length > 8*1024*1024:
            raise ProbeError('gpl_protocol_metadata_limit')
        raw = stream.read(length)
        if len(raw) != length:
            raise ProbeError('gpl_short_protocol_frame')
        row = json.loads(raw)
        if not isinstance(row, dict):
            raise ProbeError('gpl_protocol_frame_not_object')
        if row.get('kind') == 'fatal':
            code = row.get('code', 'fatal')
            if not isinstance(code, str) or not re.fullmatch(r'[a-z_]{1,64}', code):
                code = 'invalid_error_code'
            raise ProbeError('gpl_child_'+code)
        return row
    index = frame()
    if index.get('kind') != 'index' or index.get('names') != expected_names:
        raise ProbeError('gpl_index_name_mismatch')
    rows = []
    for expected in selected:
        row = frame()
        if row.get('kind') != 'payload' or type(row.get('index')) is not int or row.get('index') != expected['index']:
            raise ProbeError('gpl_payload_sequence')
        base = dict(index=expected['index'], source_file=expected['copy_path'],
            expected_sha256=expected['sha256'], archive_offset=expected['offset'],
            stored_size=expected['compressed_size'], decoded_size=expected['original_size'],
            compressed=expected['compressed'], encryption_method=expected['encryption_method'])
        if row.get('status') == 'unsupported':
            if row.get('code') not in {'upstream_decode', 'decoded_size_mismatch'}:
                raise ProbeError('gpl_unknown_child_error_code')
            rows.append(dict(base, status='unsupported', code=row.get('code', 'upstream_decode')))
            continue
        if row.get('status') != 'verified' or type(row.get('length')) is not int or row.get('length') != expected['original_size'] or row['length'] > MEMBER_LIMIT:
            raise ProbeError('gpl_payload_length')
        payload = stream.read(row['length'])
        if len(payload) != row['length']:
            raise ProbeError('gpl_short_payload')
        observed = sha(payload)
        rows.append(dict(base, observed_sha256=observed, status='verified' if observed == expected['sha256'] else 'unsupported',
            code=None if observed == expected['sha256'] else 'decoded_sha256_mismatch'))
    end = frame()
    if end.get('kind') != 'end' or stream.read(1):
        raise ProbeError('gpl_protocol_termination')
    if not re.fullmatch(r'OK: 0, Ignored: 0, Error: 0, Warning: 0', end.get('counter', '')):
        raise ProbeError('gpl_upstream_warning_or_error')
    return rows


def hash_fd(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    h = hashlib.sha256()
    while True:
        data = os.read(fd, 8*1024*1024)
        if not data:
            break
        h.update(data)
    os.lseek(fd, 0, os.SEEK_SET)
    return h.hexdigest()


def child_limits():
    for limit, value in [(resource.RLIMIT_CPU, 30), (resource.RLIMIT_FSIZE, 0), (resource.RLIMIT_CORE, 0)]:
        resource.setrlimit(limit, (value, value))


def run_probe(game, assets, source):
    binary, built = build(source)
    inventory = json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    originals = {r['path']: r for r in inventory['files']}
    archives = json.loads(read_bounded(ROOT/'private/real-p0/archive-report.json'))['items']
    samples_bytes = read_bounded(ROOT/'private/real-p0/sample-report.json')
    samples = {r['archive']: r['entries'] for r in json.loads(samples_bytes)['archives']}
    results = []
    for archive in archives:
        name = safe_member_name(archive['path'])
        if not name.startswith('GameData/'):
            continue
        row = dict(source_file=name, source_sha256=archive['sha256'], status='unsupported', errors=[])
        fd = None
        try:
            if name not in originals or archive['sha256'] != originals[name].get('sha256'):
                raise ProbeError('gpl_archive_inventory_identity')
            fd = safe_open(game/name)
            size = os.fstat(fd).st_size
            if size != originals[name]['size'] or hash_fd(fd) != archive['sha256']:
                raise ProbeError('gpl_archive_current_identity')
            meta = footer_probe(os.pread(fd, 28, size-28), size)
            if any(meta[k] != archive[k] for k in ['version', 'declared_entry_count', 'table_offset']):
                raise ProbeError('gpl_footer_identity')
            selected = samples.get(name, [])
            for selected_row in selected:
                data = read_bounded(assets/safe_member_name(selected_row['copy_path']), MEMBER_LIMIT)
                if sha(data) != selected_row['sha256']:
                    raise ProbeError('gpl_reference_copy_identity')
            request = request_for(archive, selected, size)
            process = subprocess.run([str(binary), str(fd)], input=canonical(request), pass_fds=(fd,),
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=40, cwd=PRIVATE, preexec_fn=child_limits)
            private_bytes(PRIVATE/(Path(name).name+'-stderr.log'), process.stderr[:65536])
            if process.returncode not in {0, 2} or len(process.stderr) > 65536:
                raise ProbeError('gpl_child_exit_or_stderr_limit')
            payloads = parse_output(process.stdout, [e['name'] for e in archive['index']['entries']], selected)
            for payload, chosen in zip(payloads, selected):
                stored = os.pread(fd, chosen['compressed_size'], chosen['offset'])
                if len(stored) != chosen['compressed_size']:
                    raise ProbeError('gpl_short_stored_reference')
                payload['raw_bytes_reference'] = dict(source_file=name, source_sha256=archive['sha256'],
                    offset=chosen['offset'], length=len(stored), sha256=sha(stored))
                payload['decoded_copy_reference'] = dict(source_file=chosen['copy_path'], source_sha256=chosen['sha256'],
                    offset=0, length=chosen['original_size'], sha256=chosen['sha256'])
            if process.stderr:
                raise ProbeError('gpl_upstream_stderr_requires_review')
            if hash_fd(fd) != archive['sha256']:
                raise ProbeError('gpl_archive_changed_during_probe')
            row.update(status='verified' if all(r['status'] == 'verified' for r in payloads) else 'unsupported',
                index_name_count=len(archive['index']['entries']),
                index_names_sha256=sha(canonical([e['name'] for e in archive['index']['entries']])),
                payloads=payloads, reader_spans=request['allowed_spans'], original_sha256_after=archive['sha256'])
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
            row['errors'].append(dict(category=type(exc).__name__, code=str(exc) if isinstance(exc, ProbeError) else type(exc).__name__))
        finally:
            if fd is not None:
                os.close(fd)
        results.append(row)
        write_json(PRIVATE/'archive-progress.json', dict(status='inferred', archives=results))
        print(json.dumps(dict(archive=name, status=row['status'], payloads=len(row.get('payloads', [])), errors=row['errors'])), flush=True)
    payloads = [p for a in results for p in a.get('payloads', [])]
    okay = len(results) == 9 and len(payloads) == 410 and all(a['status'] == 'verified' for a in results)
    report = dict(schema_version=1, status='inferred' if okay else 'unsupported', dataset='real',
        scope='Known SHA-pinned fourth-game archive indexes and the existing bounded 410-resource sample only; not a general importer or runtime',
        upstream_commit=built['upstream_commit'], license=built['license'],
        build_report='reports/p1/gpl-archive-build.json', binary_sha256=built['binary_sha256'],
        build_report_sha256=sha(read_bounded(ROOT/'reports/p1/gpl-archive-build.json')),
        producer_sha256=sha(read_bounded(ROOT/'tools/gpl_archive_probe.py')),
        reference_sample_manifest_sha256=sha(samples_bytes), archives=results,
        archive_count=len(results), index_name_count=sum(a.get('index_name_count', 0) for a in results),
        payload_count=len(payloads), payload_status_counts=dict(Counter(r['status'] for r in payloads)),
        payload_compression_counts=dict(Counter(str(r['compressed']) for r in payloads)),
        decoded_bytes=sum(r['decoded_size'] for r in payloads if r['status'] == 'verified'),
        neighbour_key_discovery='disabled_by_empty_filename', keys_exported=False,
        upstream_source_modified=False, original_files_written=False, external_game_data_uploads=False,
        commercial_payloads_saved=False, full_game_compatibility='not_tested', original_execution='not_tested',
        runtime_development_ready=False, redistribution_approval='not_tested',
        limits=dict(member_output_bytes=MEMBER_LIMIT, aggregate_output_bytes=TOTAL_LIMIT,
            archive_read_bytes=64*1024*1024, archive_seek_count=1000000,
            child_cpu_seconds=30, child_wall_seconds=40, child_regular_file_output_bytes=0,
            child_core_dump_bytes=0, hard_rss_limit='not_tested', inner_bpe_allocation_bound='unsupported'),
        limitations=['GPL obligations and the overall distribution plan remain to be resolved; process separation is not an automatic exception.',
            'The upstream BPE next_block grows an internal Vec before Read returns and does not enforce its declared unpacked size; outer pipe/output and CPU limits are not a hard internal allocation bound.',
            'Only known archive SHA identities are admitted. No untrusted-archive hardening claim; no hard RSS limit established.',
            'This upstream reader does not validate every entry hash before decoding; the selected plaintext SHA values were cross-checked against independent P0 copies.',
            'The uninstall archive was excluded; index agreement does not validate every metadata field or unselected payload.'])
    write_json(ROOT/'reports/p1/gpl-archive-report.json', report)
    print(json.dumps({k: report[k] for k in ['status', 'archive_count', 'index_name_count', 'payload_count', 'decoded_bytes']}))
    return 0 if okay else 2


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir', type=Path, required=True)
    p.add_argument('--assets-dir', type=Path, required=True)
    p.add_argument('--source', type=Path, default=ROOT/'.research/upstream/msg-tool')
    args = p.parse_args()
    game, assets, source = map(absolute, [args.game_dir, args.assets_dir, args.source])
    for path in [game, assets, source]:
        for out in [PRIVATE, TARGET, ROOT/'reports/p1']:
            if path == out or path in out.parents or out in path.parents:
                print(json.dumps(dict(status='unsupported', errors=[dict(code='gpl_input_output_overlap')])))
                return 2
    try:
        return run_probe(game, assets, source)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        report = dict(schema_version=1, status='unsupported', scope='Failed archive research run; no compatibility result',
            errors=[dict(category=type(exc).__name__, code=str(exc) if isinstance(exc, ProbeError) else type(exc).__name__)],
            original_files_written=False, original_execution='not_tested')
        print(json.dumps(report))
        write_json(ROOT/'reports/p1/gpl-archive-failure.json', report)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
