#!/usr/bin/env python3
"""Attach source-traceable frame/scope contracts; no stack or script is executed."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_class,parse_record
    from .object_callback_probe import relative_call
    from .subp_analysis import proof,call_shape
    from .control_state_analysis import processing_deadline
    from .qlie_lex import lex,digest
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_class,parse_record
    from object_callback_probe import relative_call
    from subp_analysis import proof,call_shape
    from control_state_analysis import processing_deadline
    from qlie_lex import lex,digest


def return_projection(count,target):
    """Index geometry of a selected valid return; never remove or restore an object."""
    if type(count) is not int or type(target) is not int or not 0<=count<=1024:
        raise ProbeError('frame_return_projection_limit')
    row=dict(status='inferred',routine_count=count,target_index=target,actual_return='not_tested')
    if count<2 or not 0<=target<count-1:
        return dict(row,status='unsupported',unknown_reason='Not a reviewed valid return to a retained routine')
    return dict(row,retained_count=target+1,first_removed_index=target+1,removed_count=count-target-1,
        resume_data_source_index=target+1,scope_owner_candidate='retained_target_routine',
        result_restore_condition='first_removed_routine_flag',cleanup_equivalence='not_tested')


def bindings(image,plan):
    classes=plan['classes']
    if len(classes)!=2 or [r['name'] for r in classes]!=['TScriptThread','TScriptRoutine']:
        raise ProbeError('frame_class_plan')
    rows=[];routine=None
    for spec in classes:
        vmt=int(spec['vmt'],16);decl=parse_class(image,vmt,0,spec['name']);methods={m['name']:m['code_address'] for m in decl['methods']}
        expected=[(12,'Add')] if spec['name']=='TScriptThread' else [(8,'Init'),(12,'Add')]
        if [s['offset'] for s in spec['slots']]!=[s[0] for s in expected]:raise ProbeError('frame_slot_plan')
        selected=[]
        for slot,(_,name) in zip(spec['slots'],expected):
            target=image.u32(vmt+slot['offset'])
            if hex(target)!=slot['target'] or hex(target)!=methods[name]:raise ProbeError('frame_method_slot_mismatch')
            image.code(target);selected.append(dict(method=name,offset=slot['offset'],target=hex(target),
                raw_bytes_reference=image.reference(vmt+slot['offset'],4)))
        rows.append(dict(name=spec['name'],vmt=hex(vmt),header_reference=decl['header_reference'],selected_slots=selected))
        if spec['name']=='TScriptRoutine':routine=decl
    fields={f['name']:f for f in routine['fields']};scope=fields['Scope'];array=scope['type_info'].get('array_header',{})
    if (scope['offset'],array.get('declared_bytes'),array.get('element_count'),fields['FResultRestory']['offset'],fields['ResultRecord']['offset'])!=(12,64,16,8,104):
        raise ProbeError('frame_scope_result_layout')
    at=int(plan['base_init_call'],16)
    if image.read(at,3)!=b'\xff\x52\x08':raise ProbeError('frame_base_virtual_init_encoding')
    clear=relative_call(image,int(plan['scope_init_call'],16),int(plan['scope_init_target'],16))
    at_subr=int(plan['subr_compare'],16)
    if image.read(at_subr,7)!=b'\x81\x7d\xd8'+struct.pack('<I',0x72627573):raise ProbeError('frame_subr_comparison_encoding')
    spec=plan['result_record'];record=parse_record(image,int(spec['type_info'],16),int(spec['fields_count_address'],16),spec['name'])
    if record['declared_size']!=268:raise ProbeError('frame_result_record_size')
    return dict(status='inferred',scope='Selected class/slot and record bindings only; full constructor, destructor and exception ABI unknown',
        classes=rows,scope_field=scope,result_restore_flag=fields['FResultRestory'],result_record_field=fields['ResultRecord'],
        virtual_init_reference=image.reference(at,3),scope_init_call=clear,subr_compare_reference=image.reference(at_subr,7),
        result_record=record,actual_scope_inheritance='not_tested')


def site_shape(record):
    token=record['token'].lower();fields=record['operands']
    if token=='ret':
        row=dict(status='inferred',command=token,lexical_arity=len(fields),actual_target='not_tested',scope_resume='retained_routine_candidate')
        if len(fields)==0:row['target_role']='default_count_minus_two_candidate'
        elif len(fields)==1:row['target_role']='normalized_named_context_candidate'
        else:row.update(status='unsupported',unknown_reason='Return arity outside reviewed zero/one source fields')
        return row
    if token not in {'sub','subp','subr'}:raise ProbeError('frame_site_command_outside_scope')
    row=call_shape(dict(record,token=token))
    row.update(new_routine_scope='init_clears_sixteen_candidate',caller_scope_owner='retained_caller_routine_candidate',
        actual_scope_inheritance='not_tested',actual_call='not_tested',
        result_snapshot_role='conditional_result_register_snapshot_candidate' if token=='subr' else 'no_snapshot_on_reviewed_variant_branch',
        activation_condition='Target resolves and selected success path reaches frame construction',
        scope_snapshot='not_tested')
    return row


def analyze_documents(assets,items):
    if not 1<=len(items)<=2000:raise ProbeError('frame_corpus_count_limit')
    rows=[];files=[];total=0;seen=set()
    for item in items:
        relative=safe_member_name(item['source_file'])
        if relative in seen:raise ProbeError('frame_duplicate_source')
        seen.add(relative);data=read_bounded(assets/relative,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('frame_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('frame_corpus_identity')
        doc=lex(data,relative,field_model='native_grouping')
        if doc['status']!='verified':raise ProbeError('frame_lexical_failure')
        found=0
        for record in doc['records']:
            if record['record_type']=='command' and record['token'].lower() in {'sub','subp','subr','ret'}:
                rows.append(dict(**proof(doc,record),**site_shape(record)));found+=1
                if len(rows)>20000:raise ProbeError('frame_source_site_limit')
        files.append(dict(source_file=relative,source_sha256=item['sha256'],site_count=found))
    return rows,files


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',required=True,type=Path)
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/frame-scope-audit-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('frame_summary_must_be_public_P1')
    for source in [game,assets]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('frame_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    plan=json.loads(read_bounded(ROOT/'docs/frame-scope-byte-plan.json'));inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    native_bytes=read_bounded(ROOT/'reports/p1/frame-scope-native-report.json');native=json.loads(native_bytes)
    required={'base_calls_virtual_init','routine_calls_base_create','return_selects_first_removed','return_trims_after_restore','subr_snapshot_gate'}
    if plan.get('schema_version')!=1 or sha!=plan.get('source_sha256') or sha!=native.get('source_sha256') or not any(
        f['path']==relative and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('frame_source_identity')
    if native.get('status')!='inferred' or native.get('errors') or native.get('independent_collection',{}).get('status')!='verified' or not required<=set(
        f['id'] for f in native['observations'] if f['status']=='verified'):raise ProbeError('frame_native_facts_missing')
    checked=bindings(Image(program),plan);corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    with processing_deadline(120):rows,files=analyze_documents(assets,corpus['items'])
    if digest(read_bounded(game/relative,64*1024*1024))!=sha:raise ProbeError('frame_source_changed_during_probe')
    counts=dict(Counter(r['command'] for r in rows))
    report=dict(schema_version=1,status='inferred',dataset='real',scope='Static frame contracts attached to source spellings only; no call/return execution',
        source_file=relative,source_sha256=sha,native_report='reports/p1/frame-scope-native-report.json',native_report_sha256=digest(native_bytes),
        native_bindings=checked,physical_corpus_files=len(files),all_versions_preserved=True,sites=rows,per_file=files,
        command_counts=counts,site_status_counts=dict(Counter(r['status'] for r in rows)),
        variant_presence_status={name:('verified' if counts.get(name) else 'not_tested') for name in ['sub','subp','subr','ret']},
        variant_presence_scope='Direct lexical source occurrences only; generated commands are outside this count',
        scope_initialization_contract='inferred',scope_return_contract='inferred',actual_scope_inheritance='not_tested',
        result_restore_semantics='not_tested',full_cleanup_equivalence='not_tested',runtime_development_ready=False,
        original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],files=len(files),sites=len(rows),commands=counts)))
    return 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as exc:
        write_json(ROOT/'private/p1-round18/frame-scope-audit-failure.json',dict(status='unsupported',error=str(exc),scope='Failed audit; no partial site promoted'))
        raise
