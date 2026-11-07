#!/usr/bin/env python3
"""Generate scoped native reviews from explicit plans, never execute targets."""
import argparse
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .native_summary import summarize
    from .call_update_analysis import validate_facts
    from .native_windows import window_reference
    from .pe_probe import pe32
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from native_summary import summarize
    from call_update_analysis import validate_facts
    from native_windows import window_reference
    from pe_probe import pe32


def linear_decode_issues(text,start,end):
    """A decoder may print an instruction crossing --stop-address; retain that gap."""
    unknown=[];outside=[];malformed=[]
    for line in text.splitlines():
        at=re.match(r'^\s*([0-9a-fA-F]+):',line)
        if not at:continue
        address=int(at.group(1),16)
        if '<unknown>' in line:unknown.append(hex(address))
        decoded=re.match(r'^\s*[0-9a-fA-F]+:\s+((?:[0-9a-fA-F]{2}[ \t]+)+)\S',line)
        if not decoded:malformed.append(hex(address));continue
        length=len(decoded.group(1).split())
        if address<start or address+length>end:outside.append(hex(address))
    return dict(unknown_instruction_addresses=unknown,instruction_span_outside_reference=outside,
        malformed_instruction_lines=malformed)


def window_summary(directory,sha,program):
    directory=absolute(directory)
    if ROOT/'private' not in directory.parents:raise ProbeError('native_windows_must_be_private')
    metadata=json.loads(read_bounded(directory/'window-report.json'));rows=metadata['windows'];pe=pe32(program)
    if (metadata['source_sha256']!=sha or metadata['source_sha256_after']!=sha or metadata['errors']
        or not 1<=len(rows)<=16):raise ProbeError('native_window_manifest_mismatch')
    observations=[]
    for row in rows:
        record=json.loads(read_bounded(directory/(safe_member_name(row['name'])+'.json'),2*1024*1024))
        a=int(record['address_range']['start'],16);b=int(record['address_range']['end_exclusive'],16)
        ref=window_reference(pe,a,b)
        if record['source_sha256']!=sha or record['status']!='verified' or any(record['raw_bytes_reference'][k]!=ref[k] for k in ['offset','length']):
            raise ProbeError('native_window_identity_mismatch')
        raw=program[ref['offset']:ref['offset']+ref['length']]
        if hashlib.sha256(raw).hexdigest()!=record['raw_bytes_reference']['sha256']:raise ProbeError('native_window_byte_digest_mismatch')
        issues=linear_decode_issues(record['normalized_result'],a,b)
        observations.append(dict(name=row['name'],evidence_id=record['evidence_id'],raw_bytes_reference=record['raw_bytes_reference'],
            address_range=record['address_range'],boundary_status='inferred',**issues,
            decode_coverage_status='unsupported' if any(issues.values()) else 'verified'))
    return dict(status='unsupported' if any(o['decode_coverage_status']=='unsupported' for o in observations) else 'verified',
        scope='Linear window observations only; decoded trailing bytes are not asserted executable',observations=observations)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--plan',type=Path,required=True);p.add_argument('--facts',type=Path,required=True)
    p.add_argument('--evidence-dir',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--attempts-file',type=Path)
    p.add_argument('--windows-dir',type=Path);p.add_argument('--exploratory-windows-dir',type=Path)
    args=p.parse_args();game=absolute(args.game_dir);native=absolute(args.evidence_dir);output=absolute(args.output)
    if ROOT/'private' not in native.parents:raise ProbeError('native_review_details_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('native_review_summary_must_be_public_P1')
    for path in [native,output]:
        if game==path or game in path.parents or path in game.parents:raise ProbeError('native_review_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(program).hexdigest()
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if not any(r['path']==relative and r.get('sha256')==sha for r in inventory['files']):raise ProbeError('native_review_inventory_identity')
    plan=json.loads(read_bounded(args.plan));definitions=json.loads(read_bounded(args.facts));specs=validate_facts(definitions,plan)
    report=summarize(native,plan,fact_specs=specs,program=program)
    raw=read_bounded(native/'collection-report.json');collection=json.loads(raw)
    expected={(q['name'],q['address']) for q in plan['queries']};rows=collection.get('queries',[])
    observed={(q['name'],q['address']) for q in rows if q['status']=='verified'}
    if (collection.get('status')!='verified' or collection.get('cleanup')!='verified' or collection.get('errors')
        or collection.get('source_sha256')!=sha or collection.get('original_sha256_after')!=sha
        or observed!=expected or len(rows)!=len(expected)):
        raise ProbeError('native_review_collection_incomplete')
    contracts=definitions.get('inferred_contracts',[])
    if len(contracts)>64 or any(c.get('status')!='inferred' for c in contracts):raise ProbeError('native_review_contract_status')
    gaps=[dict(name=q['name'],address=q['address'],status='unsupported',reason=(
        'Provider explicitly reported no containing function' if q['operation']=='resolve_containing_procedure' else
        'Provider explicitly reported undecodable coverage'))
        for q in report['queries'] if q.get('observation_support')=='unsupported']
    attempts=[]
    if args.attempts_file:
        path=absolute(args.attempts_file)
        if ROOT/'private' not in path.parents:raise ProbeError('native_review_attempts_must_be_private')
        data=json.loads(read_bounded(path));original=data['failures']
        if len(original)>64:raise ProbeError('native_review_attempt_count_limit')
        for row in original:
            attempts.append({k:row[k] for k in ['name','status','code','reason'] if k in row})
    report.update(status='inferred' if report['status']=='verified' and contracts else report['status'],
        scope=definitions.get('scope',report['scope']),inferred_contracts=contracts,
        default_function_coverage_status=('unsupported' if gaps else 'verified' if any(
            q['operation'] in {'resolve_containing_procedure','inspect_native_instruction'} for q in plan['queries']) else 'not_tested'),
        default_function_lookup_scope='Selected resolve/inspect results only; no completeness claim about underlying function bodies',
        default_body_completeness='not_tested',default_function_gaps=gaps,
        historical_failed_lookups=attempts,execution_semantics='not_tested',
        independent_collection=dict(status='verified',scope='Query observations and cleanup only, not underlying function coverage',
            manifest_sha256=hashlib.sha256(raw).hexdigest()))
    if args.windows_dir:
        report['linear_windows']=window_summary(args.windows_dir,sha,program)
        report['linear_window_coverage_status']=report['linear_windows']['status']
    if args.exploratory_windows_dir:report['exploratory_windows']=window_summary(args.exploratory_windows_dir,sha,program)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],queries=len(report['queries']),facts=len(report['observations']),
        errors=report['errors'],default_function_gaps=len(gaps),historical_failures=len(attempts))))
    return 2 if report['status']=='unsupported' else 0


if __name__=='__main__':raise SystemExit(main())
