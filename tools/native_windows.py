#!/usr/bin/env python3
"""Read bounded PE code windows with LLVM when Ghidra has no function body."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .pe_probe import pe32
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from pe_probe import pe32


def window_reference(pe,start,end):
    if start<0 or end<=start or end-start>8192:raise ProbeError('native_window_size_or_address')
    sections=[s for s in pe['sections'] if s['executable'] and pe['image_base']+s['rva']<=start
              and end<=pe['image_base']+s['rva']+s['raw_size']]
    if len(sections)!=1:raise ProbeError('native_window_not_uniquely_file_backed_executable')
    section=sections[0]
    return dict(offset=section['raw_offset']+start-pe['image_base']-section['rva'],length=end-start)


def validate_windows(pe,windows):
    if not 1<=len(windows)<=16:raise ProbeError('native_window_count_limit')
    total=0;names=set();result=[]
    for row in windows:
        name=safe_member_name(row['name'])
        if '/' in name or name in names:raise ProbeError('native_window_duplicate_or_nested_name')
        names.add(name);start=int(row['start'],16);end=int(row['end_exclusive'],16)
        ref=window_reference(pe,start,end);total+=ref['length']
        result.append((name,start,end,ref))
    if total>32768:raise ProbeError('native_window_total_size_limit')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir',type=Path,required=True)
    parser.add_argument('--exe',required=True)
    parser.add_argument('--plan',type=Path,default=ROOT/'docs/native-windows-round3.json')
    parser.add_argument('--output',type=Path,default=ROOT/'private/p1-round3/windows')
    parser.add_argument('--llvm-objdump',type=Path)
    args=parser.parse_args();game=absolute(args.game_dir);output=absolute(args.output)
    if ROOT/'private' not in output.parents:raise ProbeError('windows_output_must_be_private')
    if output==game or game in output.parents or output in game.parents:raise ProbeError('input_output_overlap')
    plan=json.loads(read_bounded(args.plan));relative=safe_member_name(args.exe);source=game/relative
    data=read_bounded(source,64*1024*1024);sha=hashlib.sha256(data).hexdigest();pe=pe32(data)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    original=next((f for f in inventory['files'] if f['path']==relative),{})
    if sha!=original.get('sha256') or sha!=plan.get('source_sha256'):raise ProbeError('window_plan_or_inventory_identity_mismatch')
    rows=validate_windows(pe,plan['windows'])
    command=str(args.llvm_objdump) if args.llvm_objdump else shutil.which('llvm-objdump')
    if not command:
        found=subprocess.run(['xcrun','--find','llvm-objdump'],capture_output=True,text=True,timeout=10)
        if found.returncode:raise ProbeError('llvm_objdump_not_available')
        command=found.stdout.strip()
    command=absolute(command)
    if command==source or game in command.parents:raise ProbeError('tool_cannot_be_game_input')
    version=subprocess.run([str(command),'--version'],capture_output=True,text=True,timeout=10)
    tool=dict(id='llvm-objdump',version=version.stdout.splitlines()[:3])
    report=dict(schema_version=1,status='verified',source_file=relative,source_sha256=sha,provider=tool,
        scope='LLVM linear windows only; analyst-selected boundaries are inferred, not recovered function bodies',
        windows=[],errors=[],original_files_written=False,target_execution='not_tested')
    for name,start,end,ref in rows:
        try:
            p=subprocess.run([str(command),'-d','--start-address='+hex(start),'--stop-address='+hex(end),
                '--x86-asm-syntax=intel',str(source)],capture_output=True,timeout=30)
            if len(p.stdout)>2*1024*1024 or len(p.stderr)>16384:raise ProbeError('LLVM_output_size_limit')
            text=p.stdout.decode('utf-8','replace')
            if p.returncode or not text.strip():raise ProbeError('LLVM_disassembly_failed')
            evidence_id='local-llvm:'+hashlib.sha256((sha+hex(start)+hex(end)+text).encode()).hexdigest()
            item=dict(status='verified',name=name,evidence_id=evidence_id,provider=tool,source_file=relative,
                source_sha256=sha,address_range=dict(start=hex(start),end_exclusive=hex(end)),
                raw_bytes_reference=dict(source_file=relative,source_sha256=sha,sha256=hashlib.sha256(data[ref['offset']:ref['offset']+ref['length']]).hexdigest(),**ref),
                normalized_result=text,boundary_status='inferred',stderr=p.stderr.decode('utf-8','replace'))
        except (OSError,ValueError,subprocess.SubprocessError) as exc:
            item=dict(status='unsupported',name=name,error=str(exc));report['errors'].append(dict(name=name,error=str(exc)))
        write_json(output/(name+'.json'),item)
        report['windows'].append({k:v for k,v in item.items() if k not in {'normalized_result','stderr'}})
    report['source_sha256_after']=hashlib.sha256(read_bounded(source,64*1024*1024)).hexdigest()
    if report['errors'] or report['source_sha256_after']!=sha:report['status']='unsupported'
    write_json(output/'window-report.json',report)
    print(json.dumps(dict(status=report['status'],windows=len(rows),errors=len(report['errors']))))
    return 0 if report['status']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
