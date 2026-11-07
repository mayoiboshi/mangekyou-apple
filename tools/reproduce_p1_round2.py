#!/usr/bin/env python3
"""Reproduce second-round evidence while preserving the delivered P0 reports."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import ROOT, absolute, read_bounded, safe_member_name, safe_open, write_json
else:
    from mangekyou_p0 import ROOT, absolute, read_bounded, safe_member_name, safe_open, write_json


def snapshot_p0():
    return {p.name:hashlib.sha256(read_bounded(p)).hexdigest() for p in (ROOT/'reports/p0').glob('*.json')}


def test_counts(log,exit_code):
    ran=re.search(r'Ran (\d+) tests?',log);skipped=re.search(r'skipped=(\d+)',log)
    count=int(ran[1]) if ran else None;skip=int(skipped[1]) if skipped else 0
    return dict(status='verified' if exit_code==0 and count is not None else 'unsupported',
        tests_run=count,skipped=skip,passed=count-skip if count is not None and exit_code==0 else None,
        exit_code=exit_code)


def original_hashes(game):
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'));items=[]
    for f in inventory['files']:
        if not f.get('sha256'):continue
        path=game/safe_member_name(f['path'])
        try:
            digest=hashlib.sha256()
            with os.fdopen(safe_open(path),'rb') as stream:
                if os.fstat(stream.fileno()).st_size!=f['size']:raise ValueError('input_size_changed')
                while True:
                    chunk=stream.read(1024*1024)
                    if not chunk:break
                    digest.update(chunk)
            observed=digest.hexdigest()
            items.append(dict(source_file=f['path'],status='verified' if observed==f['sha256'] else 'unsupported',
                expected_sha256=f['sha256'],observed_sha256=observed))
        except (OSError,ValueError) as exc:
            items.append(dict(source_file=f['path'],status='unsupported',error=str(exc)))
    return dict(status='verified' if items and all(x['status']=='verified' for x in items) else 'unsupported',items=items)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir',type=Path,required=True)
    parser.add_argument('--exe',required=True,help='Relative plain EXE candidate path, never executed')
    parser.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    parser.add_argument('--ir-dir',type=Path,default=ROOT/'private/p1/ir')
    parser.add_argument('--evidence-dir',type=Path,default=ROOT/'private/p1-round2/native-reproduced')
    parser.add_argument('--collect-native',action='store_true',help='Start local REA static analysis; otherwise validate existing evidence')
    parser.add_argument('--rea-command',type=Path,default=Path.home()/'.local/bin/rea')
    parser.add_argument('--java-home',type=Path)
    parser.add_argument('--ghidra-dir',type=Path)
    args=parser.parse_args();before=snapshot_p0();private=ROOT/'private/p1-round2';out=ROOT/'reports/p1'
    commands=[('pe_probe',[sys.executable,str(ROOT/'tools/pe_probe.py'),'--game-dir',str(args.game_dir),'--exe',args.exe]),
              ('script_constraints',[sys.executable,str(ROOT/'tools/semantic_evidence.py'),'--game-dir',str(args.game_dir),
                '--assets-dir',str(args.assets_dir),'--ir-dir',str(args.ir_dir)])]
    if args.collect_native:
        cmd=[sys.executable,str(ROOT/'tools/rea_static.py'),'--game-dir',str(args.game_dir),'--exe',args.exe,
             '--output',str(args.evidence_dir),'--rea-command',str(args.rea_command)]
        if args.java_home:cmd+=['--java-home',str(args.java_home)]
        if args.ghidra_dir:cmd+=['--ghidra-dir',str(args.ghidra_dir)]
        commands.append(('native_collection',cmd))
    commands.append(('native_summary',[sys.executable,str(ROOT/'tools/native_summary.py'),'--evidence-dir',str(args.evidence_dir)]))
    jobs=[]
    for name,cmd in commands:
        try:
            p=subprocess.run(cmd,cwd=ROOT,capture_output=True,timeout=1800 if name=='native_collection' else 120)
            log=(p.stdout+p.stderr).decode('utf-8','replace')
            job=dict(name=name,status='verified' if p.returncode==0 else 'unsupported',exit_code=p.returncode,
                output_tail=log[-3000:])
        except (OSError,subprocess.SubprocessError) as exc:job=dict(name=name,status='unsupported',error=str(exc))
        jobs.append(job);print(json.dumps(dict(job=name,status=job['status'])),flush=True)
    tests=[]
    for label,executable in [('default_python','python3'),('research_python',sys.executable)]:
        try:
            p=subprocess.run([executable,'-m','unittest','discover','-s','tests','-v'],cwd=ROOT,capture_output=True,timeout=120)
            log=(p.stdout+p.stderr).decode('utf-8','replace');r=test_counts(log,p.returncode)
            r.update(environment=label,log=log);tests.append(r)
        except (OSError,subprocess.SubprocessError) as exc:tests.append(dict(environment=label,status='unsupported',error=str(exc)))
    try:
        p=subprocess.run([sys.executable,str(ROOT/'tools/verify_upstream.py'),'--output',str(private/'upstream-verification.json')],
            cwd=ROOT,capture_output=True,timeout=120)
        upstream=json.loads(read_bounded(private/'upstream-verification.json'))
        suite=next(c for c in upstream['checks'] if c['name']=='upstream_unittest_suite')
        tests.append(dict(environment='upstream',status=upstream['status'] if p.returncode==0 else 'unsupported',tests_run=suite['tests_run'],passed=suite['passed'],
            skipped=suite['skipped'],exit_code=p.returncode,scope='Synthetic and mocked upstream checks only; fixtures unavailable',
            verification_report='private/p1-round2/upstream-verification.json'))
    except (OSError,ValueError,KeyError,StopIteration,subprocess.SubprocessError) as exc:
        tests.append(dict(environment='upstream',status='unsupported',error=str(exc)))
    testing=dict(schema_version=1,dataset='synthetic',status='verified' if all(t['status']=='verified' for t in tests) else 'unsupported',
        suites=tests,skips_are_successes=False)
    write_json(out/'round2-tests.json',testing)
    integrity=original_hashes(absolute(args.game_dir));unchanged=before==snapshot_p0()
    good=all(j['status']=='verified' for j in jobs) and testing['status']=='verified' and unchanged and integrity['status']=='verified'
    report=dict(schema_version=1,dataset='real',stage='P1 script and native evidence round 2',
        status='verified' if good else 'unsupported',scope='This evidence round only; full port goal remains incomplete',
        jobs=jobs,tests='reports/p1/round2-tests.json',p0_reports_unchanged='verified' if unchanged else 'unsupported',
        original_integrity=integrity,original_files_written=False,external_game_data_uploads=False,
        game_execution='not_tested',p1_fully_complete=False,runtime_development_ready=False,
        full_native_port='not_tested',
        remaining=['Package and loose-file priority; clean release identity',
            'Delphi register conventions and complete command handlers',
            'Expression types, coercion, operator precedence, scopes and call/return behavior',
            'Save-state schema and restoration equivalence',
            'ABMP animation, blending, complete media and font behavior',
            'Native runtime, rendering/audio/input/save implementation and end-to-end game validation'])
    write_json(out/'round2-readiness.json',report)
    print(json.dumps(dict(status=report['status'],p0_reports_unchanged=unchanged,original_integrity=integrity['status'],runtime_ready=False)))
    return 0 if good else 2


if __name__=='__main__':raise SystemExit(main())
