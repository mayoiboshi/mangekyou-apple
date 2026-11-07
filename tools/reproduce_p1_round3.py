#!/usr/bin/env python3
"""Reproduce bounded precedence and function-tail research, preserving P0."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

from mangekyou_p0 import ROOT, absolute, read_bounded, write_json
from reproduce_p1_round2 import original_hashes, snapshot_p0, test_counts


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--collect-native',action='store_true')
    p.add_argument('--rea-command',type=Path,default=Path.home()/'.local/bin/rea')
    p.add_argument('--java-home',type=Path);p.add_argument('--ghidra-dir',type=Path)
    args=p.parse_args();before=snapshot_p0();private=ROOT/'private/p1-round3';output=ROOT/'reports/p1'
    commands=[]
    if args.collect_native:
        cmd=[sys.executable,str(ROOT/'tools/rea_static.py'),'--game-dir',str(args.game_dir),'--exe',args.exe,
             '--plan',str(ROOT/'docs/native-evidence-round3-plan.json'),'--output',str(private/'native-reproduced'),
             '--rea-command',str(args.rea_command)]
        if args.java_home:cmd+=['--java-home',str(args.java_home)]
        if args.ghidra_dir:cmd+=['--ghidra-dir',str(args.ghidra_dir)]
        commands.append(('native_collection',cmd))
    commands.extend([
        ('linear_windows',[sys.executable,str(ROOT/'tools/native_windows.py'),'--game-dir',str(args.game_dir),'--exe',args.exe]),
        ('precedence_evidence',[sys.executable,str(ROOT/'tools/p1_resolution.py')])])
    jobs=[]
    for name,cmd in commands:
        try:
            result=subprocess.run(cmd,cwd=ROOT,capture_output=True,timeout=1800 if name=='native_collection' else 120)
            text=(result.stdout+result.stderr).decode('utf-8','replace')
            job=dict(name=name,status='verified' if result.returncode==0 else 'unsupported',exit_code=result.returncode,
                output_tail=text[-3000:])
        except (OSError,subprocess.SubprocessError) as exc:job=dict(name=name,status='unsupported',error=str(exc))
        jobs.append(job);print(json.dumps(dict(job=name,status=job['status'])),flush=True)
    suites=[]
    for label,executable in [('default_python','python3'),('research_python',sys.executable)]:
        try:
            result=subprocess.run([executable,'-m','unittest','discover','-s','tests','-v'],cwd=ROOT,capture_output=True,timeout=120)
            text=(result.stdout+result.stderr).decode('utf-8','replace')
            test=test_counts(text,result.returncode);test.update(environment=label,log=text);suites.append(test)
        except (OSError,subprocess.SubprocessError) as exc:suites.append(dict(environment=label,status='unsupported',error=str(exc)))
    try:
        result=subprocess.run([sys.executable,str(ROOT/'tools/verify_upstream.py'),'--output',str(private/'upstream-verification.json')],
            cwd=ROOT,capture_output=True,timeout=120)
        upstream=json.loads(read_bounded(private/'upstream-verification.json'))
        suite=next(c for c in upstream['checks'] if c['name']=='upstream_unittest_suite')
        suites.append(dict(environment='upstream',status=upstream['status'] if result.returncode==0 else 'unsupported',tests_run=suite['tests_run'],passed=suite['passed'],
            skipped=suite['skipped'],exit_code=result.returncode,scope='Synthetic and mocked checks only'))
    except (OSError,ValueError,KeyError,StopIteration,subprocess.SubprocessError) as exc:
        suites.append(dict(environment='upstream',status='unsupported',error=str(exc)))
    tests=dict(schema_version=1,dataset='synthetic',status='verified' if all(s['status']=='verified' for s in suites) else 'unsupported',
        suites=suites,skips_are_successes=False)
    write_json(output/'round3-tests.json',tests)
    integrity=original_hashes(absolute(args.game_dir));unchanged=before==snapshot_p0()
    good=all(j['status']=='verified' for j in jobs) and tests['status']=='verified' and unchanged and integrity['status']=='verified'
    report=dict(schema_version=1,dataset='real',stage='P1 conditional precedence and function tails round 3',
        status='verified' if good else 'unsupported',scope='This research round only; full native port remains incomplete',
        jobs=jobs,tests='reports/p1/round3-tests.json',original_integrity=integrity,
        p0_reports_unchanged='verified' if unchanged else 'unsupported',original_files_written=False,
        external_game_data_uploads=False,game_execution='not_tested',p1_fully_complete=False,
        runtime_development_ready=False,full_native_port='not_tested',
        remaining=['Validate loader roots, alternate mounts, loose-file and cache conditions',
            'Restore Delphi cleanup tails and function boundaries before semantic contracts',
            'Expression types/precedence, full call/return and context lifetime',
            'Save schema, ABMP animation and full resource/media behavior',
            'Native runtime, rendering/audio/input/save implementation and end-to-end validation'])
    try:
        native=json.loads(read_bounded(output/'native-round3-report.json'))
        model=json.loads(read_bounded(output/'conditional-overlay-report.json'))
        report.update(native_coverage_status=native['coverage_status'],
            unsupported_native_observations=len(native['unsupported_observations']),
            failed_exploratory_queries=len(native['exploration_failures']),
            conditional_precedence_status=model['status'],conditional_paths=model['conditional_selected'])
    except (OSError,ValueError,KeyError) as exc:
        report['status']='unsupported';report['summary_error']=str(exc);good=False
    write_json(output/'round3-readiness.json',report)
    print(json.dumps(dict(status=report['status'],p0_reports_unchanged=unchanged,original_integrity=integrity['status'],runtime_ready=False)))
    return 0 if good else 2


if __name__=='__main__':raise SystemExit(main())
