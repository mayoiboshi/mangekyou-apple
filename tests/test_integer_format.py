"""Static model boundaries, not execution of the commercial integer helper."""
import hashlib
import unittest

from tools.integer_format import probe,caller_numeric_gate
from tools.qlie_expr import parse,ExpressionError,attach_source
from tools.qlie_lex import decode_spans
from tools.scalar_analysis import byte_reference,observation
from tools.pe_probe import pe32
from tools.mangekyou_p0 import ProbeError
from tests.test_semantic_evidence import synthetic_pe


class IntegerFormatTests(unittest.TestCase):
    def test_decimal_signed_boundaries(self):
        for text,expected in [('2147483647',2147483647),('-2147483648',-2147483648),('0',0),('-0',0)]:
            with self.subTest(text=text):self.assertEqual(probe(text)['signed_i32'],expected)
        for text in ['2147483648','-2147483649','99999999999999999']:
            with self.subTest(text=text):self.assertFalse(probe(text)['accepted'])

    def test_hex_preserves_all_32_bits_and_modular_negation(self):
        for text,bits,signed in [('$FFFFFFFF',0xffffffff,-1),('0x80000000',0x80000000,-2147483648),
                                ('-$FFFFFFFF',1,1),('+$deadBEEF',0xdeadbeef,-559038737)]:
            with self.subTest(text=text):
                result=probe(text);self.assertEqual(result['bits_u32'],bits);self.assertEqual(result['signed_i32'],signed)
        self.assertFalse(probe('$100000000')['accepted'])

    def test_core_prefixes_are_not_all_raw_caller_literals(self):
        for text in ['xA','XA',' 10']:
            with self.subTest(text=text):
                self.assertTrue(probe(text)['accepted']);self.assertFalse(caller_numeric_gate(text))
        self.assertTrue(probe('+xA')['caller_gate'])
        self.assertTrue(probe('+$A')['accepted'])

    def test_leading_zero_count_does_not_replace_accumulator_bound(self):
        for text in ['$000000000000FFFFFFFF','00000000002147483647']:
            with self.subTest(text=text):self.assertTrue(probe(text)['accepted'])

    def test_ascii_space_is_the_only_skipped_core_prefix(self):
        self.assertTrue(probe('   -12')['accepted'])
        for text in ['\t12','\n12','\u300012','12 ','- 12']:
            with self.subTest(text=text):self.assertFalse(probe(text)['accepted'])

    def test_invalid_values_do_not_silently_become_zero(self):
        for text in ['', ' ', '+', '-', '$', '0x', 'x', '$G', '--1', '1.0', '1e2', '１２', '١٢']:
            with self.subTest(text=text):
                result=probe(text);self.assertFalse(result['accepted']);self.assertNotIn('bits_u32',result)
                self.assertIn('rejection_reason',result)

    def test_probe_rejects_oversize_and_excludes_embedded_nul(self):
        for text in ['0'*8193,'1\0tail']:
            with self.subTest(text=text):
                result=probe(text);self.assertEqual(result['status'],'not_tested');self.assertIsNone(result['accepted'])
                self.assertNotIn('bits_u32',result)

    def test_model_never_claims_original_execution_equivalence(self):
        for text in ['10','$FF','invalid']:
            with self.subTest(text=text):
                self.assertEqual(probe(text)['status'],'inferred')
                self.assertEqual(probe(text)['original_execution_equivalence'],'not_tested')

    def test_hex_literal_shape_does_not_consume_variable_name_prefixes(self):
        self.assertEqual(parse('$deadBEEF')['kind'],'number_literal_candidate')
        for text in ['$Background','$ColorName','$faceLabel']:
            with self.subTest(text=text):self.assertEqual(parse(text)['kind'],'identifier_candidate')
        for text in ['$', '$123G']:
            with self.subTest(text=text),self.assertRaises(ExpressionError):parse(text)

    def test_dollar_literal_offsets_and_confidence_survive_source_attachment(self):
        text='値[0]=$00fF';data=text.encode('utf-16-le');_,spans=decode_spans(data,'utf-16-le')
        node=attach_source(parse(text),data,spans,'synthetic.s',hashlib.sha256(data).hexdigest())
        literal=node['children'][1];self.assertEqual(literal['byte_offset'],10)
        self.assertEqual(data[10:20],'$00fF'.encode('utf-16-le'))
        self.assertEqual(literal['semantic_status'],'not_tested')

    def test_scalar_evidence_range_uses_source_bytes(self):
        data=synthetic_pe();data[520:526]=b'ABCDEF'
        ref=byte_reference(data,pe32(data),0x401008,0x40100e)
        self.assertEqual(ref,dict(offset=520,length=6,sha256=hashlib.sha256(b'ABCDEF').hexdigest()))

    def test_scalar_evidence_refuses_unmapped_or_empty_ranges(self):
        data=synthetic_pe();pe=pe32(data)
        for start,end in [(0x400000,0x400001),(0x401000,0x401000),(0x4011ff,0x401201)]:
            with self.subTest(start=start,end=end),self.assertRaises(ProbeError):byte_reference(data,pe,start,end)

    def test_missing_native_observation_cannot_satisfy_a_fact(self):
        records={'synthetic':dict(evidence_id='synthetic-evidence',normalized_result='one observed instruction')}
        self.assertEqual(observation(records,'synthetic',['observed']),'synthetic-evidence')
        with self.assertRaises(ProbeError):observation(records,'synthetic',['invented instruction'])


if __name__=='__main__':unittest.main()
