#!/usr/bin/env python3
"""Bind retained CUA metadata observations to the checked app/CLI reports; does not itself automate UI."""
import argparse
import hashlib
import json
import plistlib
from pathlib import Path
if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, write_json
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, write_json


def match_final(observed, scenario):
    m=scenario['machine'];location=m['currentLocation']
    wanted={k:m[k] for k in ['steps','callDepth','moduleSnapshotCount','tableObjectCount','tableEntryCount','listObjectCount','listLineCount','stopReason']}
    wanted.update({k:location[k] for k in ['sourceFile','lineNumber','byteOffset']})
    wanted['command']=m['trace'][-1]['command']
    if observed!=wanted or any(type(observed[k]) is not type(v) for k,v in wanted.items()):raise ProbeError('gui_observation_final_metadata_mismatch')
    return wanted


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--observations',required=True,type=Path);a=p.parse_args()
    source=absolute(a.observations)
    if ROOT/'private' not in source.parents:raise ProbeError('gui_observations_must_be_private')
    raw=read_bounded(source,64*1024);observed=json.loads(raw)
    if observed.get('schema_version')!=1 or observed.get('evidence_kind')!='observed_cua_accessibility':raise ProbeError('gui_observation_kind')
    if set(observed)!={'schema_version','evidence_kind','capture_method','app_version','observed_step_sequence','selected_sources','final'}:
        raise ProbeError('gui_observation_unapproved_fields')
    steps=observed['observed_step_sequence']
    if not isinstance(steps,list) or not 1<=len(steps)<=16 or any(type(s) is not int or not 0<=s<=100000 for s in steps) or steps!=sorted(set(steps)):
        raise ProbeError('gui_observation_step_sequence')
    cli_path=ROOT/'reports/p1/list-execution-report.json';cli_raw=read_bounded(cli_path);cli=json.loads(cli_raw)
    scenario=next(s for s in cli['scenarios'] if s['name']=='explicit_data8_list_file')
    final=match_final(observed['final'],scenario)
    if steps[-1]!=final['steps']:raise ProbeError('gui_observation_final_step')
    choices=observed['selected_sources'];expected={s['source_file']:s['source_sha256'] for s in scenario['selected_sources']}
    if len(choices)!=len(expected) or {s['source_file'] for s in choices}!=set(expected):raise ProbeError('gui_observation_choices')
    for row in choices:
        if set(row)!={'source_file','sha256_prefix'} or len(row['sha256_prefix'])!=12 or not expected[row['source_file']].startswith(row['sha256_prefix']):
            raise ProbeError('gui_observation_choice_digest')
    app_path=ROOT/'reports/p1/native-app-round28.json';app_raw=read_bounded(app_path);app=json.loads(app_raw)
    binary=read_bounded(ROOT/'build/Mangekyou.app/Contents/MacOS/Mangekyou')
    info=plistlib.loads(read_bounded(ROOT/'build/Mangekyou.app/Contents/Info.plist',64*1024))
    if observed['app_version']!=info['CFBundleShortVersionString']:raise ProbeError('gui_observation_app_version')
    if hashlib.sha256(binary).hexdigest()!=app['binary_sha256'] or app['source_sha256']!=cli['native_source_sha256']:
        raise ProbeError('gui_observation_app_source_identity')
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='One actual CUA accessibility replay with explicit data8 sources, retained as metadata; CLI comparison checks final state only',
        ui_observation_status='verified',metadata_crosscheck_status='verified',app_version=observed['app_version'],
        binary_sha256=app['binary_sha256'],retained_observation_sha256=hashlib.sha256(raw).hexdigest(),
        observation_kind=observed['evidence_kind'],capture_method=observed['capture_method'],
        observed_step_sequence=steps,selected_sources=choices,final=final,
        cli_report_sha256=hashlib.sha256(cli_raw).hexdigest(),app_report_sha256=hashlib.sha256(app_raw).hexdigest(),
        ui_capture_automation_in_this_command=False,all_gui_paths='not_tested',original_engine_equivalence='not_tested',
        full_game_compatibility='not_tested',original_files_written=False,external_game_data_uploads=False)
    write_json(ROOT/'reports/p1/gui-replay-round28.json',report)
    print(json.dumps(dict(status='inferred',ui_observation='verified',steps=final['steps'],list_lines=final['listLineCount'])));return 0


if __name__=='__main__':raise SystemExit(main())
