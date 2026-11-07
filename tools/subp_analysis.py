#!/usr/bin/env python3
"""Audit versioned field boundaries and trace prefix/call candidates, never execute."""
import argparse
from collections import Counter,defaultdict
import json
from pathlib import Path
import struct
import sys

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .control_state_analysis import processing_deadline
    from .delphi_metadata import Image
    from .qlie_lex import lex,digest
    from .semantic_evidence import parameter_footprints
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from control_state_analysis import processing_deadline
    from delphi_metadata import Image
    from qlie_lex import lex,digest
    from semantic_evidence import parameter_footprints


def proof(doc,record):
    return dict(source_file=doc['source_file'],source_sha256=doc['sha256'],byte_offset=record['byte_offset'],
        byte_length=record['byte_length'],raw_bytes_reference=record['raw_bytes_reference'])


def field_ref(doc,field,data):
    a=field['byte_offset'];b=a+field['byte_length']
    if not 0<=a<=b<=len(data):raise ProbeError('subp_field_reference_bounds')
    return dict(source_file=doc['source_file'],source_sha256=doc['sha256'],byte_offset=a,byte_length=b-a,
        raw_bytes_reference=dict(offset=a,length=b-a,sha256=digest(data[a:b])))


def file_shape(fields):
    if len(fields)<2:return 'absent'
    value=fields[1]['raw']
    return ('raw_empty' if value=='' else 'quoted_empty' if value=='""' else
        'self_literal' if value.lower()=='self' else 'expression_or_other')


def call_shape(record):
    fields=record['operands'];token=record['token'].lower()
    return dict(command=token,lexical_arity=len(fields),file_operand_shape=file_shape(fields),
        raw_tail_field_count=max(0,len(fields)-2),raw_empty_tail_positions=[i for i,f in enumerate(fields[2:]) if f['raw']==''],
        quoted_empty_tail_positions=[i for i,f in enumerate(fields[2:]) if f['raw']=='""'],
        packing_role='raw_field_tail_merge_candidate' if token=='subp' else 'ordinary_or_auxiliary_call_candidate',
        status='inferred',field_model='native_grouping',nil_pointer_mapping='not_tested',runtime_argument_count='not_tested')


def dispatch_case(image,guard,table,maximum,index,case,call,handler):
    if not 0<=index<=maximum<=63:raise ProbeError('subp_object_type_range')
    raw=image.read(guard,20)
    if raw[:7]!=b'\x0f\xb6\x47\x0c\x83\xf8'+bytes([maximum]) or raw[7:9]!=b'\x0f\x87' or raw[13:16]!=b'\xff\x24\x85':
        raise ProbeError('subp_object_guard_encoding')
    if struct.unpack_from('<I',raw,16)[0]!=table or image.u32(table+4*index)!=case:
        raise ProbeError('subp_object_case_disagrees_with_table')
    if not table+4*(maximum+1)<=case<=call<case+128:raise ProbeError('subp_object_case_window_limit')
    image.code(case);encoded=image.read(call,5)
    if encoded[0]!=0xe8 or (call+5+struct.unpack_from('<i',encoded,1)[0])&0xffffffff!=handler:
        raise ProbeError('subp_object_handler_call_encoding')
    return dict(status='inferred',object_type=index,object_field_offset=0xc,handler_address=hex(handler),
        guard_reference=image.reference(guard,20),table_entry_reference=image.reference(table+4*index,4),
        handler_call_reference=image.reference(call,5),execution_semantics='not_tested')


def structures(image,plan):
    vmt=int(plan['string_list_vmt'],16)
    if image.u32(vmt-88)!=vmt or image.short(image.u32(vmt-56))[0]!=plan['string_list_name']:
        raise ProbeError('subp_field_list_class_identity')
    slots=[]
    for row in plan['selected_slots']:
        at=vmt+row['offset'];target=image.u32(at)
        if target!=int(row['target'],16):raise ProbeError('subp_field_list_slot_identity')
        image.code(target);slots.append(dict(offset=row['offset'],target=hex(target),raw_bytes_reference=image.reference(at,4)))
    literals=[]
    for address,text in [(int(a,16),'rep') for a in plan['rep_literals']]+[(int(plan['comma_literal'],16),',')]:
        raw=(text+'\0').encode('utf-16le')
        if image.u32(address-4)!=len(text) or image.read(address,len(raw))!=raw:raise ProbeError('subp_builtin_literal_identity')
        literals.append(dict(symbol=text,address=hex(address),status='verified',scope='Constant bytes only',
            raw_bytes_reference=image.reference(address,len(raw))))
    binding=dispatch_case(image,int(plan['object_guard'],16),int(plan['object_table'],16),plan['maximum_type'],
        plan['rep_type'],int(plan['rep_case'],16),int(plan['rep_call'],16),int(plan['rep_handler'],16))
    return dict(status='inferred',string_list=dict(name=plan['string_list_name'],vmt=hex(vmt),
        header_reference=image.reference(vmt-88,88),selected_slots=slots,complete_ABI='not_tested'),
        preliminary_reference_assumption=dict(status='unsupported',scope='Rejected treating this admitted direct VMT as a self-pointer cell',
            referenced_address=hex(image.u32(vmt)),raw_bytes_reference=image.reference(vmt,4)),
        literals=literals,rep_dispatch=binding,creation_callback_link='not_tested',namespace_shadowing='not_tested')


def inspect_document(data,filename):
    old=lex(data,filename);doc=lex(data,filename,field_model='native_grouping')
    before={(r['byte_offset'],r['byte_length']):r for r in old['records'] if r['record_type']=='command'}
    changed=[];regions=[];prefixes=[];variants=[];calls=Counter();arities=defaultdict(Counter)
    current=None;selector=None;mention_count=0
    for record in doc['records']:
        if len(regions)>10000 or len(prefixes)>512 or len(variants)>10000:raise ProbeError('subp_document_relation_limit')
        if record['record_type']=='label':
            current=dict(label_reference=proof(doc,record),identifier_sha256=digest(record['identifier'].encode()),
                _identifier=record['identifier'],command_count=0,param_str_zero_mentions=[])
            regions.append(current);selector=None
        if record['record_type']!='command':continue
        token=record['token'].lower();key=(record['byte_offset'],record['byte_length']);prior=before.get(key)
        positions=lambda r:[(f['byte_offset'],f['byte_length']) for f in r['operands']]
        if prior is None or positions(prior)!=positions(record):
            changed.append(dict(**proof(doc,record),command=token,old_arity=len(prior['operands']) if prior else None,
                new_arity=len(record['operands']),old_field_spans=positions(prior) if prior else [],new_field_spans=positions(record)))
        if token=='scp':
            value=record['operands'][0]['raw'] if record['operands'] else ''
            selector=dict(reference=proof(doc,record),matches_builtin_rep=value in {'rep','"rep"'},status='inferred')
        if current:
            current['command_count']+=1
            for field in record['operands']:
                footprints,_=parameter_footprints(field['raw'])
                for footprint in footprints:
                    if footprint['register']=='ParamStr' and footprint['index']==0:
                        mention_count+=1
                        if mention_count>10000:raise ProbeError('subp_parameter_mention_limit')
                        current['param_str_zero_mentions'].append(dict(record_reference=proof(doc,record),
                            field_reference=field_ref(doc,field,data),character_offset=footprint['char_offset'],
                            status='inferred',read_write_direction='not_tested'))
        if token in {'sub','subp','subr'}:
            calls[token]+=1;arities[token][str(len(record['operands']))]+=1
            if token!='sub':variants.append(dict(**proof(doc,record),**call_shape(record)))
        if token not in {'et','nt'}:continue
        row=dict(**proof(doc,record),command=token,status='inferred',namespace_hint=selector,
            namespace_binding='not_tested',actual_execution='not_tested')
        if len(record['operands'])!=1:
            row.update(status='unsupported',unknown_reason='Setter spelling outside the reviewed one-field path')
            prefixes.append(row);continue
        field=record['operands'][0];raw=field['raw'];row['parent_field_reference']=field_ref(doc,field,data)
        if len(raw)<2 or raw[0]!='"' or raw[-1]!='"' or '"' in raw[1:-1]:
            row.update(literal_shape='not_tested',unknown_reason='Not one simple literal quote pair');prefixes.append(row);continue
        literal=raw[1:-1]
        if len(literal)>8192:raise ProbeError('subp_prefix_character_limit')
        row['empty_literal']=not literal;row['derived_calls']=[]
        virtual=lex(b'\xff\xfe'+literal.encode('utf-16le'),'<prefix>',field_model='native_grouping')
        if virtual['status']!='verified':row.update(status='unsupported',unknown_reason='Derived prefix lexical failure')
        for child in virtual['records']:
            if child['record_type']!='command' or child['token'].lower()!='subp':continue
            shape=call_shape(child);fields=child['operands'];label=fields[0]['raw'] if fields else ''
            target=label[2:] if label.startswith('@@') else None
            row['derived_calls'].append(dict(**shape,target_identifier_sha256=digest(target.encode()) if target else None,
                _target=target,origin='quoted_prefix_literal',native_target_resolution='not_tested'))
        prefixes.append(row)
    if len(regions)>10000 or len(prefixes)>512 or len(variants)>10000:raise ProbeError('subp_document_relation_limit')
    return dict(doc=doc,old_status=old['status'],changes=changed,regions=regions,prefixes=prefixes,
        variants=variants,calls=calls,arities=arities,
        command_records_compared=sum(r['record_type']=='command' for r in doc['records']))


def link_prefixes(prefixes,regions):
    lookup=defaultdict(list)
    for region in regions:lookup[region['_identifier']].append(region)
    edges=[];receivers={}
    for prefix in prefixes:
        for call in prefix['derived_calls'] if 'derived_calls' in prefix else []:
            target=call.pop('_target',None)
            matches=lookup.get(target,[]) if target else []
            call['label_candidate_count']=len(matches)
            if not matches:call['unknown_reason']='No exact lexical label candidate; dynamic or included targets not resolved'
            for region in matches:
                ref=region['label_reference'];key=(ref['source_file'],ref['byte_offset'])
                receivers[key]={k:v for k,v in region.items() if not k.startswith('_')}
                edges.append(dict(prefix_reference={k:prefix[k] for k in ['source_file','source_sha256','byte_offset','byte_length','raw_bytes_reference']},
                    receiver_reference=ref,same_source_file=prefix['source_file']==ref['source_file'],
                    match='exact_lexical_identifier',status='inferred',runtime_target='not_tested'))
    if len(edges)>10000:raise ProbeError('subp_prefix_edge_limit')
    return edges,list(receivers.values())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--native-report',type=Path,default=ROOT/'reports/p1/subp-native-report.json')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/subp-analysis-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('subp_summary_must_be_public_P1')
    for source in [game,assets]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('subp_input_output_overlap')
    rel=safe_member_name(args.exe);program=read_bounded(game/rel,64*1024*1024);sha=digest(program)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(f['path']==rel and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('subp_source_identity')
    plan=json.loads(read_bounded(ROOT/'docs/native-subp-structure-plan.json'))
    if plan.get('schema_version')!=1 or plan['source_sha256']!=sha:raise ProbeError('subp_structure_plan_identity')
    native_path=absolute(args.native_report)
    if ROOT/'reports/p1' not in native_path.parents:raise ProbeError('subp_native_summary_location')
    native_bytes=read_bounded(native_path);native=json.loads(native_bytes)
    required={'subp_tail_merge','call_pad_nineteen','native_group_depth','builtin_rep_register','rep_constructor_tag'}
    if (native.get('source_sha256')!=sha or native.get('status')!='inferred' or native.get('errors')
        or native.get('independent_collection',{}).get('status')!='verified'
        or not required<={f['id'] for f in native['observations'] if f['status']=='verified'}):raise ProbeError('subp_native_evidence_identity')
    items=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))['items']
    if not 1<=len(items)<=2000:raise ProbeError('subp_corpus_limit')
    prefixes=[];regions=[];variants=[];changes=[];errors=[];files=[];counts=Counter();arities=defaultdict(Counter);total=0;compared=0
    for item in items:
        path=safe_member_name(item['source_file']);data=read_bounded(assets/path,16*1024*1024);total+=len(data)
        if total>128*1024*1024 or digest(data)!=item['sha256']:raise ProbeError('subp_corpus_size_or_identity')
        found=inspect_document(data,path);doc=found['doc']
        compared+=found['command_records_compared']
        prefixes+=found['prefixes'];regions+=found['regions'];variants+=found['variants'];changes+=found['changes'];counts.update(found['calls'])
        for token,count in found['arities'].items():arities[token].update(count)
        errors += [dict(source_file=path,status='unsupported',**e) for e in doc['errors']]
        files.append(dict(source_file=path,old_status=found['old_status'],native_grouping_status=doc['status'],changed_records=len(found['changes'])))
        if len(prefixes)>512 or len(regions)>10000 or len(changes)>10000 or len(variants)>10000:raise ProbeError('subp_global_relation_limit')
    edges,receivers=link_prefixes(prefixes,regions)
    report=dict(schema_version=1,status='inferred',dataset='real',source_file=rel,source_sha256=sha,
        scope='Selected native structure, versioned field-boundary audit and lexical prefix/label links; no script execution',
        native_report=native_path.relative_to(ROOT).as_posix(),native_report_sha256=digest(native_bytes),
        structures=structures(Image(program),plan),field_model='native_grouping',
        field_boundary_audit=dict(status='unsupported' if errors else 'verified',scope='Comparison of source field spans only',
            source_files=len(files),command_records_compared=compared,changed_records=changes,errors=errors,per_file=files,
            native_grouping_execution_equivalence='not_tested',legacy_model='quote_only'),
        field_boundary_coverage_status='unsupported' if errors else 'verified',field_boundary_change_count=len(changes),
        call_variant_counts={t:counts[t] for t in ['sub','subp','subr']},call_arity_counts={t:dict(c) for t,c in arities.items()},
        direct_variant_records=variants,prefix_records=prefixes,prefix_label_edges=edges,receiver_regions=receivers,
        variant_presence_status={t:'verified' if counts[t] else 'not_tested' for t in ['sub','subp','subr']},
        variant_presence_scope='Lexical occurrence only; absence in the retained corpus is not a proof of no runtime use',
        namespace_binding='inferred',namespace_shadowing='not_tested',creation_callback_link='not_tested',
        native_label_target_resolution='not_tested',subp_execution_semantics='not_tested',
        runtime_argument_conversion='not_tested',original_files_written=False,external_game_data_uploads=False,
        runtime_development_ready=False,execution_semantics='not_tested')
    if len(json.dumps(report).encode())>32*1024*1024:raise ProbeError('subp_report_byte_limit')
    write_json(output,report)
    print(json.dumps(dict(status='inferred',field_changes=len(changes),errors=len(errors),variants=report['call_variant_counts'],
        prefix_edges=len(edges),receiver_regions=len(receivers))))
    return 0


if __name__=='__main__':
    try:
        with processing_deadline():code=main()
    except Exception as exc:
        write_json(ROOT/'private/p1-round13/subp-analysis-failure.json',dict(status='unsupported',error_type=type(exc).__name__,reason=str(exc)))
        print(str(exc),file=sys.stderr);code=2
    raise SystemExit(code)
