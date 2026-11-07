"""Invented PE instruction patterns and state tables; no target execution."""
import struct
import unittest

from tools.reader_analysis import call_candidates,state_dispatch,branch_observations
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tests.test_delphi_metadata import fixture


def toy_dispatch():
    data,put,_=fixture();guard=0x401700;table=guard+23;start=table+8;default=0x401740
    raw=b'\x0f\xb6\x58\x4c\x0f\xb6\xc3\x83\xf8\x01\x0f\x87'+struct.pack('<i',default-(guard+16))+b'\xff\x24\x85'+struct.pack('<I',table)
    put(guard,raw);put(table,struct.pack('<II',0x401720,0x401730))
    enum=dict(minimum_i32=0,maximum_i32=1,members=[dict(value=i,name=name,raw_bytes_reference={}) for i,name in enumerate(['ToyActive','ToyWait'])])
    return data,put,enum,(guard,table,start,default,0x4c)


class ReaderAnalysisTests(unittest.TestCase):
    def test_forward_and_backward_e8_candidates_have_exact_source_reference(self):
        data,put,_=fixture();target=0x401050
        for at in [0x401020,0x401080]:put(at,b'\xe8'+struct.pack('<i',target-(at+5)))
        rows,examined=call_candidates(Image(data),[target])
        self.assertEqual([r['address'] for r in rows],['0x401020','0x401080']);self.assertGreater(examined,0)
        self.assertTrue(all(r['raw_bytes_reference']['length']==5 for r in rows))

    def test_embedded_pattern_is_kept_as_candidate_without_call_claim(self):
        data,put,_=fixture();at=0x401021;target=0x401050
        put(at-1,b'\xb8\xe8'+struct.pack('<i',target-(at+5)))
        rows,_=call_candidates(Image(data),[target]);self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['status'],'inferred');self.assertEqual(rows[0]['instruction_boundary'],'not_tested')

    def test_partial_e8_at_section_end_is_not_read_past_end(self):
        data,put,_=fixture();put(0x402dfc,b'\xe8\x00\x00\x00')
        self.assertEqual(call_candidates(Image(data),[0x401050])[0],[])

    def test_target_count_duplicates_and_candidate_limit_are_enforced(self):
        data,put,_=fixture();put(0x401020,b'\xe8'+struct.pack('<i',0x401050-0x401025))
        for targets,limit in [([],128),([0x401050]*2,128),([0x401050],0)]:
            with self.subTest(targets=targets,limit=limit),self.assertRaises(ProbeError):call_candidates(Image(data),targets,limit)

    def test_non_executable_or_unmapped_targets_are_rejected(self):
        data,_,_=fixture();image=Image(data);image.pe['sections'][0]['executable']=False
        with self.assertRaises(ProbeError):call_candidates(image,[0x401050])
        with self.assertRaises(ProbeError):call_candidates(Image(data),[0x500000])

    def test_state_table_is_joined_to_declared_names_without_scheduler_claim(self):
        data,_,enum,args=toy_dispatch();r=state_dispatch(Image(data),enum,*args)
        self.assertEqual([(b['value'],b['declared_name'],b['branch_address']) for b in r['bindings']],
            [(0,'ToyActive','0x401720'),(1,'ToyWait','0x401730')])
        self.assertEqual(r['execution_semantics'],'not_tested');self.assertEqual(r['status'],'inferred')

    def test_guard_maximum_and_index_encoding_must_match(self):
        for offset,raw in [(9,b'\x02'),(18,b'\x45')]:
            data,put,enum,args=toy_dispatch();put(args[0]+offset,raw)
            with self.subTest(offset=offset),self.assertRaises(ProbeError):state_dispatch(Image(data),enum,*args)

    def test_plan_table_default_and_field_must_agree_with_bytes(self):
        for index in [1,3,4]:
            data,_,enum,args=toy_dispatch();changed=list(args);changed[index]+=4
            with self.subTest(index=index),self.assertRaises(ProbeError):state_dispatch(Image(data),enum,*changed)

    def test_nonzero_minimum_and_gapped_enum_are_rejected(self):
        for change in ['minimum','members']:
            data,_,enum,args=toy_dispatch()
            if change=='minimum':enum['minimum_i32']=1
            else:enum['members'][1]['value']=3
            with self.subTest(change=change),self.assertRaises(ProbeError):state_dispatch(Image(data),enum,*args)

    def test_table_target_cannot_enter_table_or_leave_handler_window(self):
        for target in [0x401717,0x401740,0xffffffff]:
            data,put,enum,args=toy_dispatch();put(args[1],struct.pack('<I',target))
            with self.subTest(target=target),self.assertRaises(ProbeError):state_dispatch(Image(data),enum,*args)

    def test_handler_calls_and_state_reset_are_individually_byte_checked(self):
        data,put,enum,args=toy_dispatch();at=0x401720;target=0x401050
        put(at,b'\xe8'+struct.pack('<i',target-(at+5))+b'\xc6\x40\x4c\x00')
        image=Image(data);r=state_dispatch(image,enum,*args)
        r=branch_observations(image,r,'401720: e8 2b f9 ff ff call 0x401050\n401725: c6 40 4c 00 mov byte ptr [eax + 0x4c], 0x0')
        binding=r['bindings'][0];self.assertEqual(binding['direct_call_observations'][0]['target'],'0x401050')
        self.assertEqual(binding['state_reset_observations'][0]['value'],0)
        self.assertEqual(binding['execution_semantics'],'not_tested')

    def test_mismatched_call_observation_is_not_promoted(self):
        data,_,enum,args=toy_dispatch();image=Image(data);r=state_dispatch(image,enum,*args)
        with self.assertRaises(ProbeError):branch_observations(image,r,'401720: e8 2b f9 ff ff call 0x401050')


if __name__=='__main__':unittest.main()
