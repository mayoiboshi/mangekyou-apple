#!/usr/bin/env python3
"""Summarize static storage contracts and explicit decompiler coverage gaps."""
import argparse
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .rea_static import validate_plan,checked_evidence
    from .native_summary import evaluate_fact
    from .scalar_analysis import byte_reference
    from .pe_probe import pe32
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from rea_static import validate_plan,checked_evidence
    from native_summary import evaluate_fact
    from scalar_analysis import byte_reference
    from pe_probe import pe32


def spec(key,evidence,start,end,observation,anchors):
    return dict(id=key,status='verified',evidence=evidence,start=hex(start),end=hex(end),observation=observation,
        scope='仅列出的静态机器指令，不是原程序执行结果',anchors=anchors,unknown=['执行路径和完整状态契约未验证'])


FACTS=[
    spec('assignment_requires_unresolved_target','assign-assembly',0x69b272,0x69b2bd,
        '赋值帮助函数要求目标字段非零、tag 为 3，拒绝双引号开头；数字首字符路径另调用不同的转换帮助函数。',
        ['0x69b272: CMP dword ptr [EDI + 0x8], 0x0','0x69b278: CMP byte ptr [EDI], 0x3',
         '0x69b283: CMP AX, 0x22','0x69b2ae: CALL 0x00415b0c','0x69b2b3: CMP EDX, 0x1','0x69b2b8: CMP EAX, 0x0']),
    spec('assignment_success_pushes_numeric_one','expression-core-assembly',0x69c2ef,0x69c33d,
        '此赋值路径先解析一个操作数，再调用赋值帮助函数；成功后构造 tag 0、数值 1 的描述符并压回表达式栈。',
        ['0x69c2f8: CALL 0x0069af88','0x69c30a: CALL 0x0069b260','0x69c30f: TEST AL, AL',
         '0x69c317: MOV byte ptr [EBP + -0x10], 0x0','0x69c31b: MOV dword ptr [EBP + -0xc], 0x1',
         '0x69c331: CALL 0x0069a4a8']),
    spec('lookup_order_category_3_2_1','name-lookup-assembly',0x69f422,0x69f478,
        '依次查询上下文、类别 2 存储、类别 1 存储；每层用 -1 判断未找到，并分别写出类别 3、2、1。',
        ['0x69f422: CALL 0x006a0520','0x69f427: CMP EAX, -0x1','0x69f42c: MOV byte ptr [ESI], 0x3',
         '0x69f43a: CALL 0x0069f278','0x69f44e: MOV byte ptr [ESI], 0x2',
         '0x69f45c: CALL 0x0069f3a0','0x69f470: MOV byte ptr [ESI], 0x1']),
    spec('read_permission_bit','store-read-assembly',0x69f4f8,0x69f504,
        '读取路径在未请求旁路时检查对象 +0x2c 的位 1。',
        ['0x69f4f8: CMP byte ptr [EBP + 0x8], 0x0','0x69f4fe: TEST byte ptr [ESI + 0x2c], 0x1']),
    spec('write_permission_bit','store-write-assembly',0x69f765,0x69f771,
        '写入路径在未请求旁路时检查对象 +0x2c 的位 2。',
        ['0x69f765: CMP byte ptr [EBP + 0x8], 0x0','0x69f76b: TEST byte ptr [EBX + 0x2c], 0x2']),
    spec('write_copies_then_selects_declared_tag','store-write-assembly',0x69f79d,0x69f7bd,
        '写入前复制描述符，并以目标对象 +0x10 的字节替换其 tag；不能据此假定宿主语言的默认转换。',
        ['0x69f7a9: CALL 0x0040852c','0x69f7b1: MOVZX EAX, byte ptr [EDI + 0x10]',
         '0x69f7b5: CMP AL, byte ptr [EBP + -0xc]','0x69f7ba: MOV byte ptr [EBP + -0xc], AL']),
    spec('index_list_clamps_to_four_and_visits_reverse','index-evaluate-assembly',0x69fa67,0x69fae1,
        '此下标路径按逗号拆分，数量上限为 4，按 count-1-i 取项并逐项调用表达式核心。',
        ['0x69fa69: MOV DX, 0x2c','0x69fa83: CMP dword ptr [EBP + -0x18], 0x4',
         '0x69fa89: MOV dword ptr [EBP + -0x18], 0x4','0x69fab3: DEC EDX',
         '0x69fab4: SUB EDX, dword ptr [EBP + -0x14]','0x69face: CALL 0x0069bab4']),
    spec('flatten_uses_three_stored_strides','element-index-assembly',0x69dd33,0x69dd4d,
        '线性下标以 32 位乘加组合基值与对象 +0x34、+0x38、+0x3c 三个步长；维度顺序名称尚未确认。',
        ['0x69dd33: IMUL ECX, dword ptr [EAX + 0x34]','0x69dd3c: IMUL ECX, dword ptr [EAX + 0x38]',
         '0x69dd45: IMUL ECX, dword ptr [EAX + 0x3c]','0x69dd4b: MOV EAX, EDX']),
    spec('element_read_linear_bounds_and_virtual_slot','element-read-assembly',0x69dd06,0x69dd23,
        '读取元素先要求线性结果非负且小于对象 +0x14，再经虚表 +8 调用。',
        ['0x69dd06: CALL 0x0069dd30','0x69dd0d: JL 0x0069dd23',
         '0x69dd0f: CMP EAX, dword ptr [ESI + 0x14]','0x69dd1d: CALL dword ptr [EBX + 0x8]']),
    spec('element_write_linear_bounds_and_virtual_slot','element-write-assembly',0x69deba,0x69ded7,
        '写入元素使用同一线性计算和总长度边界，再经虚表 +0xc 调用。',
        ['0x69deba: CALL 0x0069dd30','0x69dec1: JL 0x0069ded7',
         '0x69dec3: CMP EAX, dword ptr [ESI + 0x14]','0x69ded1: CALL dword ptr [EBX + 0xc]'])]

TAILS=[('read-tail',0x69f5dd,bytes.fromhex('0fb645fb')),
       ('write-tail',0x69f83a,bytes.fromhex('0fb645ef')),
       ('assign-store-tail',0x69d579,bytes.fromhex('0fb645db')),
       ('name-search-tail',0x69e553,bytes.fromhex('8b45ec'))]


def unknown_instructions(text):
    return [hex(int(m.group(1),16)) for m in re.finditer(r'^\s*([0-9a-fA-F]+):[^\n]*<unknown>',text,re.M)]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--native-dir',type=Path,default=ROOT/'private/p1-round7/native-reproduced')
    p.add_argument('--windows-dir',type=Path,default=ROOT/'private/p1-round7/windows')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/native-variable-report.json')
    args=p.parse_args();game=absolute(args.game_dir);native=absolute(args.native_dir);windows=absolute(args.windows_dir);output=absolute(args.output)
    for path in [native,windows]:
        if ROOT/'private' not in path.parents:raise ProbeError('variable_native_details_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('variable_summary_must_be_public_P1')
    for path in [native,windows,output]:
        if path==game or game in path.parents or path in game.parents:raise ProbeError('variable_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(program).hexdigest();pe=pe32(program)
    plan=json.loads(read_bounded(ROOT/'docs/native-variable-plan.json'));queries=validate_plan(plan)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if sha!=plan['source_sha256'] or not any(f['path']==relative and f.get('sha256')==sha for f in inventory['files']):
        raise ProbeError('variable_source_identity_mismatch')
    summaries=[];records={};facts=[]
    for q in queries:
        record=json.loads(read_bounded(native/(q['name']+'.json'),16*1024*1024))
        summary=checked_evidence(record,sha,q['operation'],q['address']);summary.update(name=q['name'],address=q['address'])
        summaries.append(summary);records[q['name']]=record
    for definition in FACTS:
        fact=evaluate_fact(definition,records[definition['evidence']],relative,sha)
        fact['raw_bytes_reference']=byte_reference(program,pe,int(definition['start'],16),int(definition['end'],16))
        facts.append(fact)
    window_report=json.loads(read_bounded(windows/'window-report.json'));window_rows=[]
    if window_report['source_sha256']!=sha or window_report['source_sha256_after']!=sha or window_report['status']!='verified':
        raise ProbeError('variable_window_collection_invalid')
    expected_windows=json.loads(read_bounded(ROOT/'docs/native-variable-windows.json'))
    if expected_windows['source_sha256']!=sha or len(window_report['windows'])!=len(expected_windows['windows']):
        raise ProbeError('variable_window_plan_mismatch')
    by_name={}
    for row,expected in zip(window_report['windows'],expected_windows['windows']):
        record=json.loads(read_bounded(windows/(safe_member_name(expected['name'])+'.json')))
        if record['name']!=expected['name'] or record['address_range']!={k:expected[k] for k in ['start','end_exclusive']}:
            raise ProbeError('variable_window_selector_mismatch')
        ref=byte_reference(program,pe,int(expected['start'],16),int(expected['end_exclusive'],16))
        old=record['raw_bytes_reference']
        if record['source_sha256']!=sha or any(old[k]!=ref[k] for k in ['offset','length','sha256']):
            raise ProbeError('variable_window_source_mismatch')
        by_name[expected['name']]=record;unknowns=unknown_instructions(record['normalized_result'])
        window_rows.append(dict(name=expected['name'],evidence_id=record['evidence_id'],address_range=record['address_range'],
            boundary_status='inferred',decode_coverage_status='unsupported' if unknowns else 'verified',unknown_instruction_addresses=unknowns))
    for name,address,pattern in TAILS:
        ref=byte_reference(program,pe,address,address+len(pattern));data=program[ref['offset']:ref['offset']+len(pattern)]
        if data!=pattern:raise ProbeError('variable_tail_instruction_mismatch')
        if not re.search(r'^\s*'+format(address,'x')+r':',by_name[name]['normalized_result'],re.M):
            raise ProbeError('variable_tail_address_missing')
        facts.append(dict(id=name+'_return_load',status='verified',scope='Tail instruction bytes and independent linear observation only',
            evidence_id=by_name[name]['evidence_id'],source_file=relative,source_sha256=sha,raw_bytes_reference=ref,
            observation='清理后尾部将栈中字段装入 EAX；Ghidra 基线未覆盖这个续接，不能用其 void 结论设计接口。',
            normal_flow_mapping='inferred',execution_semantics='not_tested'))
    collection_path=native/'collection-report.json';collection=dict(status='not_tested')
    if collection_path.exists():
        raw=read_bounded(collection_path);c=json.loads(raw)
        if (c['status']!='verified' or c['cleanup']!='verified' or c['errors'] or c['source_sha256']!=sha
            or c['original_sha256_after']!=sha or len(c['queries'])!=len(queries)):
            raise ProbeError('variable_independent_collection_incomplete')
        collection=dict(status='verified',source_report=collection_path.relative_to(ROOT).as_posix(),sha256=hashlib.sha256(raw).hexdigest())
    failed=sum(f['status']=='unsupported' for f in facts)
    report=dict(schema_version=1,dataset='real',status='unsupported' if failed else 'inferred',
        scope='Static storage/assignment/index observations and scoped interpretations; no engine or target execution',
        source_file=relative,source_sha256=sha,queries=summaries,machine_facts=facts,failed_facts=failed,
        tail_windows=window_rows,linear_window_coverage_status='unsupported' if any(r['unknown_instruction_addresses'] for r in window_rows) else 'verified',
        window_unknown_reason='Selected windows extend beyond recovered returns; undecodable bytes are retained, not asserted executable',
        independent_collection=collection,
        inferred_contracts=[
            dict(id='scope_search',status='inferred',meaning='Current context, then category 2, then category 1; field getters allow alternate pointers before fallback'),
            dict(id='assignment_result',status='inferred',meaning='Successful assignment yields numeric 1 on this reduction path, rather than propagating the right value'),
            dict(id='typed_storage',status='inferred',meaning='Stored declaration tag selects which cached field the value object consumes; full object and ownership contracts remain unknown'),
            dict(id='index_coordinates',status='inferred',meaning='Up to four reversed items reach stride arithmetic; source coordinate order and per-dimension validation remain unresolved'),
            dict(id='name_normalization',status='inferred',meaning='Lookup can call ASCII A-Z normalization in a UTF-16 branch; Unicode casefold and other encoding branches are not established')],
        unresolved=['Declaration destruction and shadowing lifetimes','Call/return context creation and restore',
            'Name cache invalidation and duplicate definitions','Per-dimension array bounds, rank and overflow behavior',
            'Virtual value implementations and object reference ownership','Error propagation and save serialization'],
        execution_semantics='not_tested',runtime_development_ready=False,original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],queries=len(queries),machine_facts=len(facts),failed_facts=failed,
        linear_unknown_instructions=sum(len(r['unknown_instruction_addresses']) for r in window_rows))))
    return 2 if failed else 0


if __name__=='__main__':raise SystemExit(main())
