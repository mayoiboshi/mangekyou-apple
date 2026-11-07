#!/usr/bin/env python3
"""Publish metadata observations from local native evidence, never pseudocode."""
import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, write_json
    from .rea_static import checked_evidence, validate_plan
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, write_json
    from rea_static import checked_evidence, validate_plan


# These are reviewed observations tied to explicit evidence, not opcode meanings
# inferred from names. A missing anchor must produce an unsupported observation.
FACTS=[
    dict(id='four_character_command_identifier',status='verified',evidence='command-id-assembly',
        observation='命令编号构造路径限制字符串长度为 5（含前导反斜线），逐个取随后最多四个 UTF-16 单元，以 8 位间隔移位并 OR 入 EBX。',
        scope='所列机器指令；ASCII 命令适用，未知 Unicode 输入不作兼容承诺。',
        anchors=['0x6aa4c8: CMP EAX, 0x5','0x6aa4d2: XOR EBX, EBX',
                 '0x6aa4ee: MOVZX ESI, word ptr [EDI + ESI*0x2 + -0x2]',
                 '0x6aa4f3: SHL ESI, CL','0x6aa4f5: OR EBX, ESI'],
        start='0x6aa4c8',end='0x6aa4f7',unknown=['非 ASCII 单元是否产生编号碰撞','非法命令错误传播']),
    dict(id='variable_category_selectors',status='verified',evidence='dispatch-assembly',
        observation='svar/gvar/var 的比较立即数分别选择 BL=1/2/3。',
        scope='当前 EXE 内匹配的比较和赋值指令；类别数值本身不证明生命周期或存档域。',
        anchors=['0x6b1ab8: CMP dword ptr [EBP + -0x30], 0x72617673','0x6b1ac1: MOV BL, 0x1',
                 '0x6b1ac3: CMP dword ptr [EBP + -0x30], 0x72617667','0x6b1acc: MOV BL, 0x2',
                 '0x6b1ace: CMP dword ptr [EBP + -0x30], 0x726176','0x6b1ad7: MOV BL, 0x3'],
        start='0x6b1ab8',end='0x6b1ad9',unknown=['作用域规则','遮蔽','存档持久性']),
    dict(id='distinct_variable_storage_paths',status='verified',evidence='variable-create-assembly',
        observation='类别选择段包含三个不同路径：调用 0x69f3a0、调用 0x69f278、从对象 +0x18 取指针后调用 0x6a01bc。',
        scope='分派路径静态存在；尚未恢复被调对象的完整类型、所有权和序列化。',
        anchors=['0x69d0bf: MOVZX EAX, byte ptr [EBP + 0x10]',
                 '0x69d101: CALL 0x0069f3a0','0x69d138: CALL 0x0069f278',
                 '0x69d16f: MOV EAX, dword ptr [EBX + 0x18]','0x69d178: CALL 0x006a01bc'],
        start='0x69d0bf',end='0x69d17d',unknown=['对象字段业务名称','引用共享及销毁时点']),
    dict(id='if_for_context_state_writes',status='verified',evidence='control-assembly',
        observation='控制分派函数的两条路径在调用 0x6c149c 后，分别将对象 +0x34 字节写为 7 和 5。',
        scope='机器指令状态写入；将这些状态称为循环/跳过态仍需完整转移证据。',
        anchors=['0x6bb19a: CALL 0x006c149c','0x6bb1a1: MOV byte ptr [EBX + 0x34], 0x7',
                 '0x6bb3a6: CALL 0x006c149c','0x6bb3ad: MOV byte ptr [EBX + 0x34], 0x5'],
        start='0x6bb19a',end='0x6bb3b1',unknown=['所有上下文状态编号含义','异常退出和跨文件恢复']),
    dict(id='ascii_case_normalization_candidate',status='inferred',evidence='string-normalize',
        observation='Ghidra 对 0x41493c 的表示包含 A-Z 范围检查与 OR 0x20；命令编号调用该函数。',
        scope='反编译表示与调用关系；尚未独立采集该函数汇编，非宽字符串分支未恢复。',
        anchors=['0x41','0x1a','uVar1 = uVar1 | 0x20;'],
        unknown=['非 UTF-16 分支','完整路径和变量名的大小写规则']),
    dict(id='ret_argument_has_distinct_lookup_path',status='inferred',evidence='secondary-dispatch',
        observation='ret 候选分支中，无参数候选路径调用 0x6c1ac8，有参数候选路径调用 0x6c12e0；不能先假定参数是返回值。',
        scope='Ghidra 表示，受寄存器调用约定和类型恢复误差限制；脚本中两条对应记录已可定位。',
        anchors=['WORD_00746572','FUN_006c1ac8','FUN_006c12e0'],
        unknown=['参数查找含义','返回寄存器及展开规则']),
]


def evaluate_fact(spec,record,relative,sha):
    text=record.get('normalized_result','');lines=text.splitlines()
    missing=[a for a in spec['anchors'] if a not in text]
    positions=[text.find(a) for a in spec['anchors']]
    ordered=not spec.get('require_anchor_order') or (not missing and all(a<b for a,b in zip(positions,positions[1:])))
    result={k:v for k,v in spec.items() if k not in {'anchors','start','end','evidence'}}
    result.update(status='unsupported' if missing or not ordered else spec['status'],source_file=relative,source_sha256=sha,
        evidence_id=record.get('evidence_id'),evidence_name=spec['evidence'],
        matched_line_numbers=[i+1 for i,l in enumerate(lines) if any(a in l for a in spec['anchors'])],
        missing_anchor_count=len(missing),execution_semantics='not_tested')
    if spec.get('require_anchor_order'):result['anchor_order_status']='verified' if ordered else 'unsupported'
    if 'start' in spec:result['address_range']={'start':spec['start'],'end_exclusive':spec['end']}
    return result


def summarize(evidence_dir,plan,fact_specs=None,program=None):
    queries=validate_plan(plan);identity=json.loads(read_bounded(ROOT/'reports/p1/program-probe.json'))
    sha=identity['source_sha256']
    if sha!=plan['source_sha256']:raise ProbeError('native_plan_identity_mismatch')
    if program is not None and hashlib.sha256(program).hexdigest()!=sha:raise ProbeError('native_program_identity_mismatch')
    records={};results=[]
    for q in queries:
        name=q['name'];path=evidence_dir/(name+'.json')
        try:
            record=json.loads(read_bounded(path,16*1024*1024))
            item=checked_evidence(record,sha,q['operation'],q['address']);item.update(name=name,address=q['address'])
            records[name]=record
        except (OSError,ValueError,KeyError) as exc:
            item=dict(name=name,status='unsupported',error=str(exc))
        results.append(item)
    facts=[]
    for spec in FACTS if fact_specs is None else fact_specs:
        record=records.get(spec['evidence'],{})
        fact=evaluate_fact(spec,record,identity['source_file'],sha)
        if 'address_range' in fact:
            a=int(fact['address_range']['start'],16);b=int(fact['address_range']['end_exclusive'],16)
            matches=[s for s in identity['pe']['sections'] if identity['pe']['image_base']+s['rva']<=a
                     and b<=identity['pe']['image_base']+s['rva']+s['raw_size']]
            if len(matches)!=1:raise ProbeError('native_fact_has_no_unique_file_mapping')
            s=matches[0];fact['raw_bytes_reference']=dict(source_file=identity['source_file'],source_sha256=sha,
                offset=s['raw_offset']+a-identity['pe']['image_base']-s['rva'],length=b-a)
            if program is not None:
                ref=fact['raw_bytes_reference'];raw=program[ref['offset']:ref['offset']+ref['length']]
                if ref['offset']<0 or ref['length']<=0 or len(raw)!=ref['length']:raise ProbeError('native_fact_source_range')
                ref['sha256']=hashlib.sha256(raw).hexdigest()
        facts.append(fact)
    failures=sum(x['status']=='unsupported' for x in results+facts)
    return dict(schema_version=1,dataset='real',status='verified' if failures==0 else 'unsupported',
        scope=str(len(queries))+' 个选定静态函数/汇编观察及有限事实；不代表完整指令语义或游戏兼容',
        source_file=identity['source_file'],source_sha256=sha,queries=results,observations=facts,
        errors=failures,original_authenticity='not_tested',original_program_execution='not_tested',
        runtime_development_ready=False,full_game_compatibility='not_tested',
        raw_evidence_directory=evidence_dir.relative_to(ROOT).as_posix(),
        original_files_written=False,external_game_data_uploads=False,
        limitations=['Ghidra 的 Delphi 寄存器约定、参数类型与返回值恢复不可靠；汇编优先。',
                    '发现函数和路径不能证明原始发行版身份、实际加载优先级或完整行为。',
                    '没有运行原引擎或原生游戏运行时；时序、分支、存档一致性尚未验证。'])


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir',type=Path,default=ROOT/'private/p1-round2/native-reproduced')
    parser.add_argument('--plan',type=Path,default=ROOT/'docs/native-evidence-plan.json')
    args=parser.parse_args();directory=absolute(args.evidence_dir)
    if ROOT/'private' not in directory.parents:raise ProbeError('native_evidence_must_be_private')
    report=summarize(directory,json.loads(read_bounded(args.plan)))
    write_json(ROOT/'reports/p1/native-report.json',report)
    print(json.dumps(dict(status=report['status'],queries=len(report['queries']),errors=report['errors'])))
    return 0 if report['status']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
