"""Owned count/metadata fixtures; no game code, script evaluation or runtime."""
import json
import struct
import unittest

from tools.default_field_audit import slot_projection,project_candidates,binding_checks
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tests.test_delphi_metadata import fixture


def binding_fixture():
    data,put,u32=fixture();minimum=0x401a00;mode=0x401a10;call=0x401a20;target=0x401020
    put(minimum,b'\xb9'+struct.pack('<I',9));put(mode,b'\xba'+struct.pack('<I',3))
    put(call,b'\xe8'+struct.pack('<i',target-call-5))
    slots=[dict(offset=i,target=hex(target)) for i in [12,20,56,60,152]]
    slots[1]['target']='0x401030';put(0x401030,b'\x8b\x40\x20\xc3')
    for slot in slots:u32(0x401100+slot['offset'],int(slot['target'],16))
    enum=0x401920;cell=0x401900;u32(cell,enum);name=b'TScriptValueType'
    put(enum,b'\x03'+bytes([len(name)])+name+struct.pack('<BiiI',1,0,0,cell)+b'\x09vtInteger')
    va=0x401600;name=b'TReturnValue';raw=b'\x0e'+bytes([len(name)])+name+struct.pack('<II',12,0)+b'\0'
    fields=va+len(raw);raw+=struct.pack('<I',3)
    for label,offset,typ in [('ValueType',0,cell),('IntValue',4,0),('StrValue',8,0)]:
        raw+=struct.pack('<IIB',typ,offset,2)+bytes([len(label)])+label.encode()+b'\x02\0'
    put(va,raw)
    return data,put,dict(minimum_count=9,mode_field_index=3,minimum_load=hex(minimum),mode_index_load=hex(mode),
        split_call=hex(call),split_target=hex(target),list_vmt='0x401100',list_name='ToyRoutine',slots=slots,
        return_record=dict(name='TReturnValue',type_info=hex(va),fields_count_address=hex(fields)))


def candidate(arity=2,rep=True):
    ref=dict(source_file='owned.s',source_sha256='0'*64,byte_offset=4,byte_length=8,
        raw_bytes_reference=dict(offset=4,length=8,sha256='0'*64))
    return dict(**ref,lexical_arity=arity,same_line_selector_hint=dict(reference=ref,matches_builtin_rep_literal=rep),
        private_text='must-not-appear')


class DefaultFieldAuditTests(unittest.TestCase):
    def test_omitted_mode_accounts_for_command_slot_zero(self):
        rows,skipped=project_candidates([candidate()],9,3);p=rows[0]['projection']
        self.assertEqual(p['source_field_count'],3);self.assertEqual(p['origin'],'appended_null_candidate')
        self.assertEqual(p['converted_value_candidate']['integer'],0);self.assertEqual(skipped,0)
        self.assertEqual(rows[0]['actual_registration'],'not_tested')

    def test_explicit_field_is_not_evaluated_or_assumed_null(self):
        rows,_=project_candidates([candidate(3)],9,3);p=rows[0]['projection']
        self.assertEqual(p['origin'],'source_field');self.assertNotIn('converted_value_candidate',p)
        self.assertEqual(p['value_conversion'],'not_tested')

    def test_minimum_does_not_truncate_existing_fields(self):
        p=slot_projection(15,9,14);self.assertEqual(p['list_count_candidate'],15);self.assertEqual(p['origin'],'source_field')

    def test_index_equal_to_projected_count_is_outside(self):
        p=slot_projection(3,9,9);self.assertEqual(p['status'],'unsupported');self.assertEqual(p['origin'],'outside_list')

    def test_counts_types_and_indices_are_bounded(self):
        for args in [(-1,9,3),(65,9,3),(3,0,3),(3,65,3),(3,9,64),(True,9,3),(3.0,9,3)]:
            with self.subTest(args=args),self.assertRaises(ProbeError):slot_projection(*args)

    def test_other_namespace_and_absent_hint_remain_explicitly_skipped(self):
        one=candidate(rep=False);two=candidate();two['same_line_selector_hint']=None
        rows,skipped=project_candidates([one,two],9,3);self.assertEqual(rows,[]);self.assertEqual(skipped,2)

    def test_projection_redacts_fields_and_does_not_claim_reachability(self):
        rows,_=project_candidates([candidate()],9,3)
        self.assertNotIn('must-not-appear',json.dumps(rows));self.assertNotIn('private_text',rows[0])
        self.assertEqual(rows[0]['projection']['runtime_reachability'],'not_tested')

    def test_candidate_count_limit_is_not_silently_truncated(self):
        with self.assertRaises(ProbeError):project_candidates([candidate()]*10001,9,3)

    def test_binding_fixture_keeps_byte_proof_separate_from_full_abi(self):
        data,_,plan=binding_fixture();r=binding_checks(Image(data),plan)
        self.assertEqual(r['status'],'verified');self.assertEqual(r['complete_ABI'],'not_tested')
        self.assertEqual(r['return_record']['fields'][0]['type_info']['name'],'TScriptValueType')

    def test_wrong_minimum_index_call_and_slot_are_rejected(self):
        for at,raw in [(0x401a01,b'\x08'),(0x401a11,b'\x02'),(0x401a20,b'\xe9'),(0x40110c,b'\0'*4)]:
            data,put,plan=binding_fixture();put(at,raw)
            with self.subTest(at=at),self.assertRaises(ProbeError):binding_checks(Image(data),plan)


if __name__=='__main__':unittest.main()
