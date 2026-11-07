"""Own graph snippets and PE guard fixtures; all links remain static candidates."""
import json
import struct
import unittest
from tools.subp_analysis import inspect_document,link_prefixes,call_shape,dispatch_case,field_ref
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tools.qlie_lex import lex
from tests.test_delphi_metadata import fixture


def source(receiver='OwnReceiver'):
    return ('\\scp,rep\n\\et,"\\subp,@@'+receiver+',,"\n@@'+receiver+'\n\\cal,x=ParamStr[0]\n\\ret\n').encode()


def dispatch_fixture():
    data,put,_=fixture();guard=0x401700;table=guard+20;case=0x401750;call=case+3;target=0x401020
    put(guard,b'\x0f\xb6\x47\x0c\x83\xf8\x02\x0f\x87'+struct.pack('<i',0x401780-(guard+13))+b'\xff\x24\x85'+struct.pack('<I',table))
    put(table,struct.pack('<III',0x401740,case,0x401760));put(call,b'\xe8'+struct.pack('<i',target-(call+5)))
    return data,put,(guard,table,2,1,case,call,target)


class SubpAnalysisTests(unittest.TestCase):
    def test_prefix_links_retain_both_physical_versions_and_parent_proof(self):
        one=inspect_document(source(),'one.s');two=inspect_document(source(),'two.s')
        prefixes=one['prefixes']+two['prefixes'];edges,regions=link_prefixes(prefixes,one['regions']+two['regions'])
        self.assertEqual(len(edges),4);self.assertEqual(sum(e['same_source_file'] for e in edges),2)
        self.assertEqual(len(regions),2);self.assertTrue(all(e['runtime_target']=='not_tested' for e in edges))
        self.assertEqual(prefixes[0]['derived_calls'][0]['label_candidate_count'],2)
        self.assertNotIn('OwnReceiver',json.dumps(prefixes));self.assertNotIn('_identifier',json.dumps(regions))

    def test_receiver_mentions_have_source_field_proof_and_unknown_direction(self):
        found=inspect_document(source(),'one.s');_,regions=link_prefixes(found['prefixes'],found['regions'])
        mention=regions[0]['param_str_zero_mentions'][0]
        self.assertIn('raw_bytes_reference',mention['field_reference'])
        self.assertEqual(mention['read_write_direction'],'not_tested')

    def test_selector_hint_is_reset_at_label_boundary(self):
        found=inspect_document(b'\\scp,rep\n@@Other\n\\et,""','one.s')
        self.assertIsNone(found['prefixes'][0]['namespace_hint'])
        self.assertEqual(found['prefixes'][0]['namespace_binding'],'not_tested')

    def test_file_and_empty_tail_shapes_remain_distinct(self):
        cases=[('\\subp,@@Own','absent'),('\\subp,@@Own,,','raw_empty'),('\\subp,@@Own,"",payload','quoted_empty')]
        for text,expected in cases:
            r=lex(text.encode(),'one.s',field_model='native_grouping')['records'][0];shape=call_shape(r)
            self.assertEqual(shape['file_operand_shape'],expected);self.assertEqual(shape['runtime_argument_count'],'not_tested')
        r=lex(b'\\subp,@@Own,,"",,payload','one.s',field_model='native_grouping')['records'][0]
        shape=call_shape(r);self.assertEqual(shape['quoted_empty_tail_positions'],[0]);self.assertEqual(shape['raw_empty_tail_positions'],[1])
        self.assertNotIn('payload',json.dumps(shape))

    def test_dynamic_prefix_and_bad_arity_are_not_invented_as_calls(self):
        found=inspect_document(b'\\et,privateVariable\n\\nt,"one","two"','one.s')
        self.assertEqual(found['prefixes'][0]['literal_shape'],'not_tested')
        self.assertEqual(found['prefixes'][1]['status'],'unsupported')
        self.assertNotIn('privateVariable',json.dumps(found['prefixes']))

    def test_exact_label_match_does_not_guess_case_folding(self):
        found=inspect_document(b'\\et,"\\subp,@@Own,,"\n@@own\n\\ret','one.s')
        edges,_=link_prefixes(found['prefixes'],found['regions']);self.assertEqual(edges,[])
        self.assertEqual(found['prefixes'][0]['derived_calls'][0]['label_candidate_count'],0)

    def test_field_audit_reports_changed_spans_without_argument_text(self):
        found=inspect_document(b'\\cal,privateArray[1,2]','one.s')
        self.assertEqual(len(found['changes']),1);self.assertEqual(found['changes'][0]['old_arity'],2)
        self.assertEqual(found['changes'][0]['new_arity'],1);self.assertNotIn('privateArray',json.dumps(found['changes']))

    def test_guard_table_and_e8_call_are_checked_independently(self):
        data,_,args=dispatch_fixture();r=dispatch_case(Image(data),*args)
        self.assertEqual(r['object_type'],1);self.assertEqual(r['execution_semantics'],'not_tested')
        for at,raw in [(args[0]+6,b'\x03'),(args[1]+4,struct.pack('<I',0x401760)),(args[5],b'\xe9')]:
            data,put,args=dispatch_fixture();put(at,raw)
            with self.subTest(at=at),self.assertRaises(ProbeError):dispatch_case(Image(data),*args)

    def test_field_reference_bounds_do_not_accept_arbitrary_offsets(self):
        with self.assertRaises(ProbeError):field_ref(dict(source_file='one.s',sha256='a'*64),dict(byte_offset=2,byte_length=10),b'ab')


if __name__=='__main__':unittest.main()
