#!/usr/bin/env python3
"""Audit object-scope syntax and selected native bindings without evaluating scripts."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_class
    from .object_callback_probe import relative_call
    from .subp_analysis import proof,field_ref,dispatch_case
    from .control_state_analysis import processing_deadline
    from .qlie_lex import lex,digest
    from .qlie_expr import parse,ExpressionError
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_class
    from object_callback_probe import relative_call
    from subp_analysis import proof,field_ref,dispatch_case
    from control_state_analysis import processing_deadline
    from qlie_lex import lex,digest
    from qlie_expr import parse,ExpressionError


def selector_chain(image,steps,expected):
    if len(steps)!=3:raise ProbeError('scope_selector_step_count')
    total=0;rows=[]
    for step in steps:
        at=int(step['address'],16);value=int(step['subtract'],16);raw=image.read(at,11)
        if raw[0]!=0x2d or struct.unpack_from('<I',raw,1)[0]!=value or raw[5:7]!=b'\x0f\x84':
            raise ProbeError('scope_selector_encoding')
        target=(at+11+struct.unpack_from('<i',raw,7)[0])&0xffffffff
        if target!=int(step['zero_target'],16):raise ProbeError('scope_selector_target')
        image.code(target);total=(total+value)&0xffffffff
        rows.append(dict(subtract_u32=value,zero_target=hex(target),raw_bytes_reference=image.reference(at,11)))
    if total!=expected:raise ProbeError('scope_selector_id')
    return dict(status='inferred',instruction_bytes_status='verified',command_id=hex(total),steps=rows,
        scope='Arithmetic fallthrough condition only; preceding guards and runtime dispatch remain separate evidence')


def bindings(image,plan):
    decl=parse_class(image,int(plan['routine_vmt'],16),0,'TScriptRoutine');fields={f['name']:f for f in decl['fields']}
    scope=fields['Scope'];state=fields['State'];array=scope['type_info'].get('array_header',{})
    if (scope['offset'],state['offset'],array.get('declared_bytes'),array.get('element_count'))!=(12,76,64,16) or (
        plan['scope_offset'],plan['state_offset'],plan['scope_bytes'],plan['scope_slots'])!=(12,76,64,16):
        raise ProbeError('scope_declaration_layout')
    if array.get('element_type',{}).get('name')!='string':raise ProbeError('scope_array_element_type')
    chain=selector_chain(image,plan['selector_steps'],int(plan['selector_id'],16))
    tags=plan['accepted_tag_compares']
    if len(tags)!=2 or [t['tag'] for t in tags]!=[2,1]:raise ProbeError('scope_tag_plan')
    tag_refs=[]
    for tag in tags:
        at=int(tag['address'],16)
        if image.read(at,2)!=b'\x3c'+bytes([tag['tag']]):raise ProbeError('scope_tag_encoding')
        tag_refs.append(dict(tag=tag['tag'],raw_bytes_reference=image.reference(at,2)))
    types=image.type_reference(int(plan['value_type_cell'],16));names={m['value']:m['name'] for m in types['enum_header']['members']}
    if names.get(1)!='vtString' or names.get(2)!='vtObject':raise ProbeError('scope_tag_declarations')
    call=int(plan['comparison_call'],16);comparison=relative_call(image,call,int(plan['comparison_target'],16))
    if image.read(call+5,1)!=b'\x75':raise ProbeError('scope_comparison_flags_branch')
    comparison['following_branch_reference']=image.reference(call+5,2)
    route=plan['object_dispatch']
    dispatch=dispatch_case(image,int(route['guard'],16),int(route['table'],16),route['maximum_type'],
        route['type_index'],int(route['case'],16),int(route['call'],16),int(route['handler'],16))
    return dict(status='inferred',scope='Declaration bytes, selector arithmetic, tag checks and one type route only',
        scope_field=scope,state_field=state,selector_chain=chain,accepted_tag_references=tag_refs,
        registry_comparison=comparison,rep_type_route=dispatch,complete_object_binding='not_tested')


def field_shape(text):
    if len(text)>8192:return dict(status='unsupported',shape='over_limit',unknown_reason='scope_field_character_limit')
    if text=='':return dict(status='inferred',shape='raw_empty',runtime_nil_mapping='not_tested')
    try:root=parse(text)
    except ExpressionError as exc:
        return dict(status='unsupported',shape='unverified_expression',unknown_reason=exc.reason,character_offset=exc.offset)
    return dict(status='inferred',shape=root['kind'],bare_builtin_rep_identifier=text=='rep',
        quoted_builtin_rep_string=text=='"rep"',quoted_empty=text=='""',evaluated_tag='not_tested',evaluated_object_name='not_tested')


def inspect_document(data,filename):
    doc=lex(data,filename,field_model='native_grouping')
    if doc['status']!='verified':raise ProbeError('scope_lexical_failure')
    selectors=[];edges=[];line=None;current=None
    for record in doc['records']:
        if record['record_type']=='label':current=None
        if record['record_type']!='command':continue
        if record['line_number']!=line:line=record['line_number'];current=None
        token=record['token'].lower()
        if token=='scp':
            fields=record['operands'];arity=len(fields);shapes=[]
            for i,f in enumerate(fields[:16]):shapes.append(dict(position=i,field_reference=field_ref(doc,f,data),**field_shape(f['raw'])))
            empty=[i for i,f in enumerate(fields[:16]) if f['raw']=='']
            last=max((i for i,f in enumerate(fields) if f['raw']),default=-1);later=any(i<last for i in empty)
            row=dict(**proof(doc,record),lexical_arity=arity,field_shapes=shapes,raw_empty_positions=empty,
                raw_empty_before_later_source=bool(later),omitted_or_empty_scope=arity==0,
                source_slot_positions_preserved=True,actual_scope_contents='not_tested',
                status='unsupported' if arity>16 or any(s['status']=='unsupported' for s in shapes) else 'inferred')
            if arity>16:row.update(unknown_reason='Source arity exceeds reviewed 16-slot declaration; no overflow emulation',
                unclassified_field_count=arity-16,native_arity_equivalence='not_tested')
            current=row;selectors.append(row)
        elif current:
            edges.append(dict(selector_reference={k:current[k] for k in ['source_file','source_sha256','byte_offset','byte_length','raw_bytes_reference']},
                command_reference=proof(doc,record),command=token,status='inferred',match='same_physical_line_after_scp',
                actual_dispatch='not_tested',dispatch_after_success_candidate='continue_next_slot'))
        if len(selectors)>10000 or len(edges)>20000:raise ProbeError('scope_document_relation_limit')
    return selectors,edges


def analyze_documents(assets,items):
    if not 1<=len(items)<=2000:raise ProbeError('scope_corpus_count_limit')
    selectors=[];edges=[];files=[];total=0;seen=set()
    for item in items:
        relative=safe_member_name(item['source_file'])
        if relative in seen:raise ProbeError('scope_duplicate_source')
        seen.add(relative);data=read_bounded(assets/relative,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('scope_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('scope_corpus_identity')
        rows,links=inspect_document(data,relative);selectors.extend(rows);edges.extend(links)
        if len(selectors)>10000 or len(edges)>20000:raise ProbeError('scope_corpus_relation_limit')
        files.append(dict(source_file=relative,source_sha256=item['sha256'],selectors=len(rows),same_line_edges=len(links)))
    return selectors,edges,files


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',required=True,type=Path)
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/scope-audit-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('scope_summary_must_be_public_P1')
    for source in [game,assets]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('scope_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    plan=json.loads(read_bounded(ROOT/'docs/scope-byte-plan.json'));inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    native_bytes=read_bounded(ROOT/'reports/p1/scope-native-report.json');native=json.loads(native_bytes)
    required={'scope_clear_sixteen','scp_accepted_tags','scope_reader_nil_stop','scope_dispatch_continues','registry_name_guard'}
    if plan.get('schema_version')!=1 or sha!=plan.get('source_sha256') or sha!=native.get('source_sha256') or not any(
        f['path']==relative and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('scope_source_identity')
    if native.get('status')!='inferred' or native.get('errors') or native.get('independent_collection',{}).get('status')!='verified' or not required<=set(
        f['id'] for f in native['observations'] if f['status']=='verified'):raise ProbeError('scope_native_facts_missing')
    image=Image(program);checked=bindings(image,plan);corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    with processing_deadline(120):selectors,edges,files=analyze_documents(assets,corpus['items'])
    if digest(read_bounded(game/relative,64*1024*1024))!=sha:raise ProbeError('scope_source_changed_during_probe')
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='Static scope declarations and lexical same-line edges only; no symbolic or runtime execution',
        source_file=relative,source_sha256=sha,native_report='reports/p1/scope-native-report.json',native_report_sha256=digest(native_bytes),
        native_bindings=checked,physical_corpus_files=len(files),all_versions_preserved=True,selectors=selectors,same_line_edges=edges,per_file=files,
        selector_count=len(selectors),selector_status_counts=dict(Counter(r['status'] for r in selectors)),
        arity_counts=dict(Counter(str(r['lexical_arity']) for r in selectors)),same_line_command_counts=dict(Counter(e['command'] for e in edges)),
        raw_empty_gap_candidates=sum(r['raw_empty_before_later_source'] for r in selectors),
        over_declared_arity_candidates=sum(r['lexical_arity']>16 for r in selectors),
        expression_shape_counts=dict(Counter(f['shape'] for r in selectors for f in r['field_shapes'])),
        namespace_binding='not_tested',actual_startup_reachability='not_tested',scope_inheritance='not_tested',
        scope_dispatch_contract='inferred',registry_lookup_contract='inferred',original_files_written=False,
        external_game_data_uploads=False,runtime_development_ready=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],selectors=len(selectors),edges=len(edges),arity_counts=report['arity_counts'])))
    return 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as exc:
        write_json(ROOT/'private/p1-round17/scope-audit-failure.json',dict(status='unsupported',error=str(exc),scope='Failed audit; no partial relations promoted'))
        raise
