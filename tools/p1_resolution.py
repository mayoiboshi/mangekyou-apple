#!/usr/bin/env python3
"""Conditional resource precedence model and additional static evidence facts."""
import argparse
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .native_summary import evaluate_fact
    from .rea_static import checked_evidence, validate_plan
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from native_summary import evaluate_fact
    from rea_static import checked_evidence, validate_plan


FACTS=[
    dict(id='ascii_wide_lowercase_instructions',status='verified',evidence='ascii-lower-assembly',
        observation='宽字符分支对 A-Z 执行 OR 0x20，小写转换有汇编依据。',
        scope='仅限该 UTF-16 分支的 ASCII 范围，不推广至 Unicode 或所有资源名称。',
        anchors=['0x414993: ADD ESI, -0x41','0x414996: SUB SI, 0x1a','0x41499c: OR AX, 0x20'],
        unknown=['非宽字符分支','调用者各自适用的名称规则']),
    dict(id='descending_pack_slots',status='verified',evidence='pack-select-assembly',
        observation='未命中散文件的分支从槽位 31 倒序到 0；同槽位先查 0x715580 表，再查 0x715600 表，命中后离开搜索。',
        scope='当前 EXE 的具体查找路径，尚未证明所有资源调用都进入此路径。',
        anchors=['0x4ec892: MOV EDI, 0x1f','0x4ec897: MOV EBX, 0x7155fc','0x4ec89c: MOV ESI, 0x71567c',
                 '0x4ec8b6: CALL 0x004ea57c','0x4ec8dd: JMP 0x004ec95d','0x4ec8e9: CALL 0x004ea57c',
                 '0x4ec912: DEC EDI','0x4ec913: SUB ESI, 0x4','0x4ec916: SUB EBX, 0x4',
                 '0x4ec919: CMP EDI, -0x1'],unknown=['完整散文件根目录','其他读取接口及缓存行为']),
    dict(id='one_script_reader_uses_unrestricted_slot',status='verified',evidence='script-read-assembly',
        observation='0x695104 中的一条脚本读取路径将 ECX 置为 -1、DL 置为 1，再调用 0x4ec5ac。',
        scope='该调用点的指令；不等于所有脚本装载场景或宏展开已恢复。',
        anchors=['0x69514a: OR ECX, 0xffffffff','0x69514d: MOV DL, 0x1','0x695152: CALL 0x004ec5ac'],
        unknown=['其他脚本入口','文件路径预处理和 include 递归语义']),
    dict(id='ret_candidate_reverse_string_lookup',status='verified',evidence='named-context-assembly',
        observation='0x6c12e0 从末尾向前搜索嵌套容器，取第 0 项的 +4 字段与输入字符串比较，搜索游标保存在 EBX。',
        scope='指令中的搜索与比较路径；字段业务含义及 ret 展开规则仍未确认。',
        anchors=['0x6c1318: DEC EBX','0x6c1339: XOR EDX, EDX','0x6c133b: CALL 0x006c1488',
                 '0x6c1340: MOV EDX, dword ptr [EAX + 0x4]','0x6c1346: CALL 0x00414b08',
                 '0x6c134f: DEC EBX'],unknown=['容器项业务身份','跨文件返回和状态恢复']),
]


def conditional_choice(variants,restricted_slot=None,loose_present=None,secondary_mounts_known=False):
    """A deliberately conditional metadata model, not an engine resource loader."""
    if restricted_slot is not None and not 0<=restricted_slot<32:raise ProbeError('pack_slot_out_of_range')
    candidates=[];unknown=[]
    for variant in variants:
        origin=variant.get('origin',{});archive=origin.get('archive','')
        match=re.fullmatch(r'GameData/data(\d+)\.pack',archive)
        if match is None or not 0<=int(match[1])<32:
            unknown.append(dict(source_file=variant.get('source_file'),reason='archive_to_slot_mapping_unknown'));continue
        candidates.append(dict(source_file=safe_member_name(variant['source_file']),sha256=variant['sha256'],
            archive=archive,archive_sha256=origin['archive_sha256'],index=origin['index'],slot=int(match[1])))
    if restricted_slot is not None:candidates=[c for c in candidates if c['slot']==restricted_slot]
    counts=Counter(c['slot'] for c in candidates)
    if any(n>1 for n in counts.values()):unknown.append(dict(reason='multiple_candidates_in_one_primary_slot'))
    if loose_present:unknown.append(dict(reason='loose_file_branch_requires_separate_resolution'))
    candidates.sort(key=lambda c:(-c['slot'],c['source_file']))
    winner=candidates[0] if candidates and not unknown else None
    return dict(status='inferred' if winner else 'unsupported',conditional_winner=winner,candidates=candidates,
        unknown=unknown,effective_runtime_winner='not_tested',
        preconditions=dict(no_matching_loose_file='verified' if loose_present is False else 'not_tested',
            secondary_mounts='verified' if secondary_mounts_known else 'not_tested',
            mapping='inferred',requested_slot=restricted_slot if restricted_slot is not None else -1),
        note='Conditional winner assumes dataN maps to primary slot N; untested preconditions are never treated as actual runtime facts')


def overlay_model(corpus,changed_paths):
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('corpus_count_limit')
    groups=defaultdict(list)
    for item in corpus['items']:groups[safe_member_name(item['logical_path'])].append(item)
    rows=[]
    for path,variants in sorted(groups.items()):
        row=conditional_choice(variants);row.update(logical_path=path,variant_count=len(variants),
            changed_duplicate=path in changed_paths)
        rows.append(row)
    return dict(schema_version=1,dataset='real',status='inferred',scope='Conditional static corpus view only; no authoritative runtime version selection',
        files=len(corpus['items']),logical_paths=len(rows),duplicate_groups=sum(r['variant_count']>1 for r in rows),
        conditional_selected=sum(r['conditional_winner'] is not None for r in rows),
        unknown_groups=sum(r['conditional_winner'] is None for r in rows),
        status_counts=dict(Counter(r['status'] for r in rows)),items=rows,
        full_execution='not_tested',source_variants_deleted=False,original_files_written=False,
        preconditions=['All relevant dataN archives mounted in primary slot N',
            'No matching loose file at the engine-resolved path',
            'Unrestricted slot (-1) lookup, or the stated restricted slot',
            'Other mount roots, callbacks and dynamic mutation do not change this lookup'])


def tail_observation(provider_record,window_record,address):
    sha=provider_record.get('subject',{}).get('digest',{}).get('sha256')
    if not sha or window_record.get('source_sha256')!=sha:raise ProbeError('tail_evidence_identity_mismatch')
    provider_addresses={int(m[1],16) for m in re.finditer(r'^0x([0-9a-f]+):',provider_record['normalized_result'],re.M)}
    decoded={}
    for line in window_record['normalized_result'].splitlines():
        match=re.match(r'\s*([0-9a-f]+):\s*((?:[0-9a-f]{2}\s+)+)\s*(.+)',line)
        if match:decoded[int(match[1],16)]=(match[2].strip(),match[3].strip())
    found=decoded.get(address)
    return dict(status='verified' if found else 'unsupported',address=hex(address),source_sha256=sha,
        source_file=window_record.get('source_file'),provider_evidence_id=provider_record['evidence_id'],
        window_evidence_id=window_record['evidence_id'],omitted_from_provider_instructions=address not in provider_addresses,
        instruction_byte_length=len(found[0].split()) if found else None,
        instruction_sha256=hashlib.sha256(bytes.fromhex(found[0])).hexdigest() if found else None,
        scope='Observed tail address membership only; no automatic function-body mutation')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--evidence-dir',type=Path,default=ROOT/'private/p1-round3/native-reproduced')
    parser.add_argument('--windows-dir',type=Path,default=ROOT/'private/p1-round3/windows')
    parser.add_argument('--plan',type=Path,default=ROOT/'docs/native-evidence-round3-plan.json')
    args=parser.parse_args();directory=absolute(args.evidence_dir);windows=absolute(args.windows_dir)
    for p in [directory,windows]:
        if ROOT/'private' not in p.parents:raise ProbeError('native_evidence_must_be_private')
    identity=json.loads(read_bounded(ROOT/'reports/p1/program-probe.json'));sha=identity['source_sha256']
    plan=json.loads(read_bounded(args.plan));queries=validate_plan(plan)
    if plan['source_sha256']!=sha:raise ProbeError('native_plan_sha256_mismatch')
    records={};summaries=[]
    for q in queries:
        d=json.loads(read_bounded(directory/(q['name']+'.json'),16*1024*1024))
        s=checked_evidence(d,sha,q['operation'],q['address']);s.update(name=q['name'],address=q['address'])
        records[q['name']]=d;summaries.append(s)
    facts=[evaluate_fact(s,records[s['evidence']],identity['source_file'],sha) for s in FACTS]
    window=json.loads(read_bounded(windows/'window-report.json'))
    if window['source_sha256']!=sha or window['source_sha256_after']!=sha or window['status']!='verified':
        raise ProbeError('LLVM_window_identity_or_collection_failed')
    previous=records['command-id-assembly']
    tails=[tail_observation(records['named-context-assembly'],
               json.loads(read_bounded(windows/'named-context-tail.json')),0x6c1372),
           tail_observation(previous,json.loads(read_bounded(windows/'command-id-tail.json')),0x6aa51d)]
    unsupported=[dict(name=s['name'],status='unsupported',reason='Ghidra has no decoded instruction/function at this address')
                 for s in summaries if s['observation_support']=='unsupported']
    report=dict(schema_version=1,dataset='real',status='verified' if all(f['status']=='verified' for f in facts+tails) else 'unsupported',
        scope='Selected observations only, including explicitly unavailable Ghidra coverage; not complete semantics',
        source_file=identity['source_file'],source_sha256=sha,queries=summaries,observations=facts,
        coverage_status='unsupported' if unsupported or plan.get('exploration_failures') else 'verified',
        unsupported_observations=unsupported,exploration_failures=plan.get('exploration_failures',[]),
        llvm_windows=window['windows'],tail_observations=tails,runtime_development_ready=False,original_files_written=False,
        full_game_compatibility='not_tested',external_game_data_uploads=False)
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    overlay=json.loads(read_bounded(ROOT/'reports/p1/overlay-report.json'))
    model=overlay_model(corpus,{g['logical_path'] for g in overlay['groups'] if g['relation']=='normalized_text_changed'})
    model['evidence_report']='reports/p1/native-round3-report.json'
    write_json(ROOT/'private/p1-round3/conditional-corpus.json',model)
    public=dict(model);public['items']=[r for r in model['items'] if r['changed_duplicate']]
    public.update(public_scope='All group counts and all changed-duplicate metadata; remaining rows in private report',
        private_metadata_report='private/p1-round3/conditional-corpus.json')
    write_json(ROOT/'reports/p1/conditional-overlay-report.json',public)
    write_json(ROOT/'reports/p1/native-round3-report.json',report)
    print(json.dumps(dict(status=report['status'],queries=len(summaries),observations=len(facts),
        unsupported_observations=len(unsupported),exploration_failures=len(report['exploration_failures']),
        conditional_paths=model['conditional_selected'],runtime_ready=False)))
    return 0 if report['status']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
