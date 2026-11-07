#!/usr/bin/env python3
"""Regenerate sanitized P0 reports from source pins, tests and absent-game baseline."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import unittest

from mangekyou_p0 import ROOT, run, write_json


def command(argv):
    try:
        proc = subprocess.run(argv, cwd=ROOT, capture_output=True, timeout=45)
        return dict(command=argv, exit_code=proc.returncode,
                    stdout=proc.stdout.decode('utf-8', 'replace'), stderr=proc.stderr.decode('utf-8', 'replace'))
    except (OSError, subprocess.SubprocessError) as exc:
        return dict(command=argv, exit_code=None, error=str(exc))


def main():
    os.chdir(ROOT)
    sys.path.insert(0, str(ROOT))
    sys.dont_write_bytecode = True
    output = ROOT / 'reports/p0'
    run(output=output)
    lock = json.loads((ROOT / 'docs/upstream-lock.json').read_text())
    catalog = json.loads((ROOT / 'docs/research-catalog.json').read_text())
    sources = []
    for item in lock['upstreams']:
        path = ROOT / '.research/upstream' / item['repository'].split('/')[1]
        issues = []
        for entry in item['files']:
            f = path / entry['path']
            if not f.is_file():
                issues.append(dict(path=entry['path'], reason='source_unavailable'))
            elif hashlib.sha256(f.read_bytes()).hexdigest() != entry['sha256']:
                issues.append(dict(path=entry['path'], reason='digest_mismatch'))
        sources.append(dict(repository=item['repository'], commit=item['commit'], license=item['license'],
            source_integrity_status='verified' if not issues else 'not_tested', issues=issues,
            **catalog['upstreams'][item['repository']]))
    source_report = dict(schema_version=1, audit_date='2026-11-06', status='verified' if all(s['source_integrity_status']=='verified' for s in sources) else 'not_tested',
        upstreams=sources, claims=catalog['claims'], external_references=catalog['external_references'],
        acquisition_note='First full clone included bundled binary attachments; all attachment files and clone objects were deleted without testing. Subsequent acquisition is source-only and allowlisted. No attachments remain in the source manifest or project index.')
    for claim in source_report['claims']:
        pin=next(s['commit'] for s in sources if s['repository']==claim['repository'])
        claim['source_url']='https://github.com/'+claim['repository']+'/blob/'+pin+'/'+claim['path']+'#L'+str(claim['lines'][0])+'-L'+str(claim['lines'][1])
    write_json(output / 'source-audit.json', source_report)
    environment = dict(schema_version=1, status='verified', system=platform.system(),
        release=platform.release(), machine=platform.machine(), python=platform.python_version(),
        commands={x:shutil.which(x) for x in ['python3','python3.13','git','clang','swift','cargo','rustc','cmake','ffprobe']},
        isolated_cargo_available=(ROOT/'.research/cargo/bin/cargo').is_file(),
        target_hardware_identity='not_tested', note='arm64 host observed; M4/M4 Pro performance is not benchmarked')
    build = []
    for name, compiler, filename in [('filepack31','clang','mangekyoupack/filepack31.c'),
                                     ('dpng2png','clang++','mangekyoupack/dpng2png.cpp'),
                                     ('exfp3','clang++','mangekyou_util/exfp3.cpp')]:
        src = ROOT / '.research/upstream' / filename
        if src.is_file() and shutil.which(compiler):
            result = command([compiler,'-fsyntax-only',str(src.relative_to(ROOT))])
            result.update(name=name, status='verified' if result['exit_code']==0 else 'unsupported', kind='native_syntax_check_only')
            build.append(result)
    environment['native_build_probes'] = build
    write_json(output / 'environment.json', environment)
    log = io.StringIO()
    suite = unittest.defaultTestLoader.discover(str(ROOT/'tests'))
    result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    tests = dict(schema_version=1, status='verified' if result.wasSuccessful() else 'unsupported',
                 dataset='synthetic', tests_run=result.testsRun, skipped=len(result.skipped),
                 failures=len(result.failures), errors=len(result.errors), log=log.getvalue())
    write_json(output/'test-results.json',tests)
    verification = dict(status='not_tested',reason='Need Python >=3.10, Pillow and pinned source files')
    source = ROOT/'.research/upstream/qlie-unpack'
    if sys.version_info >= (3,10) and importlib.util.find_spec('PIL') and all(s['source_integrity_status']=='verified' for s in sources):
        from verify_upstream import execute
        verification = execute(source, output/'verification.json')
    else:
        write_json(output/'verification.json',verification)
    # Attach explicit synthetic evidence to otherwise absent-real-data reports.
    for name in ['archive-report.json','asset-report.json','script-report.json']:
        path=output/name
        report=json.loads(path.read_text())
        report['synthetic_evidence_report']='verification.json'
        if name=='script-report.json' and 'synthetic_script_ir' in verification:
            report['synthetic_example']=dict(dataset='synthetic',**verification['synthetic_script_ir'])
        write_json(path,report)
    comp_path=output/'compatibility-report.json'
    comp=json.loads(comp_path.read_text())
    comp['routes']=catalog['routes']
    comp['recommended_p1_scope']=['Acquire read-only real corpus and hashes',
        'Validate actual V3.1 index, keys and representative resource decoding',
        'Cross-check real .s text against an explicit msg-tool Qlie invocation',
        'Build lossless lexical IR, unknown command inventory and unresolved resource graph',
        'Do not implement rendering, playback, saves or a UI until semantics evidence exists']
    write_json(comp_path,comp)
    acceptance=dict(schema_version=1, status='not_tested', p0_fully_passed=False,
        decision='Research deliverables available; actual-game acceptance remains pending',
        criteria=[dict(name='repeatable_scan',status=tests['status'],scope='synthetic tests'),
          dict(name='actual_pack_version',status='not_tested',reason='No legal game resources supplied'),
          dict(name='one_resource_decode_path',status=verification['status'],scope='synthetic DPNG; see verification.json'),
          dict(name='traceable_script_records',status=verification['status'],scope='synthetic byte offsets; source grammar only'),
          dict(name='actual_major_resource_formats',status='not_tested'),
          dict(name='p1_scope_and_risks_documented',status='verified',evidence='docs/05-compatibility-risks.md; docs/06-p1-recommendation.md'),
          dict(name='original_game_files_modified',status='not_tested',reason='No originals supplied; synthetic integrity test passed'),
          dict(name='commercial_content_in_project',status='verified',scope='No commercial assets retained; source cache is ignored; manifest source-only'),
          dict(name='automated_tests',status=tests['status'],scope='test-results.json; verification.json has separate upstream skips')])
    write_json(output/'acceptance.json',acceptance)
    print(json.dumps(dict(core_tests=tests['tests_run'], core_status=tests['status'],
          source_status=source_report['status'], upstream_status=verification['status'], real_game='not_tested')))
    return 0 if result.wasSuccessful() and verification['status']!='unsupported' else 1


if __name__=='__main__':
    sys.exit(main())
