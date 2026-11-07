#!/usr/bin/env python3
"""Run the native CLI to its next real stop, with an explicit experimental source cohort."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
from verify_native_scripts import fingerprints, validate_trace
from control_state_analysis import processing_deadline


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',required=True,type=Path);p.add_argument('--script',default='data0.pack/startup.s')
    p.add_argument('--source-cohort',required=True,help='Explicit experiment, e.g. data8; not original package precedence')
    p.add_argument('--stage',default='round29');a=p.parse_args()
    if not re.fullmatch(r'data(?:[0-9]|[12][0-9]|3[01])',a.source_cohort) or not re.fullmatch(r'round[1-9][0-9]*',a.stage):raise ProbeError('cli_progress_invalid_cohort_or_stage')
    assets=absolute(a.assets_dir);script=safe_member_name(a.script);private=ROOT/'private'/('p1-'+a.stage)/('cli-progress-'+a.source_cohort)
    if assets==private or assets in private.parents or private in assets.parents:raise ProbeError('cli_progress_input_output_overlap')
    private.mkdir(parents=True,exist_ok=True)
    compiled_sources=[ROOT/'native/Package.swift',*sorted((ROOT/'native/Sources').rglob('*.swift'))]
    sources={s.relative_to(ROOT).as_posix():sha(read_bounded(s)) for s in compiled_sources}
    compiled=subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'--product','mangekyou-script'],capture_output=True,timeout=120,cwd=ROOT)
    (private/'build.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise ProbeError('cli_progress_build_failed')
    binary=(ROOT/'native/.build/debug/mangekyou-script').resolve();raw=read_bounded(binary)
    if ROOT/'native/.build' not in binary.parents or raw[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',raw,4)[0]!=0x0100000c:raise ProbeError('cli_progress_binary_not_owned_arm64')
    binary_sha=sha(raw);manifest=ROOT/'reports/p1/corpus-report.json';manifest_bytes=read_bounded(manifest)
    items=json.loads(manifest_bytes)['items'];index={i['source_file']:i for i in items}
    if not 1<=len(items)<=2000 or len(index)!=len(items) or script not in index:raise ProbeError('cli_progress_catalog_identity')
    cache={};total=0
    def lookup(name):
        nonlocal total
        name=safe_member_name(name)
        if name not in index:raise ProbeError('cli_progress_source_not_in_catalog')
        if name not in cache:
            data=read_bounded(assets/name,16*1024*1024);total+=len(data)
            if total>128*1024*1024 or sha(data)!=index[name]['sha256']:raise ProbeError('cli_progress_source_identity_or_budget')
            _,document=fingerprints(data,name);cache[name]=(data,document)
        return cache[name]
    root,root_doc=lookup(script);selected=[];attempts=[];final=None
    for attempt in range(33):
        command=[str(binary),'--assets-dir',str(assets),'--script',script,'--experimental-run','--catalog',str(manifest)]
        for source in selected:command+=['--select-source',source]
        run=subprocess.run(command,capture_output=True,timeout=150,cwd=ROOT)
        (private/f'attempt-{attempt:02}-stderr.log').write_bytes(run.stderr)
        if run.returncode not in {0,2} or len(run.stdout)>32*1024*1024:raise ProbeError('cli_progress_process_failure')
        document=json.loads(run.stdout);write_json(private/f'attempt-{attempt:02}.json',document)
        record=document['reports'][0];machine=record.get('machine')
        if not machine:raise ProbeError('cli_progress_program_preparation_failed')
        with processing_deadline(120):references=validate_trace(machine,root,script,root_doc,source_lookup=lookup)
        row=dict(attempt=attempt,steps=machine['steps'],phase=machine['phase'],stop_reason=machine.get('stopReason'),
            location=machine.get('currentLocation'),source_byte_references=references)
        attempts.append(row);final=machine
        if machine.get('stopReason')!='ambiguous_module_variants':break
        candidates=record.get('moduleCandidates') or []
        choices=[r for r in candidates if r['source_file'].startswith(a.source_cohort+'.pack/')]
        if len(choices)!=1:raise ProbeError('cli_progress_cohort_does_not_select_one_candidate')
        choice=choices[0];source=choice['source_file']
        if source in selected or source not in index or choice['sha256']!=index[source]['sha256']:raise ProbeError('cli_progress_candidate_identity_or_cycle')
        lookup(source)
        selected.append(source);row['explicit_selection']=dict(source_file=source,sha256=choice['sha256'])
    else:raise ProbeError('cli_progress_selection_limit')
    if sha(read_bounded(binary))!=binary_sha or any(sha(read_bounded(ROOT/n))!=h for n,h in sources.items()):raise ProbeError('cli_progress_sources_changed')
    report=dict(schema_version=1,status='inferred',dataset='real',scope='One explicit source-cohort CLI path; no original package winner or complete-game claim',
        profile=final['profile'],source_cohort=a.source_cohort,source_choice_is_original_precedence='not_tested',
        native_binary_sha256=binary_sha,native_source_sha256=sources,corpus_report_sha256=sha(manifest_bytes),
        attempts=attempts,selected_sources=[dict(source_file=s,sha256=index[s]['sha256']) for s in selected],
        phase=final['phase'],steps=final['steps'],stop_reason=final.get('stopReason'),location=final.get('currentLocation'),
        terminal_command=final['trace'][-1].get('command') if final['trace'] else None,
        source_snapshot_count=final.get('sourceSnapshotCount'),loaded_programs=final.get('moduleSnapshotCount'),
        action_counts=dict(Counter(r['action'] for r in final['trace'])),trace_sha256=sha(json.dumps(final,sort_keys=True).encode()),
        source_byte_reference_status='verified',checked_sources=len(cache),checked_source_bytes=total,
        full_corpus_retested=False,original_engine_equivalence='not_tested',full_game_compatibility='not_tested',
        original_files_written=False,external_game_data_uploads=False,private_trace_directory=private.relative_to(ROOT).as_posix())
    write_json(ROOT/'reports/p1'/('cli-progress-'+a.stage+'-'+a.source_cohort+'.json'),report)
    print(json.dumps(dict(steps=final['steps'],stop=final.get('stopReason'),selected_sources=len(selected),checked_sources=len(cache))))
    return 0


if __name__=='__main__':raise SystemExit(main())
