#!/usr/bin/env python3
"""Publish pinned call/update constraints without executing expressions or targets."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .native_summary import summarize
    from .rea_static import validate_plan
    from .command_ids import identifier_candidate
    from .qlie_lex import lex
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from native_summary import summarize
    from rea_static import validate_plan
    from command_ids import identifier_candidate
    from qlie_lex import lex


def validate_facts(document,plan):
    if document.get('schema_version')!=1 or document.get('source_sha256')!=plan['source_sha256']:
        raise ProbeError('call_fact_plan_identity')
    rows=document.get('facts',[]);queries={q['name']:q for q in validate_plan(plan)};names=set();characters=0
    if not 1<=len(rows)<=64:raise ProbeError('call_fact_count_limit')
    for row in rows:
        if row['id'] in names:raise ProbeError('call_fact_duplicate_id')
        names.add(row['id']);query=queries.get(row['evidence'],{})
        if query.get('operation')!='procedure_assembly' or row['status']!='verified':raise ProbeError('call_fact_requires_instruction_observation')
        a=int(row['start'],16);b=int(row['end'],16)
        if not 0<=a<b<=0x100000000 or b-a>8192:raise ProbeError('call_fact_range_limit')
        if not row.get('require_anchor_order') or not 1<=len(row['anchors'])<=32:raise ProbeError('call_fact_anchor_limit')
        for anchor in row['anchors']:
            characters+=len(anchor);match=re.match(r'^0x([0-9a-f]+): ',anchor)
            if not match or len(anchor)>256 or not a<=int(match.group(1),16)<b:raise ProbeError('call_fact_anchor_outside_reference')
    if characters>65536:raise ProbeError('call_fact_text_limit')
    return rows


def ret_constraint(record):
    if record['token']!='ret':return None
    count=record['arity']
    keys=['source_file','source_sha256','byte_offset','byte_length','record_sha256']
    result={k:record[k] for k in keys}
    result.update(token='ret',arity=count,execution_semantics='not_tested')
    if count in (0,1):
        result.update(status='inferred',argument_role='default_caller_context_candidate' if count==0 else 'context_target_expression_candidate',
            evidence_fact='ret_default_count_minus_two' if count==0 else 'ret_named_context_minus_one',
            return_value_semantics='not_tested')
    else:result.update(status='unsupported',unknown_reason='ret_arity_not_covered_by_reviewed_path')
    return result


def call_slot_shapes(fields):
    """Raw lexical shape only; empty text is not yet a proved nil pointer."""
    arguments=fields[2:];empty=[i for i,f in enumerate(arguments) if f['raw']=='']
    last=max((i for i,f in enumerate(arguments) if f['raw']!=''),default=-1)
    quoted_empty=[i for i,f in enumerate(arguments) if f['raw']=='""']
    return dict(status='inferred',argument_field_count=len(arguments),raw_empty_positions=empty,
        quoted_empty_positions=quoted_empty,sparse_raw_fields=any(i<last for i in empty),
        outside_reviewed_slot_count=max(0,len(arguments)-16),nil_pointer_mapping='not_tested',
        runtime_argument_count='not_tested')


def transfer_constraints(assets,report_path):
    raw=read_bounded(report_path,32*1024*1024);doc=json.loads(raw);rows=doc['transfer_spelling_records']
    if not 1<=len(rows)<=20000:raise ProbeError('transfer_reference_count_limit')
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('transfer_corpus_count_limit')
    expected={x['source_file']:x['sha256'] for x in corpus['items']};cache={};lexical={};total=0;counts=Counter();ret_counts=Counter();samples=[];special=[];unknown=[]
    call_arities=Counter();call_shapes=Counter();call_special=[]
    for row in rows:
        relative=safe_member_name(row['source_file'])
        if relative not in cache:
            data=read_bounded(assets/relative,16*1024*1024);total+=len(data)
            if total>128*1024*1024:raise ProbeError('transfer_corpus_byte_limit')
            if hashlib.sha256(data).hexdigest()!=expected.get(relative):raise ProbeError('transfer_source_identity')
            cache[relative]=data
            fresh=lex(data,relative)
            if fresh['status']!='verified':raise ProbeError('transfer_source_lexical_failure')
            lexical[relative]={(r['byte_offset'],r['byte_length']):r for r in fresh['records'] if r['record_type']=='command'}
        data=cache[relative];a=row['byte_offset'];b=a+row['byte_length']
        if row['source_sha256']!=expected[relative] or not 0<=a<b<=len(data) or hashlib.sha256(data[a:b]).hexdigest()!=row['record_sha256']:
            raise ProbeError('transfer_record_byte_reference')
        actual=lexical[relative].get((a,b-a))
        if actual is None or actual['token'].lower()!=row['token'] or len(actual['operands'])!=row['arity']:
            raise ProbeError('transfer_cached_shape_mismatch')
        if row['token']=='sub':
            shape=call_slot_shapes(actual['operands']);call_arities[str(row['arity'])]+=1
            for key in ['sparse_raw_fields','outside_reviewed_slot_count']:
                if shape[key]:call_shapes[key]+=1
            if shape['quoted_empty_positions']:call_shapes['quoted_empty_fields']+=1
            if any(shape[k] for k in ['sparse_raw_fields','outside_reviewed_slot_count','quoted_empty_positions']):
                call_special.append(dict(**shape,source_file=relative,source_sha256=row['source_sha256'],
                    byte_offset=a,byte_length=b-a,record_sha256=row['record_sha256']))
        counts[row['token']]+=1;constraint=ret_constraint(row)
        if constraint:
            ret_counts[str(row['arity'])]+=1
            if len(samples)<20:samples.append(constraint)
            if row['arity']!=0:special.append(constraint)
            if constraint['status']=='unsupported':unknown.append(constraint)
    return dict(status='inferred',scope='All retained transfer references checked against source bytes; only ret argument roles annotated',
        input_report_sha256=hashlib.sha256(raw).hexdigest(),source_reference_audit='verified',source_files_checked=len(cache),
        transfer_records_checked=len(rows),transfer_counts=dict(counts),ret_arity_counts=dict(ret_counts),
        examples=samples,example_limit=20,nonzero_arity_ret_records=special,unsupported=unknown,
        unannotated_transfer_counts={k:v for k,v in counts.items() if k!='ret'},
        call_parameter_shape_observations=dict(status='inferred',sub_arity_counts=dict(call_arities),
            shape_counts=dict(call_shapes),special_records=call_special,execution_semantics='not_tested'),
        excluded_variant_tokens=['subp','subr'],variant_coverage='not_tested',execution_semantics='not_tested')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--assets-dir',type=Path,required=True)
    p.add_argument('--native-dir',type=Path,default=ROOT/'private/p1-round8/native-reproduced')
    p.add_argument('--transfer-report',type=Path,default=ROOT/'private/p1-round2/contract-report.json')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/call-update-report.json')
    args=p.parse_args();game=absolute(args.game_dir);assets=absolute(args.assets_dir);native=absolute(args.native_dir)
    transfer=absolute(args.transfer_report);output=absolute(args.output)
    for path in [native,transfer]:
        if ROOT/'private' not in path.parents:raise ProbeError('call_raw_evidence_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('call_summary_must_be_public_P1')
    for source in [game,assets]:
        for destination in [native,output]:
            if source==destination or source in destination.parents or destination in source.parents:raise ProbeError('call_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(program).hexdigest()
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(x['path']==relative and x.get('sha256')==sha for x in inventory['files']):raise ProbeError('call_program_inventory_identity')
    plan=json.loads(read_bounded(ROOT/'docs/native-call-update-plan.json'))
    definitions=json.loads(read_bounded(ROOT/'docs/call-update-facts.json'))
    facts=validate_facts(definitions,plan);report=summarize(native,plan,fact_specs=facts,program=program)
    manifest=read_bounded(native/'collection-report.json');collection=json.loads(manifest)
    expected={(q['name'],q['address']) for q in plan['queries']}
    observed={(q['name'],q['address']) for q in collection['queries'] if q['status']=='verified'}
    if (collection['status']!='verified' or collection['cleanup']!='verified' or collection['errors'] or observed!=expected
        or collection['source_sha256']!=sha or collection['original_sha256_after']!=sha):raise ProbeError('call_collection_incomplete')
    report.update(scope='Pinned update-phase and call/return instruction constraints plus inferred corpus roles; no runtime',
        status='inferred' if report['status']=='verified' else 'unsupported',
        independent_collection=dict(status='verified',source_report=(native/'collection-report.json').relative_to(ROOT).as_posix(),
            sha256=hashlib.sha256(manifest).hexdigest()),
        selector_chain=dict(status='inferred',scope='Reviewed SUB/JZ chain at 0x6b7134..0x6b7147',
            initial=hex(0x6b7262),deltas=[hex(0x4fb08),hex(0x3f808)],
            final=hex(0x6b7262+0x4fb08+0x3f808),candidate=identifier_candidate('ret')['identifier_hex']),
        inferred_contracts=[
            dict(id='tokenization_update',status='inferred',meaning='Recognized update sites call read/add/write during tokenization, before later reduction; old-value capture and rollback remain unknown'),
            dict(id='ret_context_target',status='inferred',meaning='The optional ret field selects a context target after string/expression resolution, rather than proving a returned-value slot'),
            dict(id='context_variable_lifetime',status='inferred',meaning='Context depth changes trigger trimming of deeper variable tables; complete object destruction and alias rules remain unknown'),
            dict(id='call_parameter_shape',status='inferred',meaning='Reviewed shared call path handles 16 slots from field 3, retaining holes and recording the highest present slot plus one'),
            dict(id='subr_auxiliary_state',status='inferred',meaning='subr has additional auxiliary-state save/restore; its full ownership and external effects are unresolved')],
        exploratory_findings=[
            dict(query='postfix-expand',status='unsupported',reason='Initial selector 0x69b2e8 explains list expansion, not update timing; actual update helper is 0x69fd90'),
            dict(query='context-push',status='inferred',reason='Selector 0x6c17c8 allocates an auxiliary record; it is not the unresolved virtual frame creation method')],
        corpus_transfer_constraints=transfer_constraints(assets,transfer),
        execution_semantics='not_tested',
        unresolved=['Value capture at nested updates','Short-circuit, syntax failure rollback and update errors',
            'Virtual frame creation and full frame destructor targets','Auxiliary record field semantics and external effects',
            'Call operand conversion, variant arities and parameter lifetime','Full save serialization and event timing'])
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],queries=len(report['queries']),facts=len(report['observations']),errors=report['errors'],
        transfer_refs=report['corpus_transfer_constraints']['transfer_records_checked'])))
    return 0 if report['status']=='inferred' else 2


if __name__=='__main__':raise SystemExit(main())
