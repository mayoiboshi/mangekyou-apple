#!/usr/bin/env python3
"""Trace bounded omitted-field candidates through pinned static evidence, never execute."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_record
    from .object_callback_probe import relative_call
    from .replacement_audit import analyze_documents
    from .control_state_analysis import processing_deadline
    from .qlie_lex import digest
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_record
    from object_callback_probe import relative_call
    from replacement_audit import analyze_documents
    from control_state_analysis import processing_deadline
    from qlie_lex import digest


def slot_projection(source_field_count,minimum_count,wanted_index):
    """Abstract field origin only; source fields are not evaluated or converted."""
    if any(type(v) is not int for v in [source_field_count,minimum_count,wanted_index]) or not (
        0<=source_field_count<=64 and 1<=minimum_count<=64 and 0<=wanted_index<64):
        raise ProbeError('default_field_projection_limit')
    count=max(source_field_count,minimum_count)
    row=dict(status='inferred',source_field_count=source_field_count,minimum_count=minimum_count,
        wanted_index=wanted_index,list_count_candidate=count,runtime_reachability='not_tested',
        original_execution_equivalence='not_tested')
    if wanted_index>=count:return dict(row,status='unsupported',origin='outside_list',unknown_reason='Index outside projected list')
    if wanted_index<source_field_count:return dict(row,origin='source_field',value_conversion='not_tested',
        unknown_reason='A lexical source field is not assumed to be a null pointer or evaluated value')
    return dict(row,origin='appended_null_candidate',value_conversion='inferred',
        converted_value_candidate=dict(tag_name='vtInteger',integer=0,string_shape='null_pointer'),
        scope='Only the observed null-pointer branch after minimum-count padding')


def binding_checks(image,plan):
    count=plan['minimum_count'];index=plan['mode_field_index']
    if (count,index)!=(9,3):raise ProbeError('default_field_reviewed_counts_changed')
    minimum=int(plan['minimum_load'],16);mode=int(plan['mode_index_load'],16)
    if image.read(minimum,5)!=b'\xb9'+struct.pack('<I',count) or image.read(mode,5)!=b'\xba'+struct.pack('<I',index):
        raise ProbeError('default_field_load_encoding')
    call=relative_call(image,int(plan['split_call'],16),int(plan['split_target'],16))
    vmt=int(plan['list_vmt'],16)
    if image.u32(vmt-88)!=vmt or image.short(image.u32(vmt-56))[0]!=plan['list_name']:
        raise ProbeError('default_field_list_identity')
    slots=plan['slots']
    if [s['offset'] for s in slots]!=[12,20,56,60,152]:raise ProbeError('default_field_slot_plan')
    selected=[]
    for slot in slots:
        at=vmt+slot['offset'];target=image.u32(at)
        if target!=int(slot['target'],16):raise ProbeError('default_field_slot_mismatch')
        image.code(target);selected.append(dict(offset=slot['offset'],target=hex(target),
            raw_bytes_reference=image.reference(at,4)))
    count_target=int(selected[1]['target'],16)
    if image.read(count_target,4)!=b'\x8b\x40\x20\xc3':raise ProbeError('default_field_count_getter_encoding')
    record=plan['return_record'];declaration=parse_record(image,int(record['type_info'],16),
        int(record['fields_count_address'],16),record['name'])
    if declaration['declared_size']!=12 or [(f['name'],f['offset']) for f in declaration['fields']]!=[
        ('ValueType',0),('IntValue',4),('StrValue',8)]:raise ProbeError('default_field_return_layout')
    value_type=declaration['fields'][0]['type_info']
    if value_type.get('name')!='TScriptValueType' or not any(m['value']==0 and m['name']=='vtInteger'
        for m in value_type.get('enum_header',{}).get('members',[])):raise ProbeError('default_field_integer_tag')
    return dict(status='verified',scope='Fixed loads, direct parser call, class/slots and return declaration bytes only',
        minimum_load_reference=image.reference(minimum,5),mode_index_reference=image.reference(mode,5),
        split_call=call,slots=selected,count_getter_reference=image.reference(count_target,4),
        return_record=declaration,complete_ABI='not_tested')


def project_candidates(rows,count,index):
    if len(rows)>10000:raise ProbeError('default_field_candidate_limit')
    selected=[];skipped=0
    for row in rows:
        hint=row.get('same_line_selector_hint')
        if not hint or not hint['matches_builtin_rep_literal']:skipped+=1;continue
        # Slot zero is the command field. Only slot origin/count is modeled.
        projection=slot_projection(row['lexical_arity']+1,count,index)
        selected.append(dict(**{k:row[k] for k in ['source_file','source_sha256','byte_offset','byte_length','raw_bytes_reference']},
            lexical_arity=row['lexical_arity'],selector_reference=hint['reference'],projection=projection,
            namespace_binding='not_tested',actual_registration='not_tested'))
    return selected,skipped


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',required=True,type=Path)
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/default-field-audit-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('default_field_summary_must_be_public_P1')
    for source in [game,assets]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('default_field_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    plan=json.loads(read_bounded(ROOT/'docs/default-field-byte-plan.json'))
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    native_bytes=read_bounded(ROOT/'reports/p1/default-field-native-report.json');native=json.loads(native_bytes)
    if plan.get('schema_version')!=1 or plan.get('source_sha256')!=sha or native.get('source_sha256')!=sha or not any(
        f['path']==relative and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('default_field_source_identity')
    required={'command_minimum_nine','padding_parent_count','null_value_result','registration_mode_source','registration_mode_store'}
    if native.get('status')!='inferred' or native.get('errors') or native.get('independent_collection',{}).get('status')!='verified' or not required<=set(
        f['id'] for f in native['observations'] if f['status']=='verified'):raise ProbeError('default_field_native_facts_missing')
    image=Image(program);bindings=binding_checks(image,plan)
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    with processing_deadline(120):rows,_,files=analyze_documents(assets,corpus['items'])
    selected,skipped=project_candidates(rows,plan['minimum_count'],plan['mode_field_index'])
    after=digest(read_bounded(game/relative,64*1024*1024))
    if after!=sha:raise ProbeError('default_field_source_changed_during_probe')
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='Omitted field conditional static projection only; no value evaluator or runtime execution',
        source_file=relative,source_sha256=sha,source_sha256_after=after,native_binding_checks=bindings,
        native_report='reports/p1/default-field-native-report.json',native_report_sha256=digest(native_bytes),
        physical_corpus_files=len(files),all_versions_preserved=True,a_spelling_candidates=len(rows),
        selected_candidate_count=len(selected),selected_candidates=selected,
        origin_counts=dict(Counter(r['projection']['origin'] for r in selected)),
        skipped_candidates=dict(count=skipped,status='not_tested',reason='No same-line literal rep selector hint; namespace not inferred'),
        omitted_mode_status='inferred',namespace_binding='not_tested',actual_registration='not_tested',
        replacement_execution='not_tested',original_files_written=False,external_game_data_uploads=False,
        preconditions=['Reviewed source command segment reaches the selected parser and rep handler',
            'List creation, padding and retrieval complete normally without mutation or callback failure',
            'No preprocessing or dynamic object binding changes the candidate before dispatch'],
        runtime_development_ready=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],files=len(files),selected=len(selected),origin_counts=report['origin_counts'])))
    return 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as exc:
        write_json(ROOT/'private/p1-round16/default-field-failure.json',dict(status='unsupported',error=str(exc),
            scope='Failed audit; no partial results promoted'))
        raise
