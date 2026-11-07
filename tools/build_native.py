#!/usr/bin/env python3
"""Build and sign the project's ARM64 app; no game inputs or bundled game data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--configuration',choices=['debug','release'],default='release')
    args=p.parse_args();private=ROOT/'private/native-foundation';private.mkdir(parents=True,exist_ok=True)
    build=ROOT/'build';app=build/'Mangekyou.app';staging=build/'Mangekyou.staging.app'
    previous=build/'Mangekyou.previous.app'
    for parent in [private,build,app,staging,previous]+list(ROOT.parents):
        if parent.is_symlink():raise ProbeError('native_build_symlink_output')
    if staging.exists():raise ProbeError('native_staging_exists_inspect_before_retry')
    if previous.exists():raise ProbeError('native_backup_exists_inspect_before_retry')
    command=['swift','build','--package-path',str(ROOT/'native'),'-c',args.configuration,'--arch','arm64','--product','Mangekyou']
    result=subprocess.run(command,capture_output=True,timeout=180,cwd=ROOT)
    (private/'swift-build.log').write_bytes(result.stdout+result.stderr)
    if result.returncode:raise ProbeError('native_build_failed_see_private_log')
    query=subprocess.run(command[:-2]+['--show-bin-path'],capture_output=True,check=True,timeout=30,cwd=ROOT)
    directory=absolute(query.stdout.decode().strip())
    if ROOT/'native/.build' not in directory.parents:raise ProbeError('native_binary_outside_build_tree')
    binary=read_bounded(directory/'Mangekyou')
    if len(binary)<12 or binary[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',binary,4)[0]!=0x0100000c:
        raise ProbeError('native_output_not_arm64_MachO')
    build.mkdir(exist_ok=True);(staging/'Contents/MacOS').mkdir(parents=True)
    executable=staging/'Contents/MacOS/Mangekyou';executable.write_bytes(binary);executable.chmod(0o755)
    info=dict(CFBundleName='Mangekyou',CFBundleDisplayName='Mangekyou',CFBundleIdentifier='org.projectmangekyou.dev',
        CFBundleExecutable='Mangekyou',CFBundlePackageType='APPL',CFBundleShortVersionString='0.6.0',
        CFBundleVersion='6',LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True,
        NSPrincipalClass='NSApplication',NSHumanReadableCopyright='Project Mangekyou; commercial game data not included')
    (staging/'Contents/Info.plist').write_bytes(plistlib.dumps(info,sort_keys=True))
    signed=subprocess.run(['codesign','--force','--sign','-',str(staging)],capture_output=True,timeout=30)
    if signed.returncode:raise ProbeError('native_adhoc_sign_failed')
    verified=subprocess.run(['codesign','--verify','--deep','--strict',str(staging)],capture_output=True,timeout=30)
    if verified.returncode:raise ProbeError('native_signature_validation_failed')
    # Only an earlier output from this builder can be replaced. Never touch imported directories.
    if app.exists():
        old=plistlib.loads(read_bounded(app/'Contents/Info.plist'))
        if old.get('CFBundleIdentifier')!=info['CFBundleIdentifier'] or previous.exists():
            raise ProbeError('native_previous_output_not_owned_or_backup_exists')
        app.rename(previous)
    try:staging.rename(app)
    except OSError:
        if previous.exists():previous.rename(app)
        raise
    if previous.exists():shutil.rmtree(previous)
    built=read_bounded(app/'Contents/MacOS/Mangekyou')
    sources={path.relative_to(ROOT).as_posix():hashlib.sha256(read_bounded(path)).hexdigest()
        for path in sorted((ROOT/'native').rglob('*.swift')) if '.build' not in path.parts}
    report=dict(schema_version=1,status='verified',scope='ARM64 app build and local ad-hoc signature only; game compatibility not tested',
        app='build/Mangekyou.app',configuration=args.configuration,architecture='arm64',
        binary_sha256=hashlib.sha256(built).hexdigest(),signature='verified',source_sha256=sources,
        commercial_assets_bundled=False,original_game_execution='not_tested',full_game_compatibility='not_tested')
    write_json(private/'build-report.json',report)
    print(json.dumps(dict(status=report['status'],app=report['app'],architecture=report['architecture'])))
    return 0


if __name__=='__main__':raise SystemExit(main())
