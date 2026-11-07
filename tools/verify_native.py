#!/usr/bin/env python3
"""Verify the native foundation against owned tests and existing bounded copies."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/native-app-foundation.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('native_summary_must_be_P1')
    private=ROOT/'private/native-foundation';private.mkdir(exist_ok=True,parents=True)
    for source in [game,assets]:
        if source==private or source in private.parents or private in source.parents:raise ProbeError('native_verification_overlap')
    build=json.loads(read_bounded(private/'build-report.json'))
    binary=ROOT/'build/Mangekyou.app/Contents/MacOS/Mangekyou'
    if build.get('status')!='verified' or sha(read_bounded(binary))!=build['binary_sha256']:raise ProbeError('native_build_identity')
    current={path.relative_to(ROOT).as_posix():sha(read_bounded(path)) for path in sorted((ROOT/'native').rglob('*.swift')) if '.build' not in path.parts}
    if build['source_sha256']!=current:raise ProbeError('native_build_sources_changed')
    test=subprocess.run(['swift','test','--package-path',str(ROOT/'native')],capture_output=True,timeout=120,cwd=ROOT)
    log=(test.stdout+test.stderr).decode('utf-8','replace');(private/'swift-tests.log').write_text(log)
    matches=re.findall(r'Executed (\d+) tests?, with (\d+) failures?',log)
    if test.returncode or not matches or any(int(f)>0 for _,f in matches):raise ProbeError('native_unit_tests_failed_or_unparsed')
    test_count=max(int(n) for n,_ in matches)
    path_query=subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'--show-bin-path'],capture_output=True,check=True,timeout=30,cwd=ROOT)
    bin_dir=absolute(path_query.stdout.decode().strip())
    if ROOT/'native/.build' not in bin_dir.parents:raise ProbeError('native_inspector_outside_build_tree')
    documents={}
    for label,flag,root,extra in [('game','--game-dir',game,[]),('assets','--assets-dir',assets,['--verify-images'])]:
        proc=subprocess.run([str(bin_dir/'mangekyou-inspect'),flag,str(root)]+extra,capture_output=True,timeout=90,cwd=ROOT)
        (private/(label+'-inspector-stderr.log')).write_bytes(proc.stderr)
        if proc.returncode:raise ProbeError('native_'+label+'_inspector_failed')
        document=json.loads(proc.stdout);write_json(private/(label+'-inventory.json'),document);documents[label]=document
    inventory=documents['game']['inventory'];p0=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if {f['relativePath']:f['byteCount'] for f in inventory['files']}!={f['path']:f['size'] for f in p0['files']}:
        raise ProbeError('native_game_inventory_does_not_match_P0')
    manifest=json.loads(read_bounded(ROOT/'reports/p0/asset-report.json'))
    expected={r['path']:r for r in manifest['items'] if r.get('format') in {'PNG','JPEG','DPNG'}}
    checks=documents['assets']['imageChecks']
    if set(expected)!={r['relativePath'] for r in checks}:raise ProbeError('native_image_selection_mismatch')
    for row in checks:
        original=expected[row['relativePath']]
        if row['status']!='verified' or row['sourceSHA256']!=original.get('sha256') or (
            row['width'],row['height'])!=(original.get('width'),original.get('height')):
            raise ProbeError('native_sample_identity_dimensions_or_decode')
    signature=subprocess.run(['codesign','--verify','--deep','--strict',str(ROOT/'build/Mangekyou.app')],capture_output=True,timeout=30)
    if signature.returncode:raise ProbeError('native_signature_verification_failed')
    report=dict(schema_version=1,status='inferred',scope='Working ARM64 app foundation; original game execution and complete game compatibility remain unimplemented',
        dataset='real',app=build['app'],architecture=build['architecture'],binary_sha256=build['binary_sha256'],
        source_sha256=current,build='verified',signature='verified',
        native_tests=dict(status='verified',passed=test_count,failed=0,skips_are_successes=False,scope='Owned resource/safety fixtures; no original-engine oracle'),
        game_inventory=dict(status='verified',files=len(inventory['files']),bytes=inventory['totalBytes'],P0_path_size_match=True,
            archive_versions=dict(Counter(f['pack']['version'] for f in inventory['files'] if f.get('pack'))),
            declared_archive_entries=sum(f['pack']['declaredEntries'] for f in inventory['files'] if f.get('pack')),
            index_listing='not_tested',scope='Signatures and bounded footer metadata only'),
        image_samples=dict(status='verified',count=len(checks),by_format=dict(Counter(expected[r['relativePath']]['format'] for r in checks)),
            sha256_and_dimensions_match_P0=True,scope='ImageIO decode and selected DPNG preview model only; no pixel/display equivalence'),
        independent_gui_replay='not_tested',full_game_compatibility='not_tested',original_renderer_equivalence='not_tested',
        complete_interpreter='unsupported',experimental_interpreter_equivalence='not_tested',
        pack_payload_access='unsupported',audio_playback='unsupported',animation_playback='unsupported',saves='unsupported',
        original_files_written=False,external_game_data_uploads=False,commercial_assets_bundled=False,
        third_party_runtime_parsers_bundled=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],native_tests=test_count,files=len(inventory['files']),images=len(checks),full_game_compatibility='not_tested')))
    return 0


if __name__=='__main__':raise SystemExit(main())
