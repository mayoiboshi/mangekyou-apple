#!/usr/bin/env python3
"""Verify pinned multi-file experimental execution without claiming game compatibility."""
import argparse
import json
from pathlib import Path
import struct
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .verify_native_scripts import sha,compare_document,fingerprints,validate_trace
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from verify_native_scripts import sha,compare_document,fingerprints,validate_trace
    from control_state_analysis import processing_deadline


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',required=True,type=Path);p.add_argument('--script-file',required=True)
    p.add_argument('--compare-source',action='append',default=[])
    args=p.parse_args();assets=absolute(args.assets_dir);relative=safe_member_name(args.script_file)
    choices=[safe_member_name(s) for s in args.compare_source]
    if len(choices)>8 or len(choices)!=len(set(choices)):raise ProbeError('module_comparison_choice_limit_or_duplicate')
    private=ROOT/'private/p1-round22';private.mkdir(parents=True,exist_ok=True)
    if assets==private or assets in private.parents or private in assets.parents:raise ProbeError('module_verification_input_output_overlap')
    native_bytes=read_bounded(ROOT/'reports/p1/module-native-report.json');native=json.loads(native_bytes)
    required={'second_field_read','self_or_nil_default','file_value_conversion','reader_receives_file_and_label','reader_self_load_gate','reader_label_call'}
    if native.get('errors') or native.get('independent_collection',{}).get('status')!='verified' or not required<=set(
        r['id'] for r in native['observations'] if r['status']=='verified'):raise ProbeError('module_native_evidence_missing')
    def sources():
        return {path.relative_to(ROOT).as_posix():sha(read_bounded(path)) for path in sorted((ROOT/'native').rglob('*.swift')) if '.build' not in path.parts}
    source_identity=sources()
    built=subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'--product','mangekyou-script'],capture_output=True,timeout=120,cwd=ROOT)
    (private/'script-build.log').write_bytes(built.stdout+built.stderr)
    if built.returncode or sources()!=source_identity:raise ProbeError('module_binary_build_or_source_identity')
    binary=(ROOT/'native/.build/debug/mangekyou-script').resolve()
    if ROOT/'native/.build' not in binary.parents or binary.name!='mangekyou-script':raise ProbeError('module_binary_location')
    program=read_bounded(binary)
    if program[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',program,4)[0]!=0x0100000c:raise ProbeError('module_binary_not_ARM64_MachO')
    catalog_path=ROOT/'reports/p1/corpus-report.json';catalog_bytes=read_bounded(catalog_path);catalog=json.loads(catalog_bytes)
    items=catalog['items'];by_source={r['source_file']:r for r in items}
    if not 1<=len(items)<=2000 or len(by_source)!=len(items) or relative not in by_source or any(s not in by_source for s in choices):
        raise ProbeError('module_catalog_or_selected_source_identity')
    def run(label,options):
        process=subprocess.run([str(binary),'--assets-dir',str(assets)]+options,capture_output=True,timeout=150,cwd=ROOT)
        (private/(label+'-stderr.log')).write_bytes(process.stderr)
        if process.returncode not in {0,2} or len(process.stdout)>32*1024*1024:raise ProbeError('module_native_process_failure')
        report=json.loads(process.stdout);write_json(private/(label+'.json'),report)
        return process.returncode,report
    _,corpus=run('corpus',['--manifest',str(catalog_path)])
    rows=corpus['reports'];native_by_source={r['sourceFile']:r for r in rows}
    if len(rows)!=len(items) or set(native_by_source)!=set(by_source):raise ProbeError('module_native_corpus_coverage')
    comparisons=[];total=0;scenarios=[]
    def lookup(name):
        name=safe_member_name(name)
        if name not in by_source:raise ProbeError('trace_module_not_in_locked_corpus')
        data=read_bounded(assets/name,16*1024*1024)
        if sha(data)!=by_source[name]['sha256']:raise ProbeError('trace_module_source_identity')
        _,document=fingerprints(data,name)
        return data,document
    with processing_deadline(120):
        for item in items:
            name=safe_member_name(item['source_file']);data=read_bounded(assets/name,16*1024*1024);total+=len(data)
            if total>128*1024*1024 or sha(data)!=item['sha256']:raise ProbeError('module_corpus_identity_or_size')
            checked,_=compare_document(native_by_source[name],data,name);comparisons.append(checked)
    data,document=lookup(relative)
    for index,choice in enumerate([None]+choices):
        options=['--script',relative,'--experimental-run','--catalog',str(catalog_path)]
        if choice:options+=['--select-source',choice]
        code,run_report=run('execution-'+str(index),options)
        if len(run_report['reports'])!=1:raise ProbeError('module_execution_result_count')
        row=run_report['reports'][0];checked,_=compare_document(row,data,relative)
        if checked['status']!='verified' or not row.get('machine'):raise ProbeError('module_execution_source_or_machine_missing')
        machine=row['machine'];refs=validate_trace(machine,data,relative,document,source_lookup=lookup)
        crossed=any(r['action']=='module_call' for r in machine['trace'])
        scenarios.append(dict(name='strict_no_preference' if choice is None else 'explicit_source_'+str(index),
            selected_source_file=choice,selected_source_sha256=by_source[choice]['sha256'] if choice else None,
            cli_exit_code=code,byte_reference_status='verified',byte_reference_count=refs,
            cross_file_call_status='verified' if crossed else 'unsupported',
            scope='One bounded candidate path; unsupported stop is preserved, not counted as full startup success',machine=machine))
    okay=all(c['status']=='verified' for c in comparisons) and all(s['cross_file_call_status']=='verified' for s in scenarios[1:])
    report=dict(schema_version=1,status='inferred' if okay else 'unsupported',dataset='real',
        scope='Explicit module binding and version-choice experiments only; full game startup and original execution equivalence not_tested',
        native_evidence='reports/p1/module-native-report.json',native_evidence_sha256=sha(native_bytes),
        native_binary_sha256=sha(program),native_source_sha256=source_identity,catalog_metadata_sha256=sha(catalog_bytes),
        physical_corpus_files=len(items),all_versions_preserved=True,
        lexical_crosscheck=dict(status='verified' if all(c['status']=='verified' for c in comparisons) else 'unsupported',
            files=len(comparisons),mismatch_count=sum(c['status']!='verified' for c in comparisons),
            records=sum(c['records'] for c in comparisons),scope='Agreement with project Python model, not independent engine grammar proof'),
        selected_entry=dict(source_file=relative,source_sha256=sha(data)),scenarios=scenarios,
        original_engine_equivalence='not_tested',original_package_winner='not_tested',full_game_compatibility='not_tested',
        original_files_written=False,external_game_data_uploads=False,commercial_text_in_public_report=False)
    write_json(private/'crosscheck.json',dict(items=comparisons))
    write_json(ROOT/'reports/p1/module-execution-report.json',report)
    print(json.dumps(dict(status=report['status'],files=len(items),scenarios=[dict(name=s['name'],
        phase=s['machine']['phase'],steps=s['machine']['steps'],reason=s['machine'].get('stopReason'),
        crossed=s['cross_file_call_status']) for s in scenarios])))
    return 0 if okay else 2


if __name__=='__main__':raise SystemExit(main())
