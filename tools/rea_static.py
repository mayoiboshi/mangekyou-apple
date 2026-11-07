#!/usr/bin/env python3
"""Collect bounded local REA static evidence; never execute the analysis target."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import time

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, safe_open, write_json
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, safe_open, write_json

MAX_MESSAGE=16*1024*1024
SELECTORS={'procedure_pseudo_code':'procedure','procedure_assembly':'procedure',
           'xrefs':'address','resolve_containing_procedure':'address','inspect_native_instruction':'address'}
ALLOWED={'open_binary','close_binary','export_evidence_bundle'}|set(SELECTORS)


def unpack(result):
    if result.get('isError'):raise ProbeError('REA_tool_error')
    value=result.get('structuredContent')
    if value is None:
        texts=[c['text'] for c in result.get('content',[]) if c.get('type')=='text']
        if len(texts)!=1:raise ProbeError('REA_response_not_one_JSON_record')
        value=json.loads(texts[0])
    if not isinstance(value,dict):raise ProbeError('REA_response_not_object')
    if value.get('error'):raise ProbeError('REA_analysis_error:'+str(value.get('code','unknown')))
    return value


def validate_plan(plan):
    if plan.get('schema_version')!=1:raise ProbeError('unsupported_native_plan')
    queries=plan.get('queries',[])
    if not 1<=len(queries)<=64:raise ProbeError('native_query_count_limit')
    names=set()
    for q in queries:
        if q.get('operation') not in SELECTORS:raise ProbeError('nonstatic_operation')
        name=safe_member_name(q['name'])
        if '/' in name or name in names:raise ProbeError('duplicate_or_nested_query_name')
        names.add(name)
        address=q.get('address','')
        if not address.startswith('0x') or not 0<=int(address,16)<=0xffffffff:raise ProbeError('invalid_PE32_selector')
    return queries


def checked_evidence(record,expected_sha,operation,selector=None):
    if record.get('subject',{}).get('digest',{}).get('sha256')!=expected_sha:
        raise ProbeError('REA_subject_sha256_mismatch')
    if record.get('provider',{}).get('id')!='ghidra':raise ProbeError('REA_provider_mismatch')
    if record.get('operation')!=operation:raise ProbeError('REA_operation_mismatch')
    if operation not in SELECTORS:raise ProbeError('nonstatic_operation')
    if selector is not None and record.get('parameters',{}).get(SELECTORS[operation])!=selector:
        raise ProbeError('REA_selector_mismatch')
    value=record.get('normalized_result')
    if operation in {'procedure_assembly','procedure_pseudo_code'}:
        if not isinstance(value,str) or not value.strip():raise ProbeError('REA_empty_code')
        text=value
    else:
        if operation=='xrefs' and (not isinstance(value,list) or any(not isinstance(v,str) for v in value)):
            raise ProbeError('REA_invalid_reference_list')
        if operation!='xrefs' and not isinstance(value,dict):raise ProbeError('REA_invalid_observation_object')
        text=json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False)
    return dict(status='verified',scope='Provider observation, not recovered source or execution semantics',
        evidence_id=record['evidence_id'],operation=operation,provider=record['provider'],
        profile_digest=record.get('analysis_profile',{}).get('digest'),
        output_sha256=hashlib.sha256(text.encode()).hexdigest(),output_characters=len(text),
        semantics='not_tested',observation_support=(
            'unsupported' if isinstance(value,dict) and (value.get('status')=='undecodable' or value.get('found') is False)
            else 'verified'))


class LocalMCP:
    def __init__(self,command,environment,log):
        directory=safe_open(log.parent,directory=True)
        try:
            fd=os.open(log.name,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600,dir_fd=directory)
        finally:os.close(directory)
        self.log=os.fdopen(fd,'wb');self.buffer=bytearray();self.sequence=0
        try:
            self.proc=subprocess.Popen([str(command),'mcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,
                stderr=self.log,env=environment,cwd=ROOT,start_new_session=True)
        except BaseException:
            self.log.close();raise

    def request(self,method,params,timeout=240):
        self.sequence+=1;rid=self.sequence
        request=dict(jsonrpc='2.0',id=rid,method=method,params=params)
        self.proc.stdin.write(json.dumps(request).encode()+b'\n');self.proc.stdin.flush()
        deadline=time.monotonic()+timeout
        while True:
            if b'\n' in self.buffer:
                line,_,rest=self.buffer.partition(b'\n');self.buffer[:]=rest
                if len(line)>MAX_MESSAGE:raise ProbeError('REA_message_size_limit')
                if not line.strip():continue
                value=json.loads(line)
                if value.get('id')!=rid:continue
                if 'error' in value:raise ProbeError('REA_RPC_error:'+str(value['error'].get('code')))
                return value['result']
            remaining=deadline-time.monotonic()
            if remaining<=0:raise TimeoutError('REA_request_deadline; no automatic retry')
            ready,_,_=select.select([self.proc.stdout],[],[],remaining)
            if not ready:continue
            chunk=os.read(self.proc.stdout.fileno(),65536)
            if not chunk:raise ProbeError('REA_closed_stdout')
            self.buffer.extend(chunk)
            if len(self.buffer)>MAX_MESSAGE:raise ProbeError('REA_message_size_limit')

    def initialize(self):
        info=self.request('initialize',dict(protocolVersion='2025-03-26',capabilities={},
            clientInfo=dict(name='mangekyou-static-research',version='1')),30)
        self.proc.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n');self.proc.stdin.flush()
        tools=self.request('tools/list',{},30)
        available={t['name'] for t in tools['tools']}
        if not ALLOWED<=available:raise ProbeError('REA_static_tools_missing')
        return info.get('serverInfo',{})

    def call(self,name,arguments,timeout=240):
        if name not in ALLOWED:raise ProbeError('nonstatic_operation')
        return self.request('tools/call',dict(name=name,arguments=arguments),timeout)

    def stop(self):
        if self.proc.stdin:self.proc.stdin.close()
        try:self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:self.proc.kill();self.proc.wait(timeout=5)
        self.log.close()


def collect(args):
    output=absolute(args.output);game=absolute(args.game_dir)
    if ROOT/'private' not in output.parents:raise ProbeError('native_evidence_must_be_private')
    if output==game or game in output.parents or output in game.parents:raise ProbeError('input/output_overlap')
    for parent in [output]+list(output.parents):
        if parent.is_symlink():raise ProbeError('symlink_output_refused')
    rea=absolute(args.rea_command)
    if rea==game or game in rea.parents:raise ProbeError('REA_command_cannot_be_game_input')
    output.mkdir(parents=True,exist_ok=True)
    plan=json.loads(read_bounded(args.plan));queries=validate_plan(plan)
    relative=safe_member_name(args.exe);target=game/relative
    data=read_bounded(target,64*1024*1024);sha=hashlib.sha256(data).hexdigest()
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    old=next((f for f in inventory['files'] if f['path']==relative),{})
    if sha!=old.get('sha256') or sha!=plan.get('source_sha256'):raise ProbeError('target_does_not_match_inventory_and_plan')
    env=dict(os.environ)
    if args.java_home:env['JAVA_HOME']=str(absolute(args.java_home))
    if args.ghidra_dir:env['GHIDRA_INSTALL_DIR']=str(absolute(args.ghidra_dir))
    budget=getattr(args,'analysis_budget_seconds',600)
    if not 1<=budget<=3600:raise ProbeError('native_analysis_budget_out_of_range')
    deadline=time.monotonic()+budget
    report=dict(schema_version=1,status='not_tested',source_file=relative,source_sha256=sha,
        scope='Local static REA/Ghidra observation only; target is never launched',
        original_files_written=False,target_execution='not_tested',external_game_data_uploads=False,
        queries=[],errors=[],cleanup='not_tested',analysis_budget_seconds=budget)
    client=None;opened=False;response_bytes=0
    try:
        client=LocalMCP(rea,env,output/'rea-stderr.log')
        report['server']=client.initialize()
        raw=client.call('open_binary',dict(path=str(target),provider_id='ghidra'),30);opened=True
        write_json(output/'open.json',raw)
        observed=unpack(raw)['result']
        if observed.get('sha256')!=sha or observed.get('format')!='pe':raise ProbeError('REA_open_identity_mismatch')
        opened=True
        for q in queries:
            try:
                remaining=deadline-time.monotonic()
                if remaining<=0:raise TimeoutError('native_collection_deadline; no automatic retry')
                raw=client.call(q['operation'],{SELECTORS[q['operation']]:q['address']},min(240,remaining))
                response_bytes+=len(json.dumps(raw).encode())
                if response_bytes>128*1024*1024:raise ProbeError('native_evidence_total_size_limit')
                write_json(output/(q['name']+'.rpc.json'),raw)
                record=unpack(raw);write_json(output/(q['name']+'.json'),record)
                item=checked_evidence(record,sha,q['operation'],q['address']);item.update(name=q['name'],address=q['address'])
            except (OSError,ValueError,KeyError,TimeoutError) as exc:
                item=dict(name=q['name'],address=q['address'],status='unsupported',error=str(exc))
                report['errors'].append(dict(query=q['name'],error=str(exc)))
            report['queries'].append(item)
            write_json(output/'collection-report.json',report)
            print(json.dumps(dict(query=q['name'],status=item['status'])),flush=True)
            if isinstance(item.get('error'),str) and ('deadline' in item['error'] or 'closed_stdout' in item['error']):break
        report['status']='verified' if len(report['queries'])==len(queries) and not report['errors'] else 'unsupported'
    except (OSError,ValueError,KeyError,TimeoutError) as exc:
        report['status']='unsupported';report['errors'].append(dict(stage='collection',error=str(exc)))
    finally:
        if client:
            try:
                if opened:
                    raw=client.call('close_binary',{},30);write_json(output/'close.json',raw);unpack(raw)
                    report['cleanup']='verified'
            except (OSError,ValueError,KeyError,TimeoutError) as exc:
                report['cleanup']='unsupported';report['errors'].append(dict(stage='close',error=str(exc)))
            finally:client.stop()
        report['original_sha256_after']=hashlib.sha256(read_bounded(target,64*1024*1024)).hexdigest()
        if report['original_sha256_after']!=sha or report['cleanup']!='verified':report['status']='unsupported'
        write_json(output/'collection-report.json',report)
    return 0 if report['status']=='verified' else 2


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-dir',type=Path,required=True)
    parser.add_argument('--exe',required=True,help='Relative path; read as bytes, never executed')
    parser.add_argument('--plan',type=Path,default=ROOT/'docs/native-evidence-plan.json')
    parser.add_argument('--output',type=Path,default=ROOT/'private/p1-round2/native-reproduced')
    parser.add_argument('--rea-command',type=Path,default=Path.home()/'.local/bin/rea')
    parser.add_argument('--java-home',type=Path)
    parser.add_argument('--ghidra-dir',type=Path)
    parser.add_argument('--analysis-budget-seconds',type=int,default=600)
    return collect(parser.parse_args())


if __name__=='__main__':raise SystemExit(main())
