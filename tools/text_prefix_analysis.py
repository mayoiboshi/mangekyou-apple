#!/usr/bin/env python3
"""Describe bounded prefix literal candidates; never transform or execute scripts."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import sys

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .control_state_analysis import processing_deadline
    from .delphi_metadata import Image,parse_class,parse_record
    from .qlie_lex import lex,digest
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from control_state_analysis import processing_deadline
    from delphi_metadata import Image,parse_class,parse_record
    from qlie_lex import lex,digest


SETTERS={'et':('FExceptText',0x2c),'nt':('FNoWordLineText',0x30)}


def literal_shape(raw):
    """A syntax observation on one quote pair, not expression/string evaluation."""
    if not isinstance(raw,str) or len(raw)>8192:raise ProbeError('prefix_field_size_or_type_limit')
    result=dict(status='not_tested',execution_semantics='not_tested',escaped_string_semantics='not_tested')
    if len(raw)<2 or raw[0]!='"' or raw[-1]!='"' or '"' in raw[1:-1]:
        result['unknown_reason']='Expression is outside the single quote-pair literal classifier; not evaluated'
        return result
    inner=raw[1:-1]
    if any(c in inner for c in ['\0','\r','\n']):
        result.update(status='unsupported',unknown_reason='Literal contains excluded control characters or line breaks')
        return result
    doc=lex(b'\xff\xfe'+inner.encode('utf-16le'),'<literal-prefix>')
    if doc['status']!='verified':
        result.update(status='unsupported',unknown_reason='Nested literal lexical observation failed')
        return result
    commands=Counter();unknown=Counter()
    for record in doc['records']:
        if record['record_type']!='command':continue
        token=record['token'].lower()
        if re.fullmatch(r'[a-z?][a-z0-9?]{0,3}',token):commands[token]+=1
        else:unknown[digest(token.encode('utf-8'))]+=1
    result.update(status='inferred',decoded_form_sha256=digest(inner.encode('utf-8')),
        character_count=len(inner),leading_category=('empty' if not inner else 'backslash' if inner[0]=='\\' else
            'at_sign' if inner[0]=='@' else 'space_or_tab' if inner[0] in ' \t' else 'other'),
        command_token_candidates=dict(commands),virtual_lexical_coverage='verified',
        unknown_command_token_hashes=dict(unknown),
        scope='Only literal shape and lexical command names; source reference remains the parent field')
    if unknown:result.update(status='unsupported',unknown_reason='Literal contains command spelling outside the bounded ASCII metadata classifier')
    return result


def setter_candidate(doc,record,selector,data):
    token=record['token'].lower();field_name,offset=SETTERS[token]
    row=dict(source_file=doc['source_file'],source_sha256=doc['sha256'],command=token,
        byte_offset=record['byte_offset'],byte_length=record['byte_length'],
        raw_bytes_reference=record['raw_bytes_reference'],arity=len(record['operands']),
        status='inferred',native_handler='0x6ba248',candidate_field=field_name,candidate_field_offset=offset,
        native_fact='prefix_setter_'+token,namespace_binding='not_tested',execution_semantics='not_tested',
        selector_sha256=digest(selector.encode('utf-8')) if selector is not None else None,
        selector_interpretation='Same-line lexical observation only, not runtime object resolution')
    if row['arity']!=1:
        row.update(status='unsupported',unknown_reason='Setter spelling has arity outside the reviewed one-argument path')
        return row
    field=record['operands'][0]
    a=field['byte_offset'];b=a+field['byte_length']
    if not record['byte_offset']<=a<=b<=record['byte_offset']+record['byte_length']<=len(data):raise ProbeError('prefix_field_reference_bounds')
    row['parent_field_reference']=dict(byte_offset=a,byte_length=b-a,
        raw_bytes_reference=dict(source_sha256=doc['sha256'],offset=a,length=b-a,sha256=digest(data[a:b])))
    row['literal_shape']=literal_shape(field['raw'])
    if row['literal_shape']['status']=='unsupported':row['status']='unsupported'
    return row


def analyze_documents(assets,items):
    if not 1<=len(items)<=2000:raise ProbeError('prefix_corpus_count_limit')
    rows=[];total=0;counts=Counter();file_rows=[]
    for item in items:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('prefix_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('prefix_corpus_identity')
        doc=lex(data,rel)
        if doc['status']!='verified':raise ProbeError('prefix_lexical_failure')
        line=None;selector=None;found=0
        for record in doc['records']:
            if record['record_type']!='command':continue
            if record['line_number']!=line:line=record['line_number'];selector=None
            token=record['token'].lower()
            if token=='scp':selector=record['operands'][0]['raw'] if record['operands'] else None
            if token not in SETTERS:continue
            rows.append(setter_candidate(doc,record,selector,data));counts[token]+=1;found+=1
            if len(rows)>512:raise ProbeError('prefix_reference_count_limit')
        file_rows.append(dict(source_file=rel,setter_spellings=found,
            record_type_counts=dict(Counter(r['record_type'] for r in doc['records']))))
    return rows,dict(counts),file_rows


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--native-report',type=Path,default=ROOT/'reports/p1/prefix-native-report.json')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/text-prefix-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('prefix_summary_must_be_public_P1')
    for source in [game,assets]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('prefix_input_output_overlap')
    rel=safe_member_name(args.exe);data=read_bounded(game/rel,64*1024*1024);sha=digest(data)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(r['path']==rel and r.get('sha256')==sha for r in inventory['files']):raise ProbeError('prefix_original_identity')
    plan=json.loads(read_bounded(ROOT/'docs/native-prefix-metadata-plan.json'))
    if plan.get('schema_version')!=1 or plan['source_sha256']!=sha:raise ProbeError('prefix_metadata_plan_identity')
    image=Image(data);spec=plan['classes'][0];declaration=parse_class(image,int(spec['vmt'],16),spec['slots'],spec['name'])
    fields={f['name']:f for f in declaration['fields']}
    if any(fields[name]['offset']!=offset for name,offset in SETTERS.values()):raise ProbeError('prefix_field_identity')
    record_spec=plan['records'][0]
    replacement=parse_record(image,int(record_spec['type_info'],16),int(record_spec['fields_count_address'],16),record_spec['name'])
    negative=None
    try:parse_class(image,int(spec['vmt'],16),3,spec['name'])
    except ValueError as exc:
        negative=dict(status='unsupported',scope='Rejected preliminary positive-slot assumption, not a failure of the admitted zero-slot layout',
            attempted_positive_slots=3,reason=str(exc),first_data_reference=image.reference(int(spec['vmt'],16),4))
    if negative is None:raise ProbeError('prefix_wrong_slot_assumption_unexpectedly_accepted')
    native_path=absolute(args.native_report)
    if ROOT/'reports/p1' not in native_path.parents:raise ProbeError('prefix_native_summary_location')
    native_bytes=read_bounded(native_path);native=json.loads(native_bytes)
    if (native.get('source_sha256')!=sha or native.get('status')!='inferred' or native.get('errors')
        or native.get('independent_collection',{}).get('status')!='verified'):raise ProbeError('prefix_native_summary_identity')
    required={'preprocessor_flag_compare_return','replacement_reverse_loop','prefix_setter_et','prefix_setter_nt'}
    observed={o['id'] for o in native['observations'] if o['status']=='verified'}
    if not required<=observed:raise ProbeError('prefix_required_native_observations_missing')
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    rows,counts,files=analyze_documents(assets,corpus['items'])
    literal_commands=Counter()
    for row in rows:literal_commands.update(row.get('literal_shape',{}).get('command_token_candidates',{}))
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='Field declarations, selected native path references and et/nt lexical spelling candidates; no replacement execution or text playback',
        source_file=rel,source_sha256=sha,native_report=native_path.relative_to(ROOT).as_posix(),native_report_sha256=digest(native_bytes),
        class_name=declaration['name'],candidate_fields=[fields[name] for name,_ in SETTERS.values()],
        replacement_record=replacement,rejected_slot_assumption=negative,
        observed_setter_counts=counts,setter_candidates=rows,per_file=files,
        literal_status_counts=dict(Counter(r['literal_shape']['status'] for r in rows if 'literal_shape' in r)),
        literal_command_token_counts=dict(literal_commands),generated_command_semantics='not_tested',
        candidate_status_counts=dict(Counter(r['status'] for r in rows)),
        physical_corpus_files=len(files),all_versions_preserved=True,
        namespace_binding='not_tested',actual_startup_reachability='not_tested',
        native_mode_values=[0,1,2,3,4],replacement_mode_semantics='not_tested',
        replacement_sort_semantics='not_tested',escaped_string_semantics='not_tested',
        text_prefix_configuration='inferred',execution_semantics='not_tested',
        runtime_development_ready=False,original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status='inferred',setters=counts,literal_statuses=report['literal_status_counts'])))
    return 0


if __name__=='__main__':
    try:
        with processing_deadline():code=main()
    except Exception as exc:
        write_json(ROOT/'private/p1-round12/prefix-analysis-failure.json',dict(status='unsupported',error_type=type(exc).__name__,reason=str(exc)))
        print(str(exc),file=sys.stderr);code=2
    raise SystemExit(code)
