#!/usr/bin/env python3
"""Audit lexical replacement-registration candidates; never run regex or scripts."""
import argparse
from collections import Counter
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .control_state_analysis import processing_deadline
    from .qlie_lex import lex,digest
    from .subp_analysis import proof,field_ref
    from .delphi_metadata import Image
    from .object_callback_probe import relative_call
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from control_state_analysis import processing_deadline
    from qlie_lex import lex,digest
    from subp_analysis import proof,field_ref
    from delphi_metadata import Image
    from object_callback_probe import relative_call


def native_bytes(image,plan):
    constants=plan['constants'];cases=plan['cases']
    if len(constants)!=5 or len(cases)!=5 or [c['mode'] for c in cases]!=list(range(5)):
        raise ProbeError('replacement_native_probe_count')
    values=[]
    for row in constants:
        at=int(row['address'],16);value=image.number(at,'B')
        if value!=row['value']:raise ProbeError('replacement_constant_changed')
        values.append(dict(id=row['id'],value_u8=value,status='verified',raw_bytes_reference=image.reference(at,1)))
    guard=int(plan['guard'],16);table=int(plan['table'],16);raw=image.read(guard,16)
    if raw[:5]!=b'\x83\xf8\x04\x0f\x87' or raw[9:12]!=b'\xff\x24\x85' or struct.unpack_from('<I',raw,12)[0]!=table:
        raise ProbeError('replacement_dispatch_guard')
    routes=[]
    for row in cases:
        target=image.u32(table+4*row['mode']);call=int(row['call'],16)
        if target!=int(row['case'],16) or not table+20<=target<=call<target+128:
            raise ProbeError('replacement_case_target')
        routes.append(dict(mode=row['mode'],case_address=hex(target),
            table_entry_reference=image.reference(table+4*row['mode'],4),
            **relative_call(image,call,int(row['helper'],16))))
    return dict(status='verified',scope='Pinned byte constants, dispatch guard and direct helper calls only',
        constants=values,routes=routes,guard_reference=image.reference(guard,16),
        option_names='not_tested',complete_regex_semantics='not_tested')


def string_shape(text):
    if len(text)>8192:return dict(status='unsupported',shape='over_limit',unknown_reason='replacement_field_character_limit')
    if text=='':return dict(status='inferred',shape='raw_empty',runtime_value='not_tested')
    if len(text)<2 or not text.startswith('"') or not text.endswith('"') or text.count('"')!=2:
        return dict(status='not_tested',shape='expression_or_complex_quotes',unknown_reason='No literal evaluation performed')
    inner=text[1:-1]
    return dict(status='inferred',shape='simple_quoted_empty' if not inner else 'simple_quoted_nonempty',
        utf16_code_units=len(inner.encode('utf-16le'))//2,ascii_only=inner.isascii(),
        special_character_counts={c:inner.count(c) for c in '.^$*+?{}[]\\|()' if c in inner},
        escape_interpretation='not_tested',regex_validity='not_tested',runtime_value='not_tested')


def mode_shape(text):
    if len(text)>8192:return dict(status='unsupported',shape='over_limit',unknown_reason='replacement_field_character_limit'),None
    if len(text)==1 and text in '01234':
        return dict(status='inferred',shape='single_decimal_in_reviewed_range',actual_evaluated_mode='not_tested'),int(text)
    return dict(status='not_tested',shape='absent_or_other_expression',actual_evaluated_mode='not_tested',
        unknown_reason='Only exact one-character decimal spelling is classified; no evaluation or coercion'),None


def inspect_document(data,filename):
    doc=lex(data,filename,field_model='native_grouping')
    if doc['status']!='verified':raise ProbeError('replacement_lexical_failure')
    rows=[];counts=Counter();region_hint=None;line_hint=None;line=None
    for record in doc['records']:
        if record['record_type']=='label':region_hint=None;line_hint=None
        if record['record_type']!='command':continue
        if line!=record['line_number']:line=record['line_number'];line_hint=None
        token=record['token'].lower();fields=record['operands']
        if token=='scp':
            text=fields[0]['raw'] if fields else None
            line_hint=region_hint=dict(reference=proof(doc,record),matches_builtin_rep_literal=text in {'rep','"rep"'},
                actual_namespace_binding='not_tested')
        if token!='a':continue
        if len(rows)>=10000:raise ProbeError('replacement_document_candidate_limit')
        row=dict(**proof(doc,record),command='a',lexical_arity=len(fields),status='inferred',
            same_line_selector_hint=line_hint,nearest_region_selector_hint=region_hint,namespace_binding='not_tested',
            actual_registration='not_tested',field_model='native_grouping')
        if len(fields) not in {2,3}:
            row.update(status='unsupported',unknown_reason='Candidate outside two lexical text fields and an optional mode field')
        else:
            mode,number=(mode_shape(fields[2]['raw']) if len(fields)==3 else
                (dict(status='not_tested',shape='omitted',actual_evaluated_mode='not_tested',
                    unknown_reason='Runtime handling of an omitted third field is not recovered'),None))
            row.update(pattern_shape=string_shape(fields[0]['raw']),replacement_shape=string_shape(fields[1]['raw']),
                mode_shape=mode,field_references=[field_ref(doc,f,data) for f in fields])
            if number is not None:counts[str(number)]+=1
            if any(row[k]['status']=='unsupported' for k in ['pattern_shape','replacement_shape','mode_shape']):
                row.update(status='unsupported',unknown_reason='One or more fields exceed admitted shape limits')
        rows.append(row)
    return doc,rows,counts


def analyze_documents(assets,items):
    if not 1<=len(items)<=2000:raise ProbeError('replacement_corpus_count_limit')
    rows=[];counts=Counter();files=[];total=0;seen=set()
    for item in items:
        relative=safe_member_name(item['source_file'])
        if relative in seen:raise ProbeError('replacement_duplicate_corpus_source')
        seen.add(relative);data=read_bounded(assets/relative,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('replacement_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('replacement_corpus_identity')
        doc,found,modes=inspect_document(data,relative);counts.update(modes);rows.extend(found)
        if len(rows)>10000:raise ProbeError('replacement_corpus_candidate_limit')
        files.append(dict(source_file=relative,source_sha256=doc['sha256'],candidate_count=len(found)))
    return rows,dict(counts),files


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',required=True,type=Path)
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/replacement-audit-report.json')
    args=p.parse_args();assets=absolute(args.assets_dir);output=absolute(args.output);game=absolute(args.game_dir)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('replacement_summary_must_be_public_P1')
    for source in [assets,game]:
        if source==output or source in output.parents or output in source.parents:raise ProbeError('replacement_input_output_overlap')
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    native=read_bounded(ROOT/'reports/p1/replacement-native-report.json');review=json.loads(native)
    if review.get('status')!='inferred' or review.get('errors') or review.get('independent_collection',{}).get('status')!='verified':
        raise ProbeError('replacement_native_review_not_verified')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    plan=json.loads(read_bounded(ROOT/'docs/replacement-byte-plan.json'))
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if plan.get('schema_version')!=1 or sha!=plan.get('source_sha256') or sha!=review.get('source_sha256') or not any(
        f['path']==relative and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('replacement_native_source_identity')
    byte_checks=native_bytes(Image(program),plan)
    with processing_deadline(120):rows,modes,files=analyze_documents(assets,corpus['items'])
    report=dict(schema_version=1,status='inferred',dataset='real',
        scope='Lexical a spellings and redacted field shapes only; mode counts do not prove executed registrations',
        native_report='reports/p1/replacement-native-report.json',native_report_sha256=digest(native),
        source_file=relative,source_sha256=sha,native_byte_checks=byte_checks,
        physical_corpus_files=len(files),all_versions_preserved=True,candidates=rows,per_file=files,
        candidate_count=len(rows),candidate_status_counts=dict(Counter(r['status'] for r in rows)),
        mode_shape_counts=dict(Counter(r['mode_shape']['shape'] for r in rows if 'mode_shape' in r)),
        mode_literal_counts=modes,same_line_rep_hints=sum(bool(r['same_line_selector_hint'] and r['same_line_selector_hint']['matches_builtin_rep_literal']) for r in rows),
        namespace_binding='not_tested',replacement_execution='not_tested',regex_engine_compatibility='not_tested',
        original_files_written=False,external_game_data_uploads=False,runtime_development_ready=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],files=len(files),candidates=len(rows),mode_literal_counts=modes)))
    return 0


if __name__=='__main__':
    try:raise SystemExit(main())
    except Exception as exc:
        write_json(ROOT/'private/p1-round15/replacement-audit-failure.json',dict(status='unsupported',error=str(exc),
            scope='Failed audit; no partial candidates promoted'))
        raise
