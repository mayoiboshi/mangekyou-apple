#!/usr/bin/env python3
"""Trace operator literals and candidate expression trees without evaluating scripts."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .pe_probe import pe32
    from .qlie_lex import digest,lex,decode_spans
    from .qlie_expr import GROUPS,BINDING,ExpressionError,parse,attach_source,public_tree
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from pe_probe import pe32
    from qlie_lex import digest,lex,decode_spans
    from qlie_expr import GROUPS,BINDING,ExpressionError,parse,attach_source,public_tree

COMMANDS={'cal','if','for','case'}


def literal_tag(data,pe,va):
    sections=[s for s in pe['sections'] if pe['image_base']+s['rva']<=va and va+6<=pe['image_base']+s['rva']+s['raw_size']]
    if len(sections)!=1:raise ProbeError('operator_literal_not_uniquely_mapped')
    section=sections[0];offset=section['raw_offset']+va-pe['image_base']-section['rva'];raw=data[offset:offset+6]
    if len(raw)!=6 or raw[4:]!=b'\0\0':raise ProbeError('operator_literal_missing_terminator')
    text=raw[:4].decode('utf-16-le')
    if not re.fullmatch(r'\*[0-9a-z]',text):raise ProbeError('operator_literal_unrecognized_shape')
    return text,dict(offset=offset,length=6,sha256=digest(raw))


def analyze_field(data,field,codec,source_file,source_sha,context):
    a=field['byte_offset'];n=field['byte_length'];raw=data[a:a+n]
    if a<0 or n<0 or a+n>len(data):raise ProbeError('expression_field_outside_source')
    text,spans=decode_spans(raw,codec,a)
    if text!=field['raw']:raise ProbeError('expression_field_decode_mismatch')
    result=dict(source_file=source_file,source_sha256=source_sha,byte_offset=a,byte_length=n,
        raw_bytes_reference=dict(offset=a,length=n,sha256=digest(raw)),decoded_text=text,**context)
    try:
        tree=attach_source(parse(text),data,spans,source_file,source_sha)
        result.update(status='inferred',ast=tree,execution_semantics='not_tested')
    except ExpressionError as exc:
        pos=spans[exc.offset][0] if exc.offset<len(spans) else a+n
        result.update(status='unsupported',unknown_reason=exc.reason,error_char_offset=exc.offset,error_byte_offset=pos,
            ast=None,execution_semantics='not_tested')
    return result


def node_count(tree):return 1+sum(node_count(c) for c in tree['children'])


def public_expression(record):
    out={k:v for k,v in record.items() if k not in {'decoded_text','ast'}}
    out['ast']=public_tree(record['ast']) if record['ast'] else None
    return out


def audit_sources(corpus,assets,ast_directory):
    counts=dict(files=0,fields=0,trees=0,nodes=0,unsupported=0)
    for item in corpus['items']:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024)
        if digest(data)!=item['sha256']:raise ProbeError('AST_audit_source_identity')
        doc=json.loads(read_bounded(ast_directory/(rel+'.json'),32*1024*1024));counts['files']+=1
        def check(ref):
            a=ref['offset'];b=a+ref['length']
            if not 0<=a<=b<=len(data) or digest(data[a:b])!=ref['sha256']:raise ProbeError('AST_audit_byte_reference')
        def visit(node,parent,text):
            counts['nodes']+=1;check(node['raw_bytes_reference']);a=node['byte_offset'];b=a+node['byte_length']
            if node['source_file']!=rel or node['source_sha256']!=item['sha256']:raise ProbeError('AST_audit_node_identity')
            if not parent[0]<=a<=b<=parent[1]:raise ProbeError('AST_audit_node_containment')
            if data[a:b].decode(item['encoding'])!=text[node['start']:node['end']]:raise ProbeError('AST_audit_character_range')
            if node['confidence']!='inferred' or node['semantic_status']!='not_tested':raise ProbeError('AST_audit_confidence')
            for child in node['children']:visit(child,(a,b),text)
        for record in doc['expressions']:
            counts['fields']+=1;check(record['raw_bytes_reference'])
            if record['ast']:
                counts['trees']+=1;visit(record['ast'],(record['byte_offset'],record['byte_offset']+record['byte_length']),record['decoded_text'])
            else:
                counts['unsupported']+=1
                if not record.get('unknown_reason'):raise ProbeError('AST_audit_missing_failure_reason')
    return dict(status='verified',scope='Byte provenance, decoded character ranges and tree containment only; not expression semantics',counts=counts)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    p.add_argument('--private-dir',type=Path,default=ROOT/'private/p1-round5')
    p.add_argument('--expression-report',type=Path,default=ROOT/'reports/p1/expression-report.json')
    p.add_argument('--operator-report',type=Path,default=ROOT/'reports/p1/operator-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);private=absolute(args.private_dir)
    if ROOT/'private' not in private.parents:raise ProbeError('expression_details_must_be_private')
    expression_output=absolute(args.expression_report);operator_output=absolute(args.operator_report)
    for output in [expression_output,operator_output]:
        if ROOT/'reports/p1' not in output.parents:raise ProbeError('expression_summary_must_be_public_P1')
    if expression_output==operator_output:raise ProbeError('expression_summary_outputs_must_differ')
    for source in [game,assets]:
        if source==private or source in private.parents or private in source.parents:raise ProbeError('expression_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=digest(program)
    plan=json.loads(read_bounded(ROOT/'docs/expression-operator-plan.json'))
    inv=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    old=next((x for x in inv['files'] if x['path']==relative),{})
    if sha!=plan['source_sha256'] or sha!=old.get('sha256'):raise ProbeError('operator_source_identity_mismatch')
    pe=pe32(program);entries=[]
    native=json.loads(read_bounded(ROOT/'private/p1-round3/native-reproduced/expression-tokenize.json'))
    precedence=json.loads(read_bounded(ROOT/'private/p1-round3/native-reproduced/expression-precedence.json'))
    for record in [native,precedence]:
        if record.get('subject',{}).get('digest',{}).get('sha256')!=sha:raise ProbeError('expression_native_evidence_identity_mismatch')
    for entry in plan['entries']:
        tag,ref=literal_tag(program,pe,int(entry['literal_va'],16))
        if tag!=entry['tag']:raise ProbeError('operator_tag_does_not_match_plan')
        pointer='DAT_'+format(int(entry['literal_va'],16),'08x')
        if pointer not in native['normalized_result']:raise ProbeError('operator_literal_reference_missing_from_native_view')
        entries.append(dict(**entry,literal_status='verified',mapping_status='inferred',source_file=relative,source_sha256=sha,
            raw_bytes_reference=ref,operation_semantics='not_tested'))
    if {e['symbol'] for e in entries}!=set(BINDING):raise ProbeError('operator_model_and_evidence_set_mismatch')
    operator_report=dict(schema_version=1,dataset='real',status='inferred',source_file=relative,source_sha256=sha,
        scope='Literal tag bytes verified; symbol mapping and reduction/precedence interpretation remain hypotheses',
        entries=entries,reduction_groups_high_to_low=GROUPS,associativity='Hypothesis: left-to-right within each pass',
        original_evidence='private/p1-round3/native-reproduced/expression-precedence.json',
        flow_model_evidence='reports/p1/expression-flow-report.json',
        tokenizer_evidence_id=native['evidence_id'],precedence_evidence_id=precedence['evidence_id'],
        integer_width_and_coercion='not_tested',logical_short_circuit='not_tested',original_files_written=False)
    write_json(operator_output,operator_report)
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('expression_corpus_count_limit')
    counts=Counter();commands=Counter();reasons=Counter();excluded=Counter();total=0;nodes=0;examples=[];failures=[];files=[];empty=[]
    for item in corpus['items']:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('expression_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('expression_corpus_identity_mismatch')
        doc=lex(data,rel)
        if doc['status']!='verified':raise ProbeError('expression_source_lexical_failure')
        records=[]
        for record in doc['records']:
            if record['record_type']!='command':continue
            token=record['token'].lower()
            if token not in COMMANDS:excluded[token]+=1;continue
            if not record['operands']:
                empty.append(dict(source_file=rel,source_sha256=item['sha256'],command=token,byte_offset=record['byte_offset'],
                    byte_length=record['byte_length'],status='not_tested',reason='No expression field; no default expression invented'))
            for i,field in enumerate(record['operands']):
                if sum(counts.values())>=20000:raise ProbeError('expression_field_count_limit')
                result=analyze_field(data,field,doc['encoding'],rel,item['sha256'],
                    dict(command=token,operand_index=i,record_byte_offset=record['byte_offset']))
                if result['ast']:
                    size=node_count(result['ast'])
                    if nodes+size>100000:
                        result.update(status='unsupported',ast=None,unknown_reason='global_expression_node_budget')
                    else:nodes+=size
                records.append(result);counts[result['status']]+=1;commands[token]+=1
                if result['status']=='unsupported':
                    reasons[result['unknown_reason']]+=1
                    if len(failures)<30:failures.append(public_expression(result))
                elif len(examples)<12:examples.append(public_expression(result))
        write_json(private/'ast'/(rel+'.json'),dict(schema_version=1,source_file=rel,source_sha256=item['sha256'],
            scope='Candidate AST only; strings/values retained privately, never evaluated',expressions=records))
        files.append(dict(source_file=rel,expression_fields=len(records),status_counts=dict(Counter(r['status'] for r in records))))
    report=dict(schema_version=1,dataset='real',status='inferred',
        scope='All operand fields of cal/if/for/case in preserved text variants; candidate trees, no execution',
        files=len(files),expression_fields=sum(counts.values()),node_count=nodes,status_counts=dict(counts),
        grammar_coverage_status='unsupported' if counts['unsupported'] else 'inferred',unknown_reasons=dict(reasons),
        command_field_counts=dict(commands),excluded_command_counts=dict(excluded),empty_expression_records=empty,
        per_file=files,examples=examples,unsupported_examples=failures,private_ast_directory=(private/'ast').relative_to(ROOT).as_posix(),
        operator_evidence=operator_output.relative_to(ROOT).as_posix(),execution_semantics='not_tested',
        limits=dict(field_characters=8192,tokens=1024,tree_depth=64,global_nodes=100000,fields=20000),
        original_files_written=False,external_game_data_uploads=False)
    audit=audit_sources(corpus,assets,private/'ast')
    if audit['counts']['fields']!=report['expression_fields'] or audit['counts']['nodes']!=nodes:
        raise ProbeError('AST_audit_count_mismatch')
    write_json(private/'ast-source-audit.json',audit)
    report['source_reference_audit_status']=audit['status']
    write_json(expression_output,report)
    print(json.dumps(dict(status=report['status'],fields=report['expression_fields'],nodes=nodes,
        counts=report['status_counts'],unknown_reasons=report['unknown_reasons'])))
    return 0


if __name__=='__main__':raise SystemExit(main())
