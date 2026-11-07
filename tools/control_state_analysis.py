#!/usr/bin/env python3
"""Link declared states, selected instruction stores and lexical block candidates."""
import argparse
from collections import Counter
from contextlib import contextmanager
import json
from pathlib import Path
import re
import signal
import struct
import sys

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_class
    from .rea_static import validate_plan,checked_evidence
    from .qlie_lex import lex,digest
    from .semantic_evidence import annotate_regions,blocks
    from .review_native import window_summary
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_class
    from rea_static import validate_plan,checked_evidence
    from qlie_lex import lex,digest
    from semantic_evidence import annotate_regions,blocks
    from review_native import window_summary

REGISTERS={'EAX':0,'ECX':1,'EDX':2,'EBX':3,'ESI':6,'EDI':7}
FAMILIES={'if':[2,5,6],'for':[3,7,8,9],'case':[4,10,11]}
MARKERS={'then':['if'],'else':['if','case'],'of':['case'],'ans':['case'],'brk':['for'],'cnt':['for']}
WRITES=re.compile(r'^(MOV|AND|OR|XOR|ADD|SUB|INC|DEC|XCHG)\s+BYTE PTR\s+\[(EAX|ECX|EDX|EBX|ESI|EDI)\s*\+\s*0X0*34\](?:,\s*(.*))?$')


@contextmanager
def processing_deadline(seconds=120):
    """Bound the standalone scan on the supported POSIX research hosts."""
    if not hasattr(signal,'setitimer'):raise ProbeError('control_deadline_host_unsupported')
    if signal.getitimer(signal.ITIMER_REAL)!=(0.0,0.0):raise ProbeError('control_existing_timer_outside_scope')
    previous=signal.getsignal(signal.SIGALRM)
    def expired(_signum,_frame):raise ProbeError('control_processing_time_limit')
    signal.signal(signal.SIGALRM,expired)
    try:
        signal.setitimer(signal.ITIMER_REAL,seconds)
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL,0)
        signal.signal(signal.SIGALRM,previous)


def instruction_rows(text,provider):
    rows=[]
    for line in text.splitlines():
        if provider=='ghidra':m=re.match(r'^0x([0-9a-fA-F]+):\s*(.+)$',line)
        else:m=re.match(r'^\s*([0-9a-fA-F]+):\s+(?:[0-9a-fA-F]{2}\s+){1,15}(.+)$',line)
        if m:rows.append((int(m.group(1),16),' '.join(m.group(2).upper().split())))
    if len(rows)>100000:raise ProbeError('state_instruction_count_limit')
    return rows


def immediate_store(image,address,register,value):
    """Recognize only C6 /0 stores with a reviewed +0x34 displacement."""
    if register not in REGISTERS or not 0<=value<=255:raise ProbeError('state_store_operand_outside_scope')
    image.code(address);prefix=image.read(address,2);reg=REGISTERS[register]
    if prefix==bytes([0xc6,0x40|reg]):expected=prefix+b'\x34'+bytes([value])
    elif prefix==bytes([0xc6,0x80|reg]):expected=prefix+struct.pack('<I',0x34)+bytes([value])
    else:raise ProbeError('state_store_encoding_outside_scope')
    if image.read(address,len(expected))!=expected:raise ProbeError('state_store_bytes_disagree_with_observation')
    return image.reference(address,len(expected))


def stores(image,text,provider,members):
    rows=instruction_rows(text,provider);result=[]
    for i,(address,instruction) in enumerate(rows):
        match=WRITES.match(instruction)
        if not match:continue
        op,register,operand=match.groups();entry=dict(address=hex(address),field_offset=0x34,
            owner_register=register,field_binding_status='inferred',execution_semantics='not_tested')
        try:
            if op!='MOV':raise ProbeError('state_modifying_instruction_outside_reviewed_encoding')
            try:value=int(operand,0)
            except (TypeError,ValueError):raise ProbeError('dynamic_state_store_value')
            entry['value_u8']=value;entry['raw_bytes_reference']=immediate_store(image,address,register,value)
            if value not in members:raise ProbeError('state_value_not_in_reviewed_enum')
            entry.update(status='verified',scope='Instruction encoding and declared value/name only; object identity inferred',
                declared_name=members[value]['name'],enum_member_reference=members[value]['raw_bytes_reference'])
        except ValueError as exc:
            if 'raw_bytes_reference' not in entry:
                length=rows[i+1][0]-address if i+1<len(rows) else 1
                length=length if 1<=length<=15 else 1
                entry['raw_bytes_reference']=image.reference(address,length)
                entry['reference_scope']='Provider instruction span, or first byte if span unavailable'
            entry.update(status='unsupported',unknown_reason=str(exc))
        result.append(entry)
    return result,len(rows)


def public_proof(proof):
    return {k:proof[k] for k in ['source_file','source_sha256','byte_offset','byte_length','record_sha256']}


def block_binding(block,members):
    family=block['kind'];values=FAMILIES.get(family)
    result=dict(kind=family,depth=block['depth'],opener=public_proof(block['opener']),closer=public_proof(block['closer']),
        status='inferred' if values else 'not_tested',execution_edges='not_tested',
        then_marker_count=len(block['then_markers']),else_marker_count=len(block['else_markers']))
    if values:result['state_family_candidates']=[dict(value=v,name=members[v]['name'],
        declaration_reference=members[v]['raw_bytes_reference'],confidence='inferred') for v in values]
    else:result['unknown_reason']='No reviewed state family for lexical opener'
    return result


def marker_binding(record,models):
    token=record['token'].lower();expected=MARKERS.get(token);at=record['byte_offset']
    result=dict(command=token,byte_offset=at,byte_length=record['byte_length'],
        raw_bytes_reference=record['raw_bytes_reference'],execution_target='not_tested')
    if expected is None:
        result.update(status='unsupported',unknown_reason='Control spelling has no reviewed lexical association rule')
        return result
    candidates=[b for b in models if b['kind'] in expected and b['opener']['byte_offset']<at<b['closer']['byte_offset']]
    if candidates:
        chosen=max(candidates,key=lambda b:(b['depth'],b['opener']['byte_offset']))
        result.update(status='inferred',lexical_candidate=public_proof(chosen['opener']),candidate_kind=chosen['kind'])
    else:result.update(status='not_tested',unknown_reason='No same-file lexical candidate; dynamic context not established')
    return result


def primitive_literals(image):
    result=[]
    for address,text in [(0x6bb9a4,'1'),(0x6bba58,'0')]:
        expected=(text+'\0').encode('utf-16le')
        if image.read(address,len(expected))!=expected:raise ProbeError('control_primitive_literal_identity')
        result.append(dict(address=hex(address),status='verified',value=text,encoding='utf-16le',
            raw_bytes_reference=image.reference(address,len(expected)),
            scope='Two primitive constant bytes only; comparison semantics remain inferred'))
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--native-dir',type=Path,default=ROOT/'private/p1-round10/native-reproduced')
    p.add_argument('--windows-dir',type=Path,default=ROOT/'private/p1-round10/windows')
    p.add_argument('--private-dir',type=Path,default=ROOT/'private/p1-round10')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/control-state-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);native=absolute(args.native_dir)
    windows=absolute(args.windows_dir);private=absolute(args.private_dir);output=absolute(args.output)
    for path in [native,windows,private]:
        if ROOT/'private' not in path.parents:raise ProbeError('control_details_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('control_summary_must_be_public_P1')
    for source in [game,assets]:
        for destination in [private,output]:
            if source==destination or source in destination.parents or destination in source.parents:raise ProbeError('control_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(x['path']==relative and x.get('sha256')==sha for x in inventory['files']):raise ProbeError('control_source_inventory_mismatch')
    metadata_plan=json.loads(read_bounded(ROOT/'docs/delphi-metadata-plan.json'))
    if metadata_plan['source_sha256']!=sha:raise ProbeError('control_metadata_identity')
    spec=next(c for c in metadata_plan['classes'] if c['name']=='TScriptBlock');image=Image(program)
    declaration=parse_class(image,int(spec['vmt'],16),spec['slots'],spec['name'])
    field=next(f for f in declaration['fields'] if f['name']=='State')
    if field['offset']!=0x34 or field['type_info']['name']!='TScriptBlockState':raise ProbeError('control_state_field_identity')
    enum=field['type_info']['enum_header'];members={m['value']:m for m in enum['members']}
    if not all(v in members for group in FAMILIES.values() for v in group):raise ProbeError('control_state_family_not_declared')
    plan=json.loads(read_bounded(ROOT/'docs/native-control-state-plan.json'))
    if plan['source_sha256']!=sha:raise ProbeError('control_native_plan_identity')
    store_rows=[];source_summaries=[]
    for q in validate_plan(plan):
        if q['operation']!='procedure_assembly':continue
        record=json.loads(read_bounded(native/(q['name']+'.json'),16*1024*1024))
        checked=checked_evidence(record,sha,q['operation'],q['address'])
        found,count=stores(image,record['normalized_result'],'ghidra',members)
        for entry in found:entry.update(source_file=relative,source_sha256=sha,evidence_id=record['evidence_id'],function=q['address'])
        store_rows+=found;source_summaries.append(dict(name=q['name'],evidence_id=checked['evidence_id'],instructions=count,state_stores=len(found)))
    checked_windows=window_summary(windows,sha,program)
    window=json.loads(read_bounded(windows/'block-init.json'))
    if window['source_sha256']!=sha or window['status']!='verified':raise ProbeError('control_init_window_identity')
    found,count=stores(image,window['normalized_result'],'llvm',members)
    for entry in found:entry.update(source_file=relative,source_sha256=sha,evidence_id=window['evidence_id'],function='0x6c0db4')
    store_rows+=found;source_summaries.append(dict(name='block-init',evidence_id=window['evidence_id'],instructions=count,state_stores=len(found)))
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('control_corpus_file_limit')
    total=0;bindings=[];markers=[];issues=[];families=Counter();commands=Counter();excluded=Counter();record_kinds=Counter();files=[]
    for item in corpus['items']:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('control_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('control_corpus_identity')
        doc=lex(data,rel)
        if doc['status']!='verified':raise ProbeError('control_lexical_failure')
        annotate_regions(doc);model=blocks(doc)
        issues += [dict(public_proof(issue),**{k:issue[k] for k in ['category','kind'] if k in issue}) for issue in model['issues']]
        for block in model['blocks']:bindings.append(block_binding(block,members));families[block['kind']]+=1
        for record in doc['records']:
            if record['record_type']!='command':record_kinds[record['record_type']]+=1;continue
            token=record['token'].lower()
            if token in set(FAMILIES)|set(MARKERS)|{'end','dbrk'}:commands[token]+=1
            else:excluded[token]+=1
            if token in MARKERS or token=='dbrk':
                marker=marker_binding(record,model['blocks']);marker.update(source_file=rel,source_sha256=item['sha256']);markers.append(marker)
        if len(bindings)>20000 or len(markers)>20000:raise ProbeError('control_relation_count_limit')
        files.append(dict(source_file=rel,candidate_blocks=len(model['blocks']),grammar_issues=len(model['issues'])))
    private_report=dict(scope='Full static links only; no execution',block_bindings=bindings,marker_bindings=markers,grammar_issues=issues)
    if len(json.dumps(private_report).encode())>32*1024*1024:raise ProbeError('control_relation_report_size')
    write_json(private/'control-links.json',private_report)
    unknown=[r for r in store_rows if r['status']=='unsupported']
    report=dict(schema_version=1,dataset='real',status='inferred',
        scope='Selected native stores and same-file lexical blocks linked to declared enum names; not execution edges',
        source_file=relative,source_sha256=sha,enum_declaration=enum,native_sources=source_summaries,native_state_stores=store_rows,
        primitive_literals=primitive_literals(image),linear_windows=checked_windows,
        linear_window_coverage_status=checked_windows['status'],
        native_store_count=len(store_rows),unknown_store_count=len(unknown),native_coverage_status='unsupported' if unknown else 'verified',
        lexical_blocks=len(bindings),family_counts=dict(families),block_examples=bindings[:20],example_limit=20,
        marker_counts=dict(Counter(m['command'] for m in markers)),marker_status_counts=dict(Counter(m['status'] for m in markers)),
        marker_examples=markers[:20],unassociated_marker_examples=[m for m in markers if m['status']!='inferred'][:20],
        grammar_issues=issues,grammar_coverage_status='unsupported' if issues else 'inferred',per_file=files,
        command_counts=dict(commands),excluded_command_counts=dict(excluded),excluded_record_type_counts=dict(record_kinds),
        private_links=(private/'control-links.json').relative_to(ROOT).as_posix(),
        routine_state_transitions='not_tested',non_command_line_skip_paths='not_tested',
        execution_semantics='not_tested',runtime_development_ready=False,
        original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status='inferred',native_stores=len(store_rows),unknown_stores=len(unknown),
        lexical_blocks=len(bindings),marker_statuses=report['marker_status_counts'])))
    return 0


if __name__=='__main__':
    try:
        with processing_deadline():code=main()
    except (OSError,ValueError) as exc:
        write_json(ROOT/'private/p1-round10/control-analysis-failure.json',
            dict(status='unsupported',error_type=type(exc).__name__,reason=str(exc),
                scope='Failed standalone analysis attempt; previous reports are not a success for this attempt'))
        print(str(exc),file=sys.stderr);code=2
    raise SystemExit(code)
