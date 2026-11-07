#!/usr/bin/env python3
"""Summarize pinned local scalar-helper observations; never execute the game."""
import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .rea_static import validate_plan,checked_evidence
    from .pe_probe import pe32
    from .integer_format import probe
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from rea_static import validate_plan,checked_evidence
    from pe_probe import pe32
    from integer_format import probe


def byte_reference(program,pe,start,end):
    if end<=start:raise ProbeError('scalar_invalid_address_range')
    sections=[s for s in pe['sections'] if pe['image_base']+s['rva']<=start and end<=pe['image_base']+s['rva']+s['raw_size']]
    if len(sections)!=1:raise ProbeError('scalar_range_not_uniquely_mapped')
    s=sections[0];a=s['raw_offset']+start-pe['image_base']-s['rva'];raw=program[a:a+end-start]
    if len(raw)!=end-start:raise ProbeError('scalar_truncated_source_range')
    return dict(offset=a,length=len(raw),sha256=hashlib.sha256(raw).hexdigest())


def observation(records,name,needles):
    record=records[name];text=record['normalized_result']
    if any(needle not in text for needle in needles):raise ProbeError('scalar_expected_observation_missing:'+name)
    return record['evidence_id']


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--native-dir',type=Path,default=ROOT/'private/p1-round6/native-reproduced')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/scalar-report.json')
    args=p.parse_args();game=absolute(args.game_dir);native=absolute(args.native_dir);output=absolute(args.output)
    if ROOT/'private' not in native.parents:raise ProbeError('scalar_native_evidence_must_be_private')
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('scalar_summary_must_be_public_P1')
    for path in [native,output]:
        if game==path or game in path.parents or path in game.parents:raise ProbeError('scalar_input_output_overlap')
    relative=safe_member_name(args.exe);program=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(program).hexdigest()
    plan=json.loads(read_bounded(ROOT/'docs/native-scalar-plan.json'));queries=validate_plan(plan)
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if sha!=plan['source_sha256'] or not any(f['path']==relative and f.get('sha256')==sha for f in inventory['files']):
        raise ProbeError('scalar_source_identity_mismatch')
    records={};summaries=[]
    for q in queries:
        record=json.loads(read_bounded(native/(q['name']+'.json'),16*1024*1024))
        summary=checked_evidence(record,sha,q['operation'],q['address']);summary.update(name=q['name'],address=q['address'])
        summaries.append(summary);records[q['name']]=record
    collection=dict(status='not_tested',scope='No independent collection manifest supplied')
    manifest=native/'collection-report.json'
    if manifest.exists():
        raw=read_bounded(manifest);collected=json.loads(raw)
        observed={(q['name'],q['address']) for q in collected.get('queries',[]) if q['status']=='verified'}
        expected={(q['name'],q['address']) for q in queries}
        if (collected.get('status')!='verified' or collected.get('cleanup')!='verified' or collected.get('errors')
            or collected.get('source_sha256')!=sha or collected.get('original_sha256_after')!=sha or observed!=expected):
            raise ProbeError('scalar_independent_collection_incomplete')
        collection=dict(status='verified',scope='All planned static queries completed and owned provider closed; not target execution',
            source_report=manifest.relative_to(ROOT).as_posix(),sha256=hashlib.sha256(raw).hexdigest(),query_count=len(queries))
    pe=pe32(program);facts=[]
    def fact(key,name,start,end,needles):
        evidence=observation(records,name,needles)
        facts.append(dict(id=key,status='verified',scope='Static instruction observation only',evidence_id=evidence,
            query=name,address_start=hex(start),address_end_exclusive=hex(end),
            source_file=relative,source_sha256=sha,raw_bytes_reference=byte_reference(program,pe,start,end)))
    fact('raw_numeric_first_character_gate','value-resolver-assembly',0x69b02b,0x69b061,
        ['0x69b02b: CMP AX, 0x24','0x69b031: CMP AX, 0x2d','0x69b037: CMP AX, 0x2b',
         '0x69b03d: CMP AX, 0x30','0x69b043: CMP AX, 0x39','0x69b04f: CALL 0x00415aa8','0x69b058: MOV byte ptr [EBX], 0x0'])
    fact('quoted_tag_and_integer_cache','value-resolver-assembly',0x69aff6,0x69b022,
        ['0x69aff6: CMP AX, 0x22','0x69affc: MOV byte ptr [EBX], 0x1','0x69b015: XOR EDX, EDX',
         '0x69b01a: CALL 0x00415a90','0x69b01f: MOV dword ptr [EBX + 0x4], EAX'])
    fact('integer_accumulation_and_prefix_checks','integer-core-assembly',0x404ffc,0x4050fe,
        ['0x40500e: MOV EDI, 0xccccccc','0x405019: CMP BX, 0x20','0x40502d: CMP BX, 0x24',
         '0x405033: CMP BX, 0x78','0x405039: CMP BX, 0x58','0x405087: TEST EAX, EAX',
         '0x405089: JGE 0x004050f3','0x405092: NEG EAX','0x405094: JLE 0x004050f3',
         '0x4050a7: MOV EDI, 0xfffffff','0x4050dd: SHL EAX, 0x4','0x4050f1: NEG EAX'])
    fact('integer_try_reports_error_zero','integer-try-assembly',0x415aaf,0x415ac1,
        ['0x415ab3: CALL 0x00404ffc','0x415aba: CMP dword ptr [ESP], 0x0','0x415abe: SETZ AL'])
    fact('preflight_checks_error_tags_only','scalar-preflight-assembly',0x69daac,0x69dabb,
        ['0x69daae: CMP byte ptr [EDX], 0x4','0x69dab3: CMP byte ptr [ECX], 0x4','0x69dab8: MOV AL, 0x1'])
    fact('numeric_add_path_is_32_bit_without_overflow_branch','addition-candidate-assembly',0x69a99a,0x69a9a6,
        ['0x69a99a: TEST AL, AL','0x69a99c: JNZ 0x0069a9a6','0x69a99e: MOV EAX, dword ptr [ESI + 0x4]',
         '0x69a9a1: ADD dword ptr [EBX + 0x4], EAX','0x69a9a4: JMP 0x0069a9b1'])
    fact('cal_nil_slot_skips_evaluation','dispatch-assembly',0x6b02b7,0x6b0315,
        ['0x6b02b7: CMP dword ptr [EBP + 0xfffffef0], 0x0','0x6b02be: JZ 0x006b030d',
         '0x6b02dc: CALL 0x006be1d8','0x6b030d: INC dword ptr [EBP + -0x4c]'])
    observation(records,'expression-core',['case 0x38:','FUN_0069a948(local_8,local_20,local_14,local_28)'])
    examples=['0','2147483647','2147483648','-2147483648','-2147483649','$FFFFFFFF','-$FFFFFFFF',
        '$100000000','$000000000000FFFFFFFF','0x80000000','xA','+xA',' 10','10 ','\t10','1.0','1e2','１２']
    contracts=[
        dict(id='integer_format',status='inferred',machine_fact='integer_accumulation_and_prefix_checks',
             meaning='Helper model: signed decimal, 32-bit hex bits, optional sign, leading ASCII spaces only; narrower raw caller gate'),
        dict(id='descriptor_names',status='inferred',machine_fact='quoted_tag_and_integer_cache',
             meaning='Tag 0 numeric, tag 1 string with cached integer, tag 3 unresolved atom, tag 4 error; field roles are interpretations'),
        dict(id='addition_dispatch',status='inferred',evidence_id=records['expression-core']['evidence_id'],
             meaning='Token *8 maps to helper 0x69a948; mixed tags update both fields, so ordinary host-language coercion is unsafe'),
        dict(id='empty_cal_field',status='inferred',machine_fact='cal_nil_slot_skips_evaluation',
             meaning='An empty corpus field may produce the observed nil slot; original field-to-pointer construction remains not_tested')]
    report=dict(schema_version=1,dataset='real',status='inferred',
        scope='Pinned static helper observations plus synthetic format hypotheses; no script execution or compatibility claim',
        source_file=relative,source_sha256=sha,queries=summaries,machine_facts=facts,inferred_contracts=contracts,
        independent_collection=collection,
        synthetic_format_examples=[dict(input=text,**probe(text)) for text in examples],
        original_execution_equivalence='not_tested',real_literal_execution='not_tested',
        expression_execution='unsupported',target_execution='not_tested',
        unknowns=['String allocation/copy and variable lifetime contracts','Assignment and array index semantics',
                  'Short-circuit behavior and arithmetic exceptions','Empty source field to nil pointer mapping',
                  'Float/exponent candidates are not verified literals','Save and event/timing state'],
        original_files_written=False,external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],queries=len(summaries),machine_facts=len(facts),
        synthetic_examples=len(examples),original_execution_equivalence='not_tested')))
    return 0


if __name__=='__main__':raise SystemExit(main())
