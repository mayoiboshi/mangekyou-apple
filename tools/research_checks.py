#!/usr/bin/env python3
"""Run P1 research checks without treating artifact status as a completed port."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json
    from .reproduce_p1_round2 import snapshot_p0,original_hashes,test_counts
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,write_json
    from reproduce_p1_round2 import snapshot_p0,original_hashes,test_counts


def forbidden_content_fields(value):
    forbidden={'pseudocode','decoded_text','raw','raw_result','normalized_result','operands'}
    if isinstance(value,dict):return any(k in forbidden or forbidden_content_fields(v) for k,v in value.items())
    if isinstance(value,list):return any(forbidden_content_fields(v) for v in value)
    return False


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir',type=Path,required=True)
    parser.add_argument('--stage',required=True)
    parser.add_argument('--artifact',type=Path,action='append',required=True)
    args=parser.parse_args()
    if not re.fullmatch(r'round[1-9][0-9]*',args.stage):raise ProbeError('invalid_research_stage_name')
    before=snapshot_p0();private=ROOT/'private'/('p1-'+args.stage);output=ROOT/'reports/p1';artifacts=[]
    for arg in args.artifact:
        p=absolute(arg)
        if output not in p.parents:raise ProbeError('research_artifact_must_be_a_public_P1_report')
        try:
            data=read_bounded(p);value=json.loads(data)
            okay=value.get('status') in {'verified','inferred'} and not forbidden_content_fields(value)
            artifacts.append(dict(path=p.relative_to(ROOT).as_posix(),status='verified' if okay else 'unsupported',
                declared_status=value.get('status'),sha256=hashlib.sha256(data).hexdigest(),scope=value.get('scope'),
                qualifiers={k:value[k] for k in ['grammar_coverage_status','status_counts','unknown_reasons',
                    'experiment_status','decompiler_model_recovery','execution_semantics',
                    'linear_window_coverage_status','field_status_counts','issue_count','phase_annotation_counts',
                    'default_function_coverage_status','metadata_binding_coverage_status','virtual_slot_mismatch_count',
                    'omitted_field_type_count','uninterpreted_method_signatures','uncompared_method_slot_count','native_coverage_status',
                    'unknown_store_count','routine_state_transitions','non_command_line_skip_paths','marker_status_counts',
                    'call_graph_completeness','text_prefix_configuration','all_wait_semantics','preliminary_boundary_coverage_status',
                    'namespace_binding','actual_startup_reachability','replacement_mode_semantics',
                    'replacement_sort_semantics','escaped_string_semantics','generated_command_semantics',
                    'field_model','field_boundary_coverage_status','field_boundary_change_count','namespace_shadowing',
                    'creation_callback_link','native_label_target_resolution','subp_execution_semantics',
                    'runtime_argument_conversion','variant_presence_status','native_xref_completeness',
                    'method_signature','runtime_invocation','default_body_completeness',
                    'replacement_execution','regex_engine_compatibility','mode_shape_counts','candidate_status_counts',
                    'omitted_mode_status','actual_registration','origin_counts','scope_inheritance',
                    'scope_dispatch_contract','registry_lookup_contract','selector_status_counts',
                    'over_declared_arity_candidates','raw_empty_gap_candidates','actual_scope_inheritance',
                    'scope_initialization_contract','scope_return_contract','result_restore_semantics',
                    'full_cleanup_equivalence','site_status_counts','original_engine_equivalence',
                    'real_overlap_equivalence','overlapping_sample_count','sample_count','nonempty_tile_count'] if k in value},
                meaning='Report shape and declared research status only; inferred semantics are not promoted'))
        except (OSError,ValueError) as exc:artifacts.append(dict(path=str(arg),status='unsupported',error=str(exc)))
    suites=[]
    for label,executable in [('default_python','python3'),('research_python',sys.executable)]:
        try:
            result=subprocess.run([executable,'-m','unittest','discover','-s','tests','-v'],cwd=ROOT,capture_output=True,timeout=120)
            text=(result.stdout+result.stderr).decode('utf-8','replace')
            report=test_counts(text,result.returncode);report.update(environment=label,log=text);suites.append(report)
        except (OSError,subprocess.SubprocessError) as exc:suites.append(dict(environment=label,status='unsupported',error=str(exc)))
    try:
        result=subprocess.run([sys.executable,str(ROOT/'tools/verify_upstream.py'),'--output',str(private/'upstream-verification.json')],
            cwd=ROOT,capture_output=True,timeout=120)
        verification=json.loads(read_bounded(private/'upstream-verification.json'))
        upstream=next(x for x in verification['checks'] if x['name']=='upstream_unittest_suite')
        suites.append(dict(environment='upstream',status=verification['status'] if result.returncode==0 else 'unsupported',
            tests_run=upstream['tests_run'],passed=upstream['passed'],skipped=upstream['skipped'],exit_code=result.returncode,
            scope='Synthetic/mocked checks only; unavailable commercial fixture tests are skipped'))
    except (OSError,ValueError,KeyError,StopIteration,subprocess.SubprocessError) as exc:
        suites.append(dict(environment='upstream',status='unsupported',error=str(exc)))
    tests=dict(schema_version=1,dataset='synthetic',status='verified' if all(s['status']=='verified' for s in suites) else 'unsupported',
        suites=suites,skips_are_successes=False)
    write_json(output/(args.stage+'-tests.json'),tests)
    integrity=original_hashes(absolute(args.game_dir));unchanged=before==snapshot_p0()
    okay=all(a['status']=='verified' for a in artifacts) and tests['status']=='verified' and unchanged and integrity['status']=='verified'
    report=dict(schema_version=1,status='verified' if okay else 'unsupported',dataset='real',stage=args.stage,
        scope='Research checks only; not full P1 acceptance, execution equivalence or a completed native port',artifacts=artifacts,
        tests='reports/p1/'+args.stage+'-tests.json',original_integrity=integrity,
        p0_reports_unchanged='verified' if unchanged else 'unsupported',runtime_development_ready=False,
        full_native_port='not_tested',game_execution='not_tested',original_files_written=False,external_game_data_uploads=False)
    write_json(output/(args.stage+'-readiness.json'),report)
    print(json.dumps(dict(status=report['status'],p0_reports_unchanged=unchanged,original_integrity=integrity['status'],runtime_ready=False)))
    return 0 if okay else 2


if __name__=='__main__':raise SystemExit(main())
