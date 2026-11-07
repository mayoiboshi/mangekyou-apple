#!/usr/bin/env python3
"""Compare explicit flow metadata hypotheses in disposable Ghidra projects."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import os
import tempfile
import signal
import re
import copy

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .native_windows import validate_windows
    from .pe_probe import pe32
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from native_windows import validate_windows
    from pe_probe import pe32

FIXTURE=bytes.fromhex('53 bb34120000 680c100000 c3 8bc3 5b c3')
FIXTURE_SHA=hashlib.sha256(FIXTURE).hexdigest()


def bounded_headless(command,env,work):
    process=subprocess.Popen(command,env=env,cwd=work,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    try:
        stdout,stderr=process.communicate(timeout=300)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGTERM)
        try:stdout,stderr=process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid,signal.SIGKILL);stdout,stderr=process.communicate(timeout=10)
        raise ProbeError('headless_timeout; owned process group stopped, no automatic retry')
    return subprocess.CompletedProcess(command,process.returncode,stdout,stderr)


def summary(raw):
    result={k:v for k,v in raw.items() if k!='functions'};functions=[]
    for item in raw['functions']:
        entry={k:v for k,v in item.items() if k not in {'baseline','variant'}}
        for key in ['baseline','variant']:
            observed=item.get(key,{})
            entry[key]={k:v for k,v in observed.items() if k!='pseudocode'}
            if 'pseudocode' in observed:
                text=observed['pseudocode'];entry[key].update(pseudocode_characters=len(text),
                    pseudocode_sha256=hashlib.sha256(text.encode()).hexdigest(),
                    unresolved_jump_markers=text.count('UNRECOVERED_JUMPTABLE'),
                    has_value_return=bool(re.search(r'\breturn\s+[^;\s][^;]*;',text)))
        functions.append(entry)
    result['functions']=functions
    return result


def model_recovery(raw,expected_values=None):
    functions=raw.get('functions',[])
    return 'verified' if functions and all(
        f.get('variant',{}).get('status')=='verified' and
        'UNRECOVERED_JUMPTABLE' not in f['variant'].get('pseudocode','') and
        (expected_values is not None and expected_values.get(f['name']) is False or
         re.search(r'\breturn\s+[^;\s][^;]*;',f['variant'].get('pseudocode','')))
        for f in functions) else 'unsupported'


def validate_result(raw,expected_sha,names):
    if raw.get('source_sha256')!=expected_sha:raise ProbeError('comparison_identity_mismatch')
    if raw.get('program_bytes_patched') is not False or raw.get('target_executed') is not False:
        raise ProbeError('comparison_scope_violation')
    if raw.get('status')!='verified':raise ProbeError('comparison_incomplete')
    if [f['name'] for f in raw.get('functions',[])]!=names:raise ProbeError('comparison_function_set_mismatch')
    for item in raw['functions']:
        if item.get('status')!='verified' or item.get('memory_unchanged') is not True:
            raise ProbeError('comparison_memory_or_function_failure')
        if item.get('source_memory_sha256')!=item.get('memory_sha256_after'):
            raise ProbeError('comparison_memory_digest_mismatch')
        for key in ['baseline','variant']:
            if item.get(key,{}).get('status')!='verified' or not item[key].get('pseudocode','').strip():
                raise ProbeError('comparison_decompiler_failure')


def run_comparison(data,plan,output,ghidra,java,synthetic=False):
    output=absolute(output);ghidra=absolute(ghidra);java=absolute(java)
    if ROOT/'private' not in output.parents:raise ProbeError('tail_probe_output_must_be_private')
    for p in [output]+list(output.parents):
        if p.is_symlink():raise ProbeError('symlink_output_refused')
    output.mkdir(parents=True,exist_ok=True)
    expected=hashlib.sha256(data).hexdigest()
    if expected!=plan['source_sha256']:raise ProbeError('tail_plan_identity_mismatch')
    names=[f['name'] for f in plan['functions']]
    if len(names)!=len(set(names)) or not 1<=len(names)<=16:raise ProbeError('tail_function_count_or_duplicates')
    for spec in plan['functions']:
        safe_member_name(spec['name'])
        for value in spec['cleanup_returns']:
            if not int(spec['start'],16)<=int(value,16)<int(spec['end_exclusive'],16):raise ProbeError('tail_override_outside_function')
    if not synthetic:validate_windows(pe32(data),plan['functions'])
    env=dict(os.environ);env['JAVA_HOME']=str(java)
    raw=None;error=None;exit_code=None;log=''
    with tempfile.TemporaryDirectory(prefix='tail-probe-',dir=output) as tmp:
        work=Path(tmp).resolve();target=work/('target.bin' if synthetic else 'target.exe')
        with target.open('xb') as stream:stream.write(data)
        write_json(work/'plan.json',plan)
        command=[str(ghidra/'support/analyzeHeadless'),str(work),'probe','-import',str(target)]
        if synthetic:command+=['-loader','BinaryLoader','-loader-baseAddr','0x1000','-processor','x86:LE:32:default',
                                '-cspec','borlanddelphi','-noanalysis']
        else:command+=['-analysisTimeoutPerFile','100','-max-cpu','2']
        command+=['-readOnly','-deleteProject','-scriptPath',str(ROOT/'tools/ghidra'),'-postScript','BoundTailProbe.java',
                  str(work/'plan.json'),str(work/'result.json')]
        try:
            p=bounded_headless(command,env,work)
            exit_code=p.returncode
            if len(p.stdout)+len(p.stderr)>8*1024*1024:raise ProbeError('headless_log_limit')
            log=(p.stdout+p.stderr).decode('utf-8','replace')
            if p.returncode:raise ProbeError('headless_exit_failure')
            if 'analysis timed out' in log.lower():raise ProbeError('headless_analysis_timed_out')
            raw=json.loads(read_bounded(work/'result.json',8*1024*1024))
            validate_result(raw,expected,names)
            if synthetic:
                baseline=raw['functions'][0]['baseline']['pseudocode'];variant=raw['functions'][0]['variant']['pseudocode']
                if '0x1234' in baseline or not ('0x1234' in variant or '4660' in variant):
                    raise ProbeError('synthetic_expected_return_not_recovered')
        except (OSError,ValueError,KeyError,subprocess.SubprocessError) as exc:error=str(exc)
        if raw is not None:write_json(output/'comparison.json',raw)
        write_json(output/'headless-log.json',dict(exit_code=exit_code,log=log,error=error))
    expectations={f['name']:f.get('expects_value_return',True) for f in plan['functions']}
    recovery=model_recovery(raw,expectations) if raw is not None else 'unsupported'
    result=summary(raw) if raw is not None else dict(functions=[])
    result.update(schema_version=1,status='unsupported' if error or recovery!='verified' else ('verified' if synthetic else 'inferred'),
        experiment_status='unsupported' if error else 'verified',dataset='synthetic' if synthetic else 'real',
        decompiler_model_recovery=recovery,
        expected_value_returns=expectations,
        error=error,source_sha256=expected,game_execution='not_tested',original_files_written=False,
        target_semantic_equivalence='not_tested',
        script_sha256=hashlib.sha256(read_bounded(ROOT/'tools/ghidra/BoundTailProbe.java')).hexdigest(),
        limitations=['Only selected normal-flow hypotheses in a disposable analysis database',
                    'Real-program overrides are analyst inference, not original execution or unmodified REA output',
                    'Synthetic success does not verify game behavior or arbitrary Delphi exception paths'])
    return result


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--synthetic',action='store_true');p.add_argument('--game-dir',type=Path);p.add_argument('--exe')
    p.add_argument('--ghidra-dir',type=Path,required=True);p.add_argument('--java-home',type=Path,required=True)
    p.add_argument('--plan',type=Path,default=ROOT/'docs/native-tail-probe-plan.json')
    p.add_argument('--private-dir',type=Path,default=ROOT/'private/p1-round4')
    p.add_argument('--public-report',default='tail-probe-report.json')
    args=p.parse_args();output=absolute(args.private_dir);source=None
    if ROOT/'private' not in output.parents:raise ProbeError('tail_probe_output_must_be_private')
    report_name=safe_member_name(args.public_report)
    if '/' in report_name or not report_name.endswith('.json'):raise ProbeError('invalid_public_report_name')
    if args.synthetic and (args.game_dir or args.exe):p.error('synthetic mode cannot also select game inputs')
    if args.synthetic:
        data=FIXTURE;plan=dict(source_sha256=FIXTURE_SHA,functions=[dict(name='synthetic_cleanup',
            start='0x1000',end_exclusive='0x1010',cleanup_returns=['0x100b'],return_targets={'0x100b':'0x100c'})])
    else:
        if not args.game_dir or not args.exe:p.error('real mode requires --game-dir and --exe')
        ready=json.loads(read_bounded(output/'synthetic-summary.json'))
        if ready['experiment_status']!='verified' or ready['source_sha256']!=FIXTURE_SHA:
            raise ProbeError('successful_synthetic_probe_required')
        if ready.get('negative_guard',{}).get('status')!='verified':
            raise ProbeError('negative_continuation_guard_must_pass_first')
        if ready['script_sha256']!=hashlib.sha256(read_bounded(ROOT/'tools/ghidra/BoundTailProbe.java')).hexdigest():
            raise ProbeError('synthetic_probe_was_for_a_different_script')
        game=absolute(args.game_dir)
        if output==game or game in output.parents or output in game.parents:raise ProbeError('input_output_overlap')
        source=game/safe_member_name(args.exe);data=read_bounded(source,64*1024*1024)
        plan=json.loads(read_bounded(args.plan));inv=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
        old=next((f for f in inv['files'] if f['path']==args.exe),{})
        if old.get('sha256')!=hashlib.sha256(data).hexdigest():raise ProbeError('input_not_P0_identity')
    mode='synthetic' if args.synthetic else 'real'
    result=run_comparison(data,plan,output/(mode+'-comparison'),args.ghidra_dir,args.java_home,args.synthetic)
    if args.synthetic and result['experiment_status']=='verified':
        negative=copy.deepcopy(plan)
        negative['functions'][0]['return_targets']['0x100b']='0x100d'
        refused=run_comparison(data,negative,output/'negative-comparison',args.ghidra_dir,args.java_home,True)
        write_json(output/'negative-summary.json',refused)
        good=refused['experiment_status']=='unsupported' and any(
            'no decoded PUSH of continuation' in f.get('error','') for f in refused['functions'])
        result['negative_guard']=dict(status='verified' if good else 'unsupported',
            rejected_variant_status=refused['status'],scope='Wrong continuation target must be refused, not decompiled as a valid model')
        if not good:result.update(status='unsupported',experiment_status='unsupported',error='negative_continuation_guard_failed')
    if source is not None:
        result['source_file']=args.exe
        result['original_sha256_after']=hashlib.sha256(read_bounded(source,64*1024*1024)).hexdigest()
        if result['original_sha256_after']!=result['source_sha256']:
            result.update(status='unsupported',experiment_status='unsupported',error='original_digest_changed')
    write_json(output/(mode+'-summary.json'),result)
    if not args.synthetic:write_json(ROOT/'reports/p1'/report_name,result)
    print(json.dumps(dict(status=result['status'],experiment_status=result['experiment_status'],model_recovery=result['decompiler_model_recovery'],dataset=mode,
        functions=len(result['functions']),error=result['error'])))
    return 0 if result['experiment_status']=='verified' and result['decompiler_model_recovery']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
