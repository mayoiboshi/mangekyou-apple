#!/usr/bin/env python3
"""Bounded call-byte candidates and one reviewed state dispatch, never execution."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import struct
import sys

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_class
    from .control_state_analysis import processing_deadline,instruction_rows
    from .qlie_lex import lex,digest
    from .rea_static import validate_plan,checked_evidence
    from .review_native import window_summary
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_class
    from control_state_analysis import processing_deadline,instruction_rows
    from qlie_lex import lex,digest
    from rea_static import validate_plan,checked_evidence
    from review_native import window_summary


def call_candidates(image,targets,limit=128):
    """E8-looking bytes may occur inside data or another instruction's operand."""
    if not 1<=len(targets)<=8 or len(set(targets))!=len(targets):raise ProbeError('reader_target_count_or_duplicate')
    for target in targets:image.code(target)
    result=[];examined=0
    for section in image.pe['sections']:
        if not section['executable']:continue
        lo=section['raw_offset'];hi=lo+section['raw_size'];examined+=hi-lo;cursor=lo
        if examined>32*1024*1024:raise ProbeError('reader_scan_byte_limit')
        while True:
            at=image.data.find(b'\xe8',cursor,hi-4)
            if at<0:break
            cursor=at+1;va=image.pe['image_base']+section['rva']+at-lo
            target=(va+5+struct.unpack_from('<i',image.data,at+1)[0])&0xffffffff
            if target not in targets:continue
            if len(result)>=limit:raise ProbeError('reader_candidate_count_limit')
            result.append(dict(address=hex(va),target=hex(target),status='inferred',
                raw_bytes_reference=image.reference(va,5),raw_encoding='verified',
                instruction_boundary='not_tested',reachability='not_tested'))
    return result,examined


def state_dispatch(image,enum,guard,expected_table,handlers_start,default_target,field_offset):
    """Admit just the reviewed unsigned-byte guard and absolute indexed table."""
    minimum=enum['minimum_i32'];maximum=enum['maximum_i32'];members=enum['members']
    if minimum!=0 or not 0<=maximum<32 or [m['value'] for m in members]!=list(range(maximum+1)):
        raise ProbeError('reader_dispatch_enum_shape')
    if not 0<=field_offset<=127:raise ProbeError('reader_dispatch_field_offset')
    raw=image.read(guard,23)
    if (raw[:12]!=b'\x0f\xb6\x58'+bytes([field_offset])+b'\x0f\xb6\xc3\x83\xf8'+bytes([maximum])+b'\x0f\x87'
        or raw[16:19]!=b'\xff\x24\x85'):raise ProbeError('reader_dispatch_guard_encoding')
    default=(guard+16+struct.unpack_from('<i',raw,12)[0])&0xffffffff
    table=struct.unpack_from('<I',raw,19)[0]
    if table!=expected_table or default!=default_target or table+4*len(members)!=handlers_start:
        raise ProbeError('reader_dispatch_plan_disagrees_with_bytes')
    if not handlers_start<default<=handlers_start+8192:raise ProbeError('reader_dispatch_handler_range')
    targets=struct.unpack('<'+'I'*len(members),image.read(table,4*len(members)));result=[]
    for member,target in zip(members,targets):
        if not handlers_start<=target<default:raise ProbeError('reader_dispatch_target_outside_scope')
        image.code(target)
        result.append(dict(value=member['value'],declared_name=member['name'],branch_address=hex(target),
            status='inferred',table_bytes_status='verified',owner_binding='inferred',execution_semantics='not_tested',
            enum_member_reference=member['raw_bytes_reference'],table_reference=image.reference(table+member['value']*4,4)))
    return dict(status='inferred',guard_reference=image.reference(guard,23),table_reference=image.reference(table,4*len(members)),
        default_target=hex(default),bindings=result,field_offset=field_offset,execution_semantics='not_tested')


def branch_observations(image,dispatch,text):
    rows=instruction_rows(text,'llvm');bindings=dispatch['bindings']
    boundaries=sorted(set(int(b['branch_address'],16) for b in bindings)|{int(dispatch['default_target'],16)})
    for binding in bindings:
        start=int(binding['branch_address'],16);end=min(b for b in boundaries if b>start)
        calls=[];resets=[]
        for address,instruction in rows:
            if not start<=address<end:continue
            match=re.match(r'^CALL 0X([0-9A-F]+)(?:\s|$)',instruction)
            if match:
                raw=image.read(address,5);target=int(match.group(1),16)
                if raw[0]!=0xe8 or (address+5+struct.unpack_from('<i',raw,1)[0])&0xffffffff!=target:
                    raise ProbeError('reader_branch_call_encoding_mismatch')
                calls.append(dict(address=hex(address),target=hex(target),status='verified',
                    raw_bytes_reference=image.reference(address,5),scope='Encoding and target only; call execution not_tested'))
            if instruction=='MOV BYTE PTR [EAX + 0X4C], 0X0':
                if image.read(address,4)!=b'\xc6\x40\x4c\x00':raise ProbeError('reader_state_reset_encoding')
                resets.append(dict(address=hex(address),value=0,status='verified',
                    raw_bytes_reference=image.reference(address,4),scope='Store bytes only; reachability not_tested'))
        binding.update(direct_call_observations=calls,state_reset_observations=resets)
    return dispatch


def spelling_records(assets):
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'));items=corpus['items'];total=0;found=[]
    if not 1<=len(items)<=2000:raise ProbeError('reader_corpus_file_limit')
    for item in items:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('reader_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('reader_corpus_digest')
        doc=lex(data,rel)
        if doc['status']!='verified':raise ProbeError('reader_corpus_lexical_failure')
        for record in doc['records']:
            if record['record_type']!='command' or record['token'].lower()!='dbrk':continue
            found.append(dict(source_file=rel,source_sha256=item['sha256'],byte_offset=record['byte_offset'],
                byte_length=record['byte_length'],raw_bytes_reference=record['raw_bytes_reference'],
                command='dbrk',arity=len(record['operands']),status='inferred',
                local_dispatch_fact='dbrk_branch_to_handled_tail',lexical_family_binding='not_tested',
                global_execution_semantics='not_tested'))
            if len(found)>128:raise ProbeError('reader_spelling_reference_limit')
    return found,len(items)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--evidence-dir',type=Path,default=ROOT/'private/p1-round11/native-reproduced')
    p.add_argument('--windows-dir',type=Path,default=ROOT/'private/p1-round11/windows-final')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/reader-analysis-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);evidence=absolute(args.evidence_dir)
    windows=absolute(args.windows_dir);output=absolute(args.output)
    if any(ROOT/'private' not in path.parents for path in [evidence,windows]):raise ProbeError('reader_details_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('reader_summary_must_be_public_P1')
    for source in [game,assets]:
        if output==source or output in source.parents or source in output.parents:raise ProbeError('reader_output_input_overlap')
    rel=safe_member_name(args.exe);data=read_bounded(game/rel,64*1024*1024);sha=digest(data);image=Image(data)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(x['path']==rel and x.get('sha256')==sha for x in inventory['files']):raise ProbeError('reader_source_inventory')
    plans=[json.loads(read_bounded(ROOT/'docs'/name)) for name in ['native-reader-call-plan.json','native-reader-state-plan.json','native-reader-plan.json','delphi-metadata-plan.json']]
    if any(plan.get('schema_version')!=1 or plan.get('source_sha256')!=sha for plan in plans):raise ProbeError('reader_plan_identity')
    call_plan,state_plan,plan,metadata_plan=plans;records={};queries=validate_plan(plan)
    for q in queries:
        record=json.loads(read_bounded(evidence/(q['name']+'.json'),16*1024*1024))
        checked_evidence(record,sha,q['operation'],q['address']);records[q['name']]=record
    collection=json.loads(read_bounded(evidence/'collection-report.json'))
    if (collection.get('status')!='verified' or collection.get('errors') or collection.get('cleanup')!='verified'
        or collection.get('source_sha256')!=sha or collection.get('original_sha256_after')!=sha
        or len(collection.get('queries',[]))!=len(queries)
        or {(r['name'],r['address']) for r in collection['queries'] if r['status']=='verified'}!={(q['name'],q['address']) for q in queries}):
        raise ProbeError('reader_collection_incomplete')
    candidates,examined=call_candidates(image,[int(v,16) for v in call_plan['targets']])
    xrefs={target:set(records[name]['normalized_result']) for target,name in [('0x6aacf8','command-call-xrefs'),('0x695a7c','chunk-reader-xrefs')]}
    owners={q['address']:records[q['name']]['normalized_result'] for q in queries if q['operation']=='resolve_containing_procedure'}
    for candidate in candidates:
        candidate['present_in_provider_xrefs']=candidate['address'] in xrefs[candidate['target']]
        owner=owners.get(candidate['address'])
        candidate['default_function_owner']=('verified' if owner['found'] else 'unsupported') if owner else 'not_tested'
        if owner and not owner['found']:candidate['unknown_reason']='Default provider has no containing procedure; byte candidate alone is not a call proof'
    spec=next(c for c in metadata_plan['classes'] if c['name']=='TScriptRoutine')
    declaration=parse_class(image,int(spec['vmt'],16),spec['slots'],spec['name'])
    field=next(f for f in declaration['fields'] if f['name']=='State')
    if field['offset']!=state_plan['field_offset'] or field['type_info']['name']!=state_plan['enum_name']:raise ProbeError('reader_state_field_identity')
    dispatch=state_dispatch(image,field['type_info']['enum_header'],*[int(state_plan[k],16) for k in ['guard','table','handlers_start','default_target']],state_plan['field_offset'])
    checked_windows=window_summary(windows,sha,data)
    handler_record=json.loads(read_bounded(windows/'routine-state-handlers.json'))
    dispatch=branch_observations(image,dispatch,handler_record['normalized_result'])
    dispatch['window_evidence_id']=handler_record['evidence_id']
    boundary=state_plan['rejected_window_boundary'];call=int(boundary['covering_call'],16);target=int(boundary['call_target'],16)
    rejected=int(boundary['start'],16);assembly=records['generic-dispatch-assembly'];raw=image.read(call,5)
    anchor=f'0x{call:x}: CALL 0x{target:08x}'
    if (anchor not in assembly['normalized_result'] or not call<rejected<call+5 or raw[0]!=0xe8
        or (call+5+struct.unpack_from('<i',raw,1)[0])&0xffffffff!=target):raise ProbeError('reader_rejected_boundary_evidence')
    boundary_review=dict(status='unsupported',rejected_start=hex(rejected),corrected_start=boundary['corrected_start'],
        reason='Preliminary window starts inside an observed CALL operand; successful linear decoding is not a boundary proof',
        covering_call_reference=image.reference(call,5),evidence_id=assembly['evidence_id'],preliminary_plan=boundary['plan'])
    spellings,file_count=spelling_records(assets)
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='E8 byte candidates, one guarded state table, selected branch instructions and dbrk spellings; no scheduler or script execution',
        source_file=rel,source_sha256=sha,call_candidates=candidates,executable_bytes_scanned=examined,
        candidate_counts=dict(Counter(c['target'] for c in candidates)),
        candidates_absent_from_provider_xrefs=sum(not c['present_in_provider_xrefs'] for c in candidates),
        call_graph_completeness='not_tested',native_state_dispatch=dispatch,
        handler_analysis_scope='Only direct E8 calls and immediate zero stores at selected EAX+0x4c boundaries; other instructions are not interpreted',
        preliminary_boundary_review=boundary_review,preliminary_boundary_coverage_status='unsupported',
        linear_windows=checked_windows,linear_window_coverage_status=checked_windows['status'],
        dbrk_records=spellings,dbrk_arity_counts=dict(Counter(str(r['arity']) for r in spellings)),corpus_files_verified=file_count,
        default_function_coverage_status='unsupported' if any(not r['found'] for r in owners.values()) else 'verified',
        non_command_line_skip_paths='not_tested',text_prefix_configuration='not_tested',
        all_wait_semantics='not_tested',execution_semantics='not_tested',runtime_development_ready=False,
        original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status='inferred',candidates=len(candidates),not_in_xrefs=report['candidates_absent_from_provider_xrefs'],
        state_bindings=len(dispatch['bindings']),dbrk=len(spellings))))
    return 0


if __name__=='__main__':
    try:
        with processing_deadline():code=main()
    except Exception as exc:
        write_json(ROOT/'private/p1-round11/reader-analysis-failure.json',dict(status='unsupported',error_type=type(exc).__name__,reason=str(exc)))
        print(str(exc),file=sys.stderr);code=2
    raise SystemExit(code)
