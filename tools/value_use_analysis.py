#!/usr/bin/env python3
"""Trace candidate assignment/update positions without resolving or changing values."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .qlie_lex import lex,digest
    from .expression_analysis import COMMANDS,analyze_field,node_count
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from qlie_lex import lex,digest
    from expression_analysis import COMMANDS,analyze_field,node_count


def node_reference(node):
    keys=['source_file','source_sha256','byte_offset','byte_length','raw_bytes_reference']
    return dict(char_start=node['start'],char_end=node['end'],**{k:node[k] for k in keys if k in node})


def target_shape(node):
    original=node;subscripts=[]
    while node['kind']=='index_candidate':
        index=node['children'][1]
        subscripts.append(dict(kind=index['kind'],**node_reference(index)))
        node=node['children'][0]
    result=dict(target_kind=original['kind'],target_reference=node_reference(original),
        nested_index_syntax_count=len(subscripts),subscripts=list(reversed(subscripts)))
    if node['kind']=='identifier_candidate':
        result.update(status='inferred',target_name=node['value'],
            target_name_sha256=hashlib.sha256(node['value'].encode()).hexdigest())
    else:result.update(status='unsupported',unknown_reason='target_shape_has_no_verified_reference_rule')
    return result


def uses(tree):
    """Syntactic roles only. Neither evaluation order nor read/write effects."""
    operations=[];identifiers=[]
    def visit(node,role='value_identifier_candidate',parent=None):
        kind=node['kind']
        if kind=='identifier_candidate':
            identifiers.append(dict(name=node['value'],role=role,confidence='inferred',**node_reference(node)))
            return
        if kind=='binary_candidate' and node['operator']=='=':
            operations.append(dict(operation_kind='assignment_candidate',nested=parent is not None,
                **node_reference(node),**target_shape(node['children'][0])))
            visit(node['children'][0],'assignment_base_candidate',node)
            visit(node['children'][1],'value_identifier_candidate',node)
        elif kind=='postfix_update_candidate':
            operations.append(dict(operation_kind='update_candidate',operator=node['operator'],nested=parent is not None,
                **node_reference(node),**target_shape(node['children'][0])))
            visit(node['children'][0],'update_base_candidate',node)
        elif kind=='index_candidate':
            visit(node['children'][0],role,node)
            visit(node['children'][1],'index_operand_candidate',node)
        else:
            for child in node['children']:visit(child,role,node)
    visit(tree)
    return operations,identifiers


def public_operation(record):
    return {k:v for k,v in record.items() if k!='target_name'}


def checked_phase_profile(value,expected_sha,report_reference):
    required={'tokenizer_increment_call','tokenizer_decrement_call','update_read_add_write','tokenizer_precedes_transform'}
    rows=value.get('observations',[]);by_id={r['id']:r for r in rows}
    if (value.get('status')!='inferred' or value.get('errors')!=0 or value.get('source_sha256')!=expected_sha
        or value.get('execution_semantics')!='not_tested' or len(rows)>64 or len(by_id)!=len(rows)
        or not all(by_id.get(k,{}).get('status')=='verified' for k in required)):
        raise ProbeError('update_phase_evidence_incomplete')
    return dict(status='inferred',scope='Static tokenization-update hypothesis only; values and execution order remain unknown',
        report_reference=report_reference,source_binary_sha256=expected_sha,machine_fact_ids=sorted(required),
        old_value_capture='not_tested',error_rollback='not_tested')


def annotate_phase(operation,profile):
    result=dict(operation)
    if profile and operation['operation_kind']=='update_candidate' and operation['status']=='inferred':
        result.update(phase_hypothesis='tokenization_write_candidate',phase_status='inferred',phase_evidence=profile)
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--private-dir',type=Path,default=ROOT/'private/p1-round7')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/value-use-report.json')
    p.add_argument('--native-contract-report',type=Path)
    args=p.parse_args();assets=absolute(args.assets_dir);private=absolute(args.private_dir);output=absolute(args.output)
    if ROOT/'private' not in private.parents:raise ProbeError('value_use_details_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('value_use_summary_must_be_public_P1')
    for path in [private,output]:
        if path==assets or assets in path.parents or path in assets.parents:raise ProbeError('value_use_input_output_overlap')
    profile=None;phase_counts=Counter();nested_updates=[];phase_examples=[]
    if args.native_contract_report:
        path=absolute(args.native_contract_report)
        if ROOT/'reports/p1' not in path.parents or path==output:raise ProbeError('update_phase_report_path')
        raw=read_bounded(path);value=json.loads(raw)
        if value.get('dataset')!='real':raise ProbeError('update_phase_requires_real_observation_report')
        binary=json.loads(read_bounded(ROOT/'reports/p1/program-probe.json'))
        profile=checked_phase_profile(value,binary['source_sha256'],dict(path=path.relative_to(ROOT).as_posix(),sha256=digest(raw)))
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('value_use_file_limit')
    fields=Counter();operations=Counter();roles=Counter();targets=Counter();by_command=Counter();nested_kinds=Counter();issues=[];examples=[];files=[]
    excluded_commands=Counter();excluded_records=Counter();no_operand_records=[]
    total_bytes=0;nodes=0;total_ops=0;identifier_count=0;nested_count=0
    for item in corpus['items']:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total_bytes+=len(data)
        if total_bytes>128*1024*1024:raise ProbeError('value_use_corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('value_use_source_identity_mismatch')
        doc=lex(data,rel)
        if doc['status']!='verified':raise ProbeError('value_use_source_lexical_failure')
        file_ops=[];file_uses=[];file_issues=[]
        for record in doc['records']:
            if record['record_type']!='command':excluded_records[record['record_type']]+=1;continue
            if record['token'].lower() not in COMMANDS:excluded_commands[record['token'].lower()]+=1;continue
            if not record['operands']:
                no_operand_records.append(dict(source_file=rel,source_sha256=item['sha256'],command=record['token'].lower(),
                    byte_offset=record['byte_offset'],byte_length=record['byte_length'],status='not_tested',
                    reason='No expression operand; no default invented'))
            for i,field in enumerate(record['operands']):
                if sum(fields.values())>=20000:raise ProbeError('value_use_expression_count_limit')
                context=dict(command=record['token'].lower(),operand_index=i,record_byte_offset=record['byte_offset'])
                result=analyze_field(data,field,doc['encoding'],rel,item['sha256'],context);fields[result['status']]+=1
                if not result['ast']:
                    issue={k:v for k,v in result.items() if k not in {'decoded_text','ast'}}
                    file_issues.append(issue);issues.append(issue);continue
                nodes+=node_count(result['ast'])
                if nodes>100000:raise ProbeError('value_use_node_limit')
                ops,refs=uses(result['ast']);total_ops+=len(ops);identifier_count+=len(refs)
                if total_ops>20000 or identifier_count>100000:raise ProbeError('value_use_occurrence_limit')
                for op in ops:
                    op=annotate_phase(op,profile)
                    op.update(context,execution_semantics='not_tested');file_ops.append(op)
                    operations[op['operation_kind']]+=1;targets[(op['operation_kind'],op['target_kind'])]+=1
                    by_command[(context['command'],op['operation_kind'])]+=1;nested_count+=op['nested']
                    if op['nested']:nested_kinds[op['operation_kind']]+=1
                    if 'phase_hypothesis' in op:
                        phase_counts[op['phase_hypothesis']]+=1
                        if len(phase_examples)<20:phase_examples.append(public_operation(op))
                        if op['nested']:nested_updates.append(public_operation(op))
                    if op['status']=='unsupported':issues.append(public_operation(op))
                    if len(examples)<20:examples.append(public_operation(op))
                for ref in refs:
                    ref.update(context,execution_semantics='not_tested');file_uses.append(ref);roles[ref['role']]+=1
        detail=dict(source_file=rel,source_sha256=item['sha256'],scope='Candidate syntax roles, no value resolution or execution',
            operations=file_ops,identifier_uses=file_uses,issues=file_issues)
        if len(json.dumps(detail,ensure_ascii=False).encode())>32*1024*1024:raise ProbeError('value_use_private_report_limit')
        write_json(private/'value-uses'/(rel+'.json'),detail)
        files.append(dict(source_file=rel,operations=len(file_ops),identifier_uses=len(file_uses),issues=len(file_issues)))
    report=dict(schema_version=1,dataset='real',status='inferred',
        scope='All cal/if/for/case fields re-lexed from bounded source copies; syntactic candidate roles only',
        files=len(files),expression_fields=sum(fields.values()),field_status_counts=dict(fields),
        node_count=nodes,operation_counts=dict(operations),
        target_shape_counts=[dict(operation_kind=k,target_kind=t,count=v) for (k,t),v in sorted(targets.items())],
        nested_operation_candidates=nested_count,nested_operation_counts=dict(nested_kinds),identifier_role_counts=dict(roles),
        command_operation_counts=[dict(command=c,operation_kind=k,count=v) for (c,k),v in sorted(by_command.items())],
        issues=issues,issue_count=len(issues),examples=examples,example_limit=20,operation_total=total_ops,
        per_file=files,private_details=(private/'value-uses').relative_to(ROOT).as_posix(),
        excluded_command_counts=dict(excluded_commands),excluded_record_type_counts=dict(excluded_records),
        no_operand_records=no_operand_records,
        phase_profile=profile,phase_annotation_counts=dict(phase_counts),phase_examples=phase_examples,
        nested_update_phase_examples=nested_updates,
        grammar_coverage_status='unsupported' if issues else 'inferred',
        execution_semantics='not_tested',variable_bindings='not_tested',evaluation_order='not_tested',
        nested_index_syntax_is_runtime_rank=False,original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status='inferred',fields=report['expression_fields'],operations=total_ops,
        kinds=dict(operations),issues=len(issues))))
    return 0


if __name__=='__main__':raise SystemExit(main())
