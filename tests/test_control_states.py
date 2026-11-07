"""Own invented instruction bytes and lexical blocks; never run a target."""
import unittest
from unittest import mock

from tools.control_state_analysis import (immediate_store,instruction_rows,stores,
    public_proof,marker_binding,block_binding,processing_deadline)
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tests.test_delphi_metadata import fixture


def proof(offset):
    return dict(source_file='invented.s',source_sha256='a'*64,byte_offset=offset,
        byte_length=4,record_sha256='b'*64,label_region='must-not-be-published')


def block(kind,start,end,depth):
    return dict(kind=kind,opener=proof(start),closer=proof(end),depth=depth,
        then_markers=[],else_markers=[])


def marker(token,offset):
    return dict(token=token,byte_offset=offset,byte_length=4,
        raw_bytes_reference=dict(offset=offset,length=4,sha256='c'*64))


class ControlStateTests(unittest.TestCase):
    def test_deadline_expiry_restores_original_handler_and_disarms_timer(self):
        with mock.patch('tools.control_state_analysis.signal.getitimer',return_value=(0.0,0.0)), \
            mock.patch('tools.control_state_analysis.signal.getsignal',return_value='original'), \
            mock.patch('tools.control_state_analysis.signal.signal') as install, \
            mock.patch('tools.control_state_analysis.signal.setitimer') as timer:
            with self.assertRaisesRegex(ProbeError,'control_processing_time_limit'):
                with processing_deadline():install.call_args.args[1](None,None)
            self.assertEqual(timer.call_args.args[1],0)
            self.assertEqual(install.call_args.args[1],'original')

    def test_successful_deadline_scope_also_disarms_timer(self):
        with mock.patch('tools.control_state_analysis.signal.getitimer',return_value=(0.0,0.0)), \
            mock.patch('tools.control_state_analysis.signal.getsignal',return_value='original'), \
            mock.patch('tools.control_state_analysis.signal.signal') as install, \
            mock.patch('tools.control_state_analysis.signal.setitimer') as timer:
            with processing_deadline():pass
            self.assertEqual([c.args[1] for c in timer.call_args_list],[120,0])
            self.assertEqual(install.call_args.args[1],'original')

    def test_existing_timer_is_not_silently_replaced(self):
        with mock.patch('tools.control_state_analysis.signal.getitimer',return_value=(2.0,0.0)), \
            mock.patch('tools.control_state_analysis.signal.signal') as install:
            with self.assertRaisesRegex(ProbeError,'existing_timer'):
                with processing_deadline():self.fail('Should not enter the scan')
            install.assert_not_called()

    def test_short_and_long_displacements_verify_exact_source_bytes(self):
        for raw,register,value in [(b'\xc6\x43\x34\x02','EBX',2),
            (b'\xc6\x86\x34\x00\x00\x00\x08','ESI',8)]:
            data,put,_=fixture();put(0x401020,raw)
            with self.subTest(register=register):
                ref=immediate_store(Image(data),0x401020,register,value)
                self.assertEqual(ref['length'],len(raw));self.assertEqual(ref['offset'],544)

    def test_wrong_immediate_displacement_or_register_is_rejected(self):
        for raw in [b'\xc6\x43\x34\x03',b'\xc6\x43\x35\x02',b'\xc6\x46\x34\x02']:
            data,put,_=fixture();put(0x401020,raw)
            with self.subTest(raw=raw),self.assertRaises(ProbeError):immediate_store(Image(data),0x401020,'EBX',2)

    def test_stack_register_and_out_of_byte_values_are_rejected(self):
        data,_,_=fixture()
        for register,value in [('ESP',2),('EBX',256),('EBX',-1)]:
            with self.subTest(register=register,value=value),self.assertRaises(ProbeError):
                immediate_store(Image(data),0x401020,register,value)

    def test_non_executable_section_is_rejected(self):
        data,put,_=fixture();put(0x401020,b'\xc6\x43\x34\x02');image=Image(data)
        image.pe['sections'][0]['executable']=False
        with self.assertRaises(ProbeError):immediate_store(image,0x401020,'EBX',2)

    def test_verified_store_claim_is_limited_to_declared_name_and_bytes(self):
        data,put,_=fixture();put(0x401020,b'\xc6\x43\x34\x02')
        rows,count=stores(Image(data),'0x401020: MOV byte ptr [EBX + 0x34], 0x2','ghidra',
            {2:dict(name='ToyTwo',raw_bytes_reference=dict(offset=10,length=7,sha256='d'*64))})
        self.assertEqual(count,1);self.assertEqual(rows[0]['status'],'verified')
        self.assertEqual(rows[0]['field_binding_status'],'inferred')
        self.assertEqual(rows[0]['execution_semantics'],'not_tested')

    def test_unknown_enum_value_remains_unsupported_with_raw_reference(self):
        data,put,_=fixture();put(0x401020,b'\xc6\x43\x34\x63')
        rows,_=stores(Image(data),'0x401020: MOV byte ptr [EBX + 0x34], 0x63','ghidra',{})
        self.assertEqual(rows[0]['status'],'unsupported');self.assertIn('raw_bytes_reference',rows[0])
        self.assertEqual(rows[0]['unknown_reason'],'state_value_not_in_reviewed_enum')

    def test_dynamic_and_other_modifying_stores_are_explicitly_unsupported(self):
        data,_,_=fixture()
        for text,reason in [('MOV byte ptr [EAX + 0x34], CL','dynamic_state_store_value'),
            ('INC byte ptr [EAX + 0x34]','state_modifying_instruction_outside_reviewed_encoding')]:
            with self.subTest(text=text):
                rows,_=stores(Image(data),'0x401020: '+text,'ghidra',{})
                self.assertEqual(rows[0]['status'],'unsupported');self.assertEqual(rows[0]['unknown_reason'],reason)

    def test_instruction_boundaries_exclude_comments_and_unrelated_fields(self):
        text='comment C6 43 34 02\n0x401020: NOP\n0x401021: MOV byte ptr [EBX + 0x38], 0x2'
        data,_,_=fixture();rows,count=stores(Image(data),text,'ghidra',{})
        self.assertEqual(rows,[]);self.assertEqual(count,2)
        llvm='  401020: c6 43 34 02 \tmov\tbyte ptr [ebx + 0x34], 0x2\n'
        self.assertEqual(instruction_rows(llvm,'llvm'),[(0x401020,'MOV BYTE PTR [EBX + 0X34], 0X2')])

    def test_loop_marker_can_lexically_enclose_an_inner_if(self):
        result=marker_binding(marker('cnt',40),[block('for',10,80,1),block('if',20,70,2)])
        self.assertEqual(result['candidate_kind'],'for');self.assertEqual(result['status'],'inferred')
        self.assertEqual(result['execution_target'],'not_tested')

    def test_marker_prefers_nearest_matching_family_and_rejects_boundary(self):
        result=marker_binding(marker('else',40),[block('case',10,80,1),block('if',20,70,2)])
        self.assertEqual(result['candidate_kind'],'if')
        self.assertEqual(marker_binding(marker('then',20),[block('if',20,70,1)])['status'],'not_tested')

    def test_unreviewed_control_spelling_is_preserved_without_guess(self):
        result=marker_binding(marker('dbrk',40),[block('for',10,80,1)])
        self.assertEqual(result['status'],'unsupported');self.assertNotIn('lexical_candidate',result)

    def test_public_links_redact_label_and_never_claim_execution_edges(self):
        self.assertNotIn('label_region',public_proof(proof(10)))
        members={v:dict(name='Toy'+str(v),raw_bytes_reference={}) for v in [2,5,6]}
        result=block_binding(block('if',10,80,1),members)
        self.assertEqual(result['status'],'inferred');self.assertEqual(result['execution_edges'],'not_tested')
        self.assertNotIn('label_region',result['opener'])


if __name__=='__main__':unittest.main()
