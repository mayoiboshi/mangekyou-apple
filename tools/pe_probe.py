#!/usr/bin/env python3
"""Read-only bounded PE32 facts. Never loads or executes the inspected program."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json

MAX_PE=64*1024*1024
NEEDLES=['FilePackVer','GameData','.pack','ParamInt','ParamStr','IMOSYSDATA','SystemData','SaveData']


def sha(data):return hashlib.sha256(data).hexdigest()


def pe32(data):
    if len(data)>MAX_PE or len(data)<64 or data[:2]!=b'MZ':raise ProbeError('invalid_dos_header_or_size')
    pe=struct.unpack_from('<I',data,60)[0]
    if pe>len(data)-24 or data[pe:pe+4]!=b'PE\0\0':raise ProbeError('invalid_pe_header')
    machine,count=struct.unpack_from('<HH',data,pe+4);optional=struct.unpack_from('<H',data,pe+20)[0]
    if machine!=0x14c or count==0 or count>96:raise ProbeError('unsupported_machine_or_section_count')
    base=pe+24
    if optional<96 or base+optional>len(data):raise ProbeError('invalid_optional_header')
    if struct.unpack_from('<H',data,base)[0]!=0x10b:raise ProbeError('only_pe32_supported')
    image_base=struct.unpack_from('<I',data,base+28)[0]
    entry_rva=struct.unpack_from('<I',data,base+16)[0]
    table=base+optional
    if table+40*count>len(data):raise ProbeError('short_section_table')
    sections=[];ranges=[]
    for i in range(count):
        pos=table+40*i
        name=data[pos:pos+8].split(b'\0',1)[0].decode('ascii','replace')
        virtual_size,rva,raw_size,raw_offset=struct.unpack_from('<4I',data,pos+8)
        flags=struct.unpack_from('<I',data,pos+36)[0]
        if raw_size and (raw_offset>len(data)-raw_size or raw_offset<table+40*count):
            raise ProbeError('section_raw_range_outside_file')
        if rva+max(raw_size,virtual_size)>0x100000000:raise ProbeError('section_rva_overflow')
        if raw_size:
            if any(raw_offset<b and raw_offset+raw_size>a for a,b in ranges):raise ProbeError('overlapping_raw_sections')
            ranges.append((raw_offset,raw_offset+raw_size))
        sections.append(dict(name=name,rva=rva,virtual_size=virtual_size,raw_offset=raw_offset,
            raw_size=raw_size,executable=bool(flags&0x20000000),flags=hex(flags)))
    return dict(status='verified',machine='i386',image_base=image_base,entry_rva=entry_rva,
        sections=sections,authenticity='not_tested',execution='not_tested')


def locate(pe,offset,length=1):
    if offset<0 or length<0:raise ProbeError('negative_offset')
    for section in pe['sections']:
        if section['raw_offset']<=offset and offset+length<=section['raw_offset']+section['raw_size']:
            rva=section['rva']+offset-section['raw_offset']
            return dict(file_offset=offset,length=length,rva=rva,va=pe['image_base']+rva,
                section=section['name'],executable_section=section['executable'])
    return dict(file_offset=offset,length=length,rva=None,va=None,section=None,executable_section=False)


def selector_patterns(data,pe):
    """Exact i386 byte pattern only, not a recovered function or scope semantics."""
    found=[]
    for token in ['svar','gvar','var']:
        immediate=token.encode().ljust(4,b'\0');start=0
        while True:
            pos=data.find(immediate,start)
            if pos<0:break
            start=pos+1
            a=pos-3;b=pos+8
            if a<0 or b>len(data):continue
            # cmp dword ptr [ebp+disp8],imm32 ; jne +2 ; mov bl,imm8
            pattern=data[a:b]
            if pattern[:2]!=b'\x81\x7d' or pattern[7:10]!=b'\x75\x02\xb3':continue
            where=locate(pe,a,11)
            if not where['executable_section']:continue
            found.append(dict(token=token,**where,pattern_sha256=sha(pattern),
                local_slot_displacement=struct.unpack('b',pattern[2:3])[0],selected_bl_u8=pattern[10],
                byte_pattern_status='verified',dispatch_role='inferred',
                number_meaning='not_tested',reachability='not_tested',
                candidate_instructions=['cmp dword [ebp+disp8], token_imm32','jne +2','mov bl, category_u8']))
    return found


def probe(data):
    pe=pe32(data);hits=[]
    for word in NEEDLES:
        for codec in ['ascii','utf-16-le']:
            needle=word.encode(codec);positions=[];start=0
            while True:
                pos=data.find(needle,start)
                if pos<0:break
                positions.append(pos);start=pos+1
            if positions:
                hits.append(dict(needle=word,encoding=codec,total_matches=len(positions),retained_limit=32,
                    locations=[locate(pe,p,len(needle)) for p in positions[:32]],
                    meaning='byte occurrence only; executable section may also contain literal data'))
    return dict(schema_version=1,status='verified',source_sha256=sha(data),size=len(data),pe=pe,
        literal_patterns=hits,variable_category_patterns=selector_patterns(data,pe),
        archive_load_precedence='not_tested',variable_scope_semantics='not_tested',execution='not_tested')


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--game-dir',type=Path,required=True)
    ap.add_argument('--exe',required=True,help='Relative EXE path, inspected only as bytes')
    ap.add_argument('--inventory',type=Path,default=ROOT/'reports/p0/inventory.json')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p1/program-probe.json')
    args=ap.parse_args();rel=safe_member_name(args.exe)
    output=absolute(args.output);game=absolute(args.game_dir)
    if ROOT/'reports/p1' not in output.parents and ROOT/'private' not in output.parents:
        raise ProbeError('report_output_must_be_project_reports_or_private')
    if output==game or game in output.parents:raise ProbeError('input/output overlap')
    source=game/rel;data=read_bounded(source,MAX_PE)
    inv=json.loads(read_bounded(args.inventory));old=next((i for i in inv['files'] if i['path']==rel),None)
    if old is None or old.get('sha256')!=sha(data):raise ProbeError('program_does_not_match_P0_inventory')
    report=probe(data);report.update(source_file=rel,inventory_sha256_status='verified',
        scope='User-supplied plain-named EXE candidate only; translation EXEs not inspected')
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],machine=report['pe']['machine'],
        category_patterns=[{'token':p['token'],'bl':p['selected_bl_u8'],'offset':p['file_offset']} for p in report['variable_category_patterns']],
        execution='not_tested')))


if __name__=='__main__':main()
