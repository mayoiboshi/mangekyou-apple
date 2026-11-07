#!/usr/bin/env python3
"""Reproduce P1 static evidence and synthetic tests, without changing P0 reports."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from mangekyou_p0 import ROOT, write_json


def snapshots():
    return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'reports/p0').glob('*.json')}


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--game-dir',type=Path)
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--samples',type=Path,default=ROOT/'private/real-p0/sample-report.json')
    ap.add_argument('--archives',type=Path,default=ROOT/'private/real-p0/archive-report.json')
    ap.add_argument('--upstream-source',type=Path,default=ROOT/'.research/upstream/qlie-unpack')
    args=ap.parse_args();output=ROOT/'reports/p1';before=snapshots();jobs=[]
    commands=[('static_corpus',[sys.executable,str(ROOT/'tools/p1_static.py'),
        '--assets-dir',str(args.assets_dir),'--samples',str(args.samples),'--archives',str(args.archives)]
        +(['--game-dir',str(args.game_dir)] if args.game_dir else [])),
        ('abmp_containers',[sys.executable,str(ROOT/'tools/abmp_probe.py'),'--assets-dir',str(args.assets_dir),
            '--samples',str(args.samples),'--source',str(args.upstream_source)])]
    for name,command in commands:
        try:
            proc=subprocess.run(command,cwd=ROOT,capture_output=True,timeout=120)
            job=dict(name=name,status='verified' if proc.returncode==0 else 'unsupported',
                exit_code=proc.returncode,stdout=proc.stdout.decode('utf-8','replace')[-3000:],
                stderr=proc.stderr.decode('utf-8','replace')[-3000:])
        except (OSError,subprocess.SubprocessError) as exc:
            job=dict(name=name,status='unsupported',error=str(exc))
        jobs.append(job)
        print(json.dumps(dict(job=name,status=job['status'])),flush=True)
    proc=subprocess.run([sys.executable,'-m','unittest','discover','-s','tests','-v'],cwd=ROOT,
        capture_output=True,timeout=60)
    log=(proc.stdout+proc.stderr).decode('utf-8','replace')
    ran=re.search(r'Ran (\d+) tests?',log);skipped=re.search(r'skipped=(\d+)',log)
    count=int(ran[1]) if ran else None;skip=int(skipped[1]) if skipped else 0
    tests=dict(schema_version=1,dataset='synthetic',status='verified' if proc.returncode==0 else 'unsupported',
        python=sys.version.split()[0],tests_run=count,skipped=skip,passed=count-skip if count is not None and proc.returncode==0 else None,
        exit_code=proc.returncode,log=log,scope='P0+P1 tests; no commercial fixtures')
    write_json(output/'test-results.json',tests)
    ready=dict(schema_version=1,dataset='real',stage='P1 static foundation round 1',
        status='verified' if all(j['status']=='verified' for j in jobs) and proc.returncode==0 else 'unsupported',
        p1_fully_complete=False,runtime_development_ready=False,tests_run=count,jobs=jobs,
        p0_reports_unchanged='verified' if before==snapshots() else 'unsupported',
        original_files_written=False,game_execution='not_tested',external_game_data_uploads=False,
        remaining=['Load/patch precedence','Command execution and expression model','Variable scopes and save state',
            'ABMP opaque data/parameters and animation semantics','Original engine rendering/timing equivalence','Third-party licensing for distribution'])
    if all(j['status']=='verified' for j in jobs):
        corpus=json.loads((output/'corpus-report.json').read_text())
        overlay=json.loads((output/'overlay-report.json').read_text())
        symbols=json.loads((output/'symbol-report.json').read_text())
        assets=json.loads((output/'resource-report.json').read_text())
        abmp=json.loads((output/'abmp-report.json').read_text())
        ready.update(files=corpus['files'],inline_command_lines=corpus['inline_command_lines'],
            original_pack_integrity=corpus['original_archive_integrity_status'],
            changed_duplicate_texts=overlay['comparison_counts'].get('normalized_text_changed',0),
            unresolved_label_literals=symbols['label_reference_status_counts'].get('unsupported',0),
            dynamic_control_targets=symbols['dynamic_control_target_count'],
            unresolved_resource_literals=assets['unresolved_literal_count'],
            unknown_abmp_members=abmp['format_counts'].get('Unknown',0))
    write_json(output/'readiness.json',ready)
    print(json.dumps(dict(status=ready['status'],tests=count,skipped=skip,p0_reports_unchanged=ready['p0_reports_unchanged'],runtime_ready=False)))
    return 0 if ready['status']=='verified' and ready['p0_reports_unchanged']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
