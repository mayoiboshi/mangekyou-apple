#!/usr/bin/env python3
"""Cross-check real scripts against a locally built msg-tool. Bodies stay private."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import ROOT, absolute, read_bounded, script_probe, tokenize_tag, write_json
else:
    from mangekyou_p0 import ROOT, absolute, read_bounded, script_probe, tokenize_tag, write_json


def projection(data, filename):
    parsed=script_probe(data,filename)
    if parsed['errors']:raise ValueError('local script parse errors')
    messages=[];name=None;references=[]
    for record in parsed['records']:
        raw=data[record['byte_offset']:record['byte_offset']+record['byte_length']]
        line=raw.decode(parsed['encoding']).strip()
        kind=record['record_type']
        if kind=='name_candidate':
            name=line[1:-1]
        elif kind in {'text_candidate','comment_candidate'}:
            message=dict(message=line.replace('[n]','\n'))
            if name is not None:message['name']=name
            messages.append(message);name=None;references.append(record['byte_offset'])
        elif kind=='line_tag' and (record.get('token') or '').lower() in {'select','savetext'}:
            fields=tokenize_tag(line[1:])[1:]
            if record['token'].lower()=='savetext':fields=fields[:1]
            for field in fields:
                # Match only proved simple quoted/bare fields, not unknown key/value syntax.
                quoted=False
                for char in field:
                    if char=='"':quoted=not quoted
                    elif char==':' and not quoted:raise ValueError('non-simple extraction field')
                if field:
                    messages.append(dict(message=field.replace('"','')))
                    references.append(record['byte_offset'])
    return messages,references


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--binary',type=Path,required=True)
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--output',type=Path,default=ROOT/'private/msg-export')
    ap.add_argument('--report',type=Path,default=ROOT/'private/real-p0/msg-crosscheck.json')
    args=ap.parse_args()
    args.output=absolute(args.output);args.report=absolute(args.report);args.assets_dir=absolute(args.assets_dir)
    if ROOT/'private' not in args.output.parents or ROOT/'private' not in args.report.parents:
        raise ValueError('all commercial text output must remain in ignored private/')
    if args.assets_dir==args.output or args.assets_dir in args.output.parents:raise ValueError('input/output overlap')
    binary=absolute(args.binary)
    blob=read_bounded(binary)
    if blob[:4]!=b'\xcf\xfa\xed\xfe':raise ValueError('expected locally built 64-bit Mach-O msg_tool, not Windows EXE')
    for parent in [args.output,args.report]+list(args.output.parents)+list(args.report.parents):
        if parent.is_symlink():raise ValueError('output symlink rejected')
    args.output.mkdir(parents=True,exist_ok=True)
    results=[]
    for source in sorted(args.assets_dir.rglob('*.s')):
        relative=source.relative_to(args.assets_dir).as_posix()
        target=args.output/(hashlib.sha256(relative.encode()).hexdigest()+'.json')
        if target.is_symlink():raise ValueError('output symlink rejected')
        if target.exists():target.unlink()  # Only this tool's generated, hashed output name.
        # Existing exports are compared after a fresh export to another unique private directory.
        target.parent.mkdir(parents=True,exist_ok=True)
        command=[str(binary),'export','-t','qlie',str(source),str(target)]
        item=dict(source_file=relative,status='unsupported')
        try:
            data=read_bounded(source,16*1024*1024)
            expected,offsets=projection(data,relative)
            proc=subprocess.run(command,capture_output=True,timeout=20)
            if proc.returncode:
                raise ValueError('msg_tool export failed: exit '+str(proc.returncode))
            if not target.is_file() and expected:
                raise ValueError('msg_tool produced no output for nonempty expected extraction')
            actual=json.loads(read_bounded(target,16*1024*1024)) if target.is_file() else []
            item['empty_export_omitted']=not target.is_file()
            mismatches=[i for i,(a,b) in enumerate(zip(actual,expected)) if a!=b]
            if len(actual)!=len(expected):mismatches.append(min(len(actual),len(expected)))
            canonical=json.dumps(actual,ensure_ascii=False,sort_keys=True,separators=(',',':')).encode()
            item.update(status='verified' if not mismatches else 'unsupported',messages=len(actual),
                expected_messages=len(expected),mismatch_count=len(mismatches),
                first_mismatch_source_byte_offset=offsets[mismatches[0]] if mismatches and mismatches[0]<len(offsets) else None,
                source_sha256=hashlib.sha256(data).hexdigest(),message_sequence_sha256=hashlib.sha256(canonical).hexdigest())
        except Exception as exc:
            item['error']=dict(category=type(exc).__name__,detail=str(exc))
        results.append(item)
    # Independently reproduce auto-detection failure without editing upstream source.
    probe=next(iter(sorted(args.assets_dir.rglob('*.s'))),None)
    auto=dict(status='not_tested')
    if probe:
        target=args.output/'autodetect.json'
        proc=subprocess.run([str(binary),'export',str(probe),str(target)],capture_output=True,timeout=20)
        auto=dict(status='verified',exit_code=proc.returncode,produced_output=target.is_file(),
                  interpretation='Auto mode behavior observed only; explicit -t qlie used for content comparisons')
    report=dict(schema_version=1,dataset='real',status='verified' if results and all(x['status']=='verified' for x in results) else 'unsupported',
        binary_sha256=hashlib.sha256(blob).hexdigest(),upstream_commit='0356bb93be7c1f5b11ec22864919200cf7455e33',
        files=len(results),messages=sum(x.get('messages',0) for x in results),
        mismatches=sum(x.get('mismatch_count',0) for x in results),failed_files=sum(x['status']!='verified' for x in results),
        items=results,autodetect_probe=auto,
        scope='Exact name/message sequence agreement with an independent projection of upstream extraction rules. This is not a human dialogue oracle or execution semantics verification',
        execution_semantics='unsupported')
    write_json(args.report,report)
    print(json.dumps({k:report[k] for k in ['status','files','messages','mismatches','failed_files','autodetect_probe']}))
    return 0 if report['status']=='verified' else 2


if __name__=='__main__':sys.exit(main())
