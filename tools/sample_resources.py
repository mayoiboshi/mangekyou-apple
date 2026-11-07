#!/usr/bin/env python3
"""Bounded local research copies via upstream decoder; no game executables or repack.

All .s/.txt plus <=2 representative files per candidate asset extension per PACK.
Keeps archive provenance; never chooses patch precedence. Keys remain in memory.
"""
import argparse
import hashlib
import json
import mmap
import os
from pathlib import Path
import resource
import struct
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import (ROOT, ProbeError, absolute, collision_key, footer_probe,
        safe_member_name, safe_open, write_json, signature)
    from .upstream_worker import validate_source
else:
    from mangekyou_p0 import (ROOT, ProbeError, absolute, collision_key, footer_probe,
        safe_member_name, safe_open, write_json, signature)
    from upstream_worker import validate_source

MEMBER_LIMIT = 16 * 1024 * 1024
TOTAL_LIMIT = 128 * 1024 * 1024


def copy_exclusive(root, name, data):
    normalized = safe_member_name(name)
    root.mkdir(parents=True, exist_ok=True)
    fd = safe_open(root, directory=True)
    parts = normalized.split('/')
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, mode=0o700, dir_fd=fd)
            except FileExistsError:
                pass
            nxt = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd); fd = nxt
        try:
            out = os.open(parts[-1], os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        except FileExistsError:
            existing = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(existing, 'rb') as stream:
                if stream.read(len(data)+1) != data:
                    raise ProbeError('existing_sample_differs; no overwrite permitted')
            return
        with os.fdopen(out, 'wb') as stream:
            stream.write(data)
    finally:
        os.close(fd)


def worker(args):
    resource.setrlimit(resource.RLIMIT_CPU, (100,100))
    validate_source(args.upstream_source)
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(args.upstream_source))
    from qlie_unpacker.parser import parse_bytes
    import qlie_unpacker.extractor as extractor
    # Preserve decoded raw resource format, not the upstream PNG conversion.
    # Hash validation, decryption, BPE and exact decoded-size checks remain upstream.
    extractor.process_payload = lambda name, payload, cancel_callback=None: payload
    result = dict(archive=args.archive, status='verified', errors=[], entries=[], key_exported=False,
                  policy='all .s/.txt, first and smallest candidate per asset extension; no patch precedence')
    path = args.game_dir / args.archive
    with os.fdopen(safe_open(path),'rb') as stream:
        size = stream.seek(0,2);stream.seek(max(0,size-28))
        meta = footer_probe(stream.read(28),size)
        with mmap.mmap(stream.fileno(),0,access=mmap.ACCESS_READ) as data:
            archive = parse_bytes(data,path)
            key_entry = next((e for e in archive.entries if 'pack_keyfile' in e.name),None)
            key = b''
            if key_entry:
                if key_entry.original_size > 1024*1024 or key_entry.compressed_size > 1024*1024:
                    raise ProbeError('key_size_limit')
                key = extractor._decode_entry(archive,data,key_entry,b'',b'')
            selected = {e.index for e in archive.entries if Path(e.name).suffix.lower() in {'.s','.txt'}}
            for ext in ['.png','.b','.ogg','.wav','.ogv']:
                candidates = [e for e in archive.entries if Path(e.name).suffix.lower()==ext
                              and e.original_size<=MEMBER_LIMIT and e.compressed_size<=MEMBER_LIMIT]
                if candidates:
                    selected.update([candidates[0].index,min(candidates,key=lambda e:e.original_size).index])
            if args.member:
                matches = [e.index for e in archive.entries if collision_key(e.name) == collision_key(args.member)]
                if len(matches) != 1:
                    raise ProbeError('named_member_missing_or_ambiguous')
                selected = set(matches)
                result['policy'] = 'single explicitly named research member'
            total=0;seen=set()
            for entry in archive.entries:
                if entry.index not in selected:
                    continue
                evidence = dict(index=entry.index,name=entry.name,offset=entry.offset,
                    compressed_size=entry.compressed_size,original_size=entry.original_size,
                    compressed=entry.compressed,encryption_method=entry.encryption_method)
                try:
                    normalized=safe_member_name(entry.name)
                    folded=collision_key(entry.name)
                    if folded in seen:raise ProbeError('case_unicode_collision')
                    seen.add(folded)
                    if (entry.original_size>MEMBER_LIMIT or entry.compressed_size>MEMBER_LIMIT
                        or total+entry.original_size>TOTAL_LIMIT):raise ProbeError('sample_size_limit')
                    if entry.offset+entry.compressed_size>meta['table_offset']:raise ProbeError('index_overlap')
                    payload=extractor._decode_entry(archive,data,entry,key,b'')
                    total+=len(payload)
                    relative=Path(args.archive).name+'/'+normalized
                    copy_exclusive(args.output,relative,payload)
                    evidence.update(status='verified',copy_path=relative,decoded_size=len(payload),
                        sha256=hashlib.sha256(payload).hexdigest(),signature_type=signature(payload),
                        integrity_scope='upstream encrypted-data hash and decoded size; not engine fidelity')
                except Exception as exc:
                    evidence.update(status='unsupported',error=dict(category=type(exc).__name__,detail=str(exc)))
                    result['errors'].append(dict(index=entry.index,**evidence['error']))
                result['entries'].append(evidence)
            result.update(selected_count=len(selected),decoded_bytes=total,not_selected_count=len(archive.entries)-len(selected))
    if result['errors']:result['status']='unsupported'
    print(json.dumps(result,ensure_ascii=False))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--game-dir',type=Path,required=True)
    ap.add_argument('--upstream-source',type=Path,required=True)
    ap.add_argument('--archive-report',type=Path)
    ap.add_argument('--output',type=Path,required=True)
    ap.add_argument('--report',type=Path)
    ap.add_argument('--archive',help=argparse.SUPPRESS)
    ap.add_argument('--member',help='One exact member in an explicitly selected GameData archive')
    args=ap.parse_args()
    args.game_dir=absolute(args.game_dir);args.upstream_source=absolute(args.upstream_source);args.output=absolute(args.output)
    # Copies/reports must stay in ignored private/, with no overlap with original files.
    private=ROOT/'private'
    if private not in args.output.parents:raise ProbeError('sample output must be under project private/')
    for out in [args.output]+([absolute(args.report)] if args.report else []):
        if out==args.game_dir or args.game_dir in out.parents or out in args.game_dir.parents:
            raise ProbeError('input/output overlap')
        for parent in [out]+list(out.parents):
            if parent.is_symlink():raise ProbeError('output symlink rejected')
    if args.member:
        safe_member_name(args.member)
        if not args.archive or not args.archive.startswith('GameData/'):
            ap.error('--member requires an explicit GameData archive')
    if args.archive:
        safe_member_name(args.archive)
        worker(args);return 0
    if not args.archive_report or not args.report:ap.error('--archive-report and --report required')
    if private not in absolute(args.report).parents:raise ProbeError('sample report must be private')
    archives=json.loads(args.archive_report.read_text())['items']
    results=[]
    for archive in archives:
        # Exclude installer resources from game samples; archive index is still inventoried.
        if not archive['path'].startswith('GameData/'):
            results.append(dict(archive=archive['path'],status='not_tested',reason='installer excluded'))
            continue
        command=[sys.executable,str(Path(__file__).resolve()),'--game-dir',str(args.game_dir),
            '--upstream-source',str(args.upstream_source),'--output',str(args.output),'--archive',archive['path']]
        try:
            proc=subprocess.run(command,capture_output=True,timeout=120)
            result=json.loads(proc.stdout) if proc.returncode==0 else dict(archive=archive['path'],status='unsupported',errors=[dict(category='worker_failure',detail=proc.stderr.decode('utf-8','replace')[-1500:])])
        except (subprocess.SubprocessError,ValueError) as exc:
            result=dict(archive=archive['path'],status='unsupported',errors=[dict(category=type(exc).__name__,detail=str(exc))])
        result['source_archive_sha256']=archive.get('sha256')
        results.append(result)
        print(json.dumps(dict(archive=archive['path'],status=result['status'],selected=result.get('selected_count'),errors=len(result.get('errors',[]))),ensure_ascii=False),flush=True)
        write_json(args.report,dict(schema_version=1,dataset='real',status='inferred',original_files_written=False,archives=results))
    return 2 if any(r['status']=='unsupported' for r in results) else 0


if __name__=='__main__':
    sys.exit(main())
