#!/usr/bin/env python3
"""Build the pinned QLIE-only msg-tool, recording exact native build/test results."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

from mangekyou_p0 import ROOT, read_bounded, write_json


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,default=ROOT/'.research/upstream/msg-tool')
    ap.add_argument('--target-dir',type=Path,default=ROOT/'.research/msg-target')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p0/msg-build.json')
    args=ap.parse_args()
    lock=json.loads((ROOT/'docs/upstream-lock.json').read_text())
    upstream=next(u for u in lock['upstreams'] if u['repository']=='lifegpc/msg-tool')
    for f in upstream['files']:
        if hashlib.sha256(read_bounded(args.source/f['path'],4*1024*1024)).hexdigest()!=f['sha256']:
            raise ValueError('source digest mismatch: '+f['path'])
    env=dict(os.environ)
    local=ROOT/'.research/cargo/bin/cargo'
    cargo=shutil.which('cargo') or (str(local) if local.is_file() else None)
    if not cargo:raise ValueError('Install a Rust 2024-compatible toolchain; no game programs will be run')
    if cargo==str(local):
        env.update(CARGO_HOME=str(ROOT/'.research/cargo'),RUSTUP_HOME=str(ROOT/'.research/rustup'))
        env['PATH']=str(local.parent)+os.pathsep+env.get('PATH','')
    common=['--manifest-path',str(args.source/'Cargo.toml'),'--locked','--no-default-features','--features','qlie','--target-dir',str(args.target_dir)]
    commands=[]
    for argv in [[cargo,'--version'],[cargo,'build']+common+['--release'],[cargo,'test']+common+['test_tag']]:
        proc=subprocess.run(argv,env=env,capture_output=True,timeout=180)
        commands.append(dict(command=argv,exit_code=proc.returncode,stdout=proc.stdout.decode('utf-8','replace'),stderr=proc.stderr.decode('utf-8','replace')))
        if proc.returncode:break
    binary=args.target_dir/'release/msg_tool'
    report=dict(schema_version=1,upstream_commit=upstream['commit'],status='verified' if all(c['exit_code']==0 for c in commands) else 'unsupported',
        feature_scope='--no-default-features --features qlie; not archive/image features',
        native_architecture=os.uname().machine,commands=commands,
        binary_sha256=hashlib.sha256(read_bounded(binary)).hexdigest() if binary.is_file() else None,
        note='test_tag is one source test compiled in both lib and bin test targets; do not call this two independent test cases')
    write_json(args.output,report)
    print(json.dumps(dict(status=report['status'],binary=str(binary))))
    return 0 if report['status']=='verified' else 1


if __name__=='__main__':sys.exit(main())
