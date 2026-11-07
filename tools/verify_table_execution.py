#!/usr/bin/env python3
"""Verify bounded native table execution on pinned research copies; no game program runs."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .verify_native_scripts import sha, fingerprints, compare_document, validate_trace
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from verify_native_scripts import sha, fingerprints, compare_document, validate_trace
    from control_state_analysis import processing_deadline


def main(stage='round26', report_name='table-execution-report.json', profile='experimental_static_contracts_v3',
         extra_evidence=(), extra_choices=()):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir', required=True, type=Path)
    p.add_argument('--script-file', required=True)
    args = p.parse_args()
    assets = absolute(args.assets_dir); entry = safe_member_name(args.script_file)
    private = ROOT/'private'/('p1-'+stage)
    if assets == private or assets in private.parents or private in assets.parents:
        raise ProbeError('table_execution_input_output_overlap')
    private.mkdir(parents=True, exist_ok=True)
    def sources():
        return {p.relative_to(ROOT).as_posix(): sha(read_bounded(p)) for p in sorted((ROOT/'native').rglob('*.swift')) if '.build' not in p.parts}
    source_sha = sources()
    compiled = subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'--product','mangekyou-script'],
        capture_output=True, timeout=120, cwd=ROOT)
    (private/'script-build.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode or sources() != source_sha:
        raise ProbeError('table_execution_build_or_source_changed')
    binary = (ROOT/'native/.build/debug/mangekyou-script').resolve()
    if ROOT/'native/.build' not in binary.parents or binary.name != 'mangekyou-script':
        raise ProbeError('table_execution_binary_location')
    executable = read_bounded(binary)
    if executable[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',executable,4)[0] != 0x0100000c:
        raise ProbeError('table_execution_binary_not_arm64')
    catalog_path = ROOT/'reports/p1/corpus-report.json'
    catalog_bytes = read_bounded(catalog_path); catalog = json.loads(catalog_bytes)
    items = catalog['items']; by_source = {i['source_file']: i for i in items}
    if not 1 <= len(items) <= 2000 or len(by_source) != len(items) or entry not in by_source:
        raise ProbeError('table_execution_corpus_identity')
    evidence = {}
    for name in ['table-native-report','table-helper-native-report','encoding-native-report',*extra_evidence]:
        path = ROOT/'reports/p1'/(name+'.json'); raw = read_bounded(path); doc = json.loads(raw)
        okay = doc.get('field_and_slot_binding') == 'verified' if name in {'index-binding-report','list-binding-report'} else doc.get('independent_collection',{}).get('status') == 'verified'
        if doc.get('errors') or not okay:
            raise ProbeError('table_execution_native_basis_missing')
        evidence[path.relative_to(ROOT).as_posix()] = sha(raw)
    def run(label, options):
        process = subprocess.run([str(binary),'--assets-dir',str(assets)]+options,capture_output=True,timeout=150,cwd=ROOT)
        (private/(label+'-stderr.log')).write_bytes(process.stderr)
        if process.returncode not in {0,2} or len(process.stdout)>32*1024*1024:
            raise ProbeError('table_execution_process_failure')
        value = json.loads(process.stdout); write_json(private/(label+'.json'),value)
        return process.returncode, value
    _, native = run('corpus',['--manifest',str(catalog_path)])
    records = native['reports']; native_by_source = {r['sourceFile']: r for r in records}
    if len(records) != len(items) or set(native_by_source) != set(by_source):
        raise ProbeError('table_execution_corpus_coverage')
    total = 0; compared = []
    def lookup(name):
        name = safe_member_name(name)
        if name not in by_source:
            raise ProbeError('table_execution_unpinned_trace_source')
        data = read_bounded(assets/name,16*1024*1024)
        if sha(data) != by_source[name]['sha256']:
            raise ProbeError('table_execution_trace_source_identity')
        _, doc = fingerprints(data,name)
        return data, doc
    with processing_deadline(120):
        for item in items:
            name = safe_member_name(item['source_file']); data = read_bounded(assets/name,16*1024*1024); total += len(data)
            if total > 128*1024*1024 or sha(data) != item['sha256']:
                raise ProbeError('table_execution_corpus_bytes_or_identity')
            result, _ = compare_document(native_by_source[name],data,name); compared.append(result)
    if any(r['status'] != 'verified' for r in compared):
        raise ProbeError('table_execution_lexical_mismatch')
    root, root_document = lookup(entry)
    choices = [('strict_no_preference',[]),('module_only',['data8.pack/misc/value.s']),
        ('explicit_data7',['data7.pack/misc/value.s','data7.pack/avg/setting.txt','data7.pack/avg/projectsetting.txt']),
        ('explicit_data8',['data8.pack/misc/value.s','data8.pack/avg/setting.txt','data8.pack/avg/projectsetting.txt'])]
    choices += list(extra_choices)
    scenarios = []
    for label, selected in choices:
        if any(name not in by_source for name in selected):
            raise ProbeError('table_execution_selected_source_missing')
        options = ['--script',entry,'--experimental-run','--catalog',str(catalog_path)]
        for source in selected:
            options += ['--select-source',source]
        exit_code, value = run(label,options)
        if len(value['reports']) != 1 or not value['reports'][0].get('machine'):
            raise ProbeError('table_execution_machine_not_observed')
        machine = value['reports'][0]['machine']
        if machine.get('profile') != profile:
            raise ProbeError('execution_profile_does_not_match_verifier')
        with processing_deadline(120):
            references = validate_trace(machine,root,entry,root_document,source_lookup=lookup)
        scenarios.append(dict(name=label, selected_sources=[dict(source_file=s,source_sha256=by_source[s]['sha256']) for s in selected],
            cli_exit_code=exit_code, byte_reference_status='verified', byte_reference_count=references,
            action_counts=dict(Counter(t['action'] for t in machine['trace'])), machine=machine,
            scope='One bounded experimental path; an unsupported stop is retained, not counted as full startup'))
    if sources() != source_sha:
        raise ProbeError('table_execution_sources_changed_after_run')
    report = dict(schema_version=1,status='inferred',dataset='real',
        scope='Pinned-copy experimental '+profile+' execution and byte/model cross-check; not original-engine equivalence or complete game startup',
        native_binary_sha256=sha(executable),native_source_sha256=source_sha,native_evidence=evidence,
        corpus_report_sha256=sha(catalog_bytes),physical_corpus_files=len(compared),
        lexical_crosscheck=dict(status='verified',mismatch_count=0,records=sum(r['records'] for r in compared)),
        scenarios=scenarios,all_versions_preserved=True,original_engine_equivalence='not_tested',
        windows_locale_and_codepage_equivalence='not_tested',physical_archive_access='unsupported',
        table_auxiliary_result_flags='not_tested',original_files_written=False,external_game_data_uploads=False,
        commercial_text_in_public_reports=False,full_game_compatibility='not_tested')
    write_json(ROOT/'reports/p1'/report_name,report)
    print(json.dumps(dict(status='inferred',scenarios=[dict(name=s['name'],steps=s['machine']['steps'],
        stop=s['machine']['stopReason'],tables=s['machine']['tableObjectCount']) for s in scenarios])))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
