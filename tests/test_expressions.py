"""Structural expression-model tests, never original-engine semantic tests."""
import copy
import hashlib
import json
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.qlie_lex import decode_spans
from tools.qlie_expr import ExpressionError,parse,public_tree,attach_source
from tools.expression_analysis import analyze_field,literal_tag
from tools.pe_probe import pe32
from tools.ghidra_tail_probe import model_recovery
from tests.test_semantic_evidence import synthetic_pe


class ExpressionModelTests(unittest.TestCase):
    def test_logical_operators_share_a_pass_in_this_model(self):
        node=parse('a||b&&c')
        self.assertEqual(node['operator'],'&&');self.assertEqual(node['children'][0]['operator'],'||')

    def test_bitwise_group_and_shift_order_do_not_copy_c_precedence(self):
        node=parse('a|b&c');self.assertEqual(node['operator'],'&')
        self.assertEqual(node['children'][0]['operator'],'|')
        node=parse('a+b<<c&d')
        self.assertEqual(node['operator'],'&');self.assertEqual(node['children'][0]['operator'],'<<')
        self.assertEqual(node['children'][0]['children'][0]['operator'],'+')

    def test_groups_override_pass_order(self):
        node=parse('a||(b&&c)')
        self.assertEqual(node['operator'],'||');self.assertEqual(node['children'][1]['kind'],'group_candidate')

    def test_same_pass_associativity_is_explicitly_a_hypothesis(self):
        node=parse('a-b-c');self.assertEqual(node['children'][0]['operator'],'-')
        node=parse('a=b=c');self.assertEqual(node['children'][0]['operator'],'=')
        self.assertEqual(node['confidence'],'inferred');self.assertEqual(node['semantic_status'],'not_tested')

    def test_index_and_postfix_update_preserve_unknown_effects(self):
        node=parse('ParamInt[#index+1]++')
        self.assertEqual(node['kind'],'postfix_update_candidate')
        self.assertEqual(node['children'][0]['kind'],'index_candidate')
        self.assertIn('unverified',node['unknown_reason'])

    def test_unverified_prefix_call_and_punctuation_are_rejected(self):
        for text in ['++x','f(1)','!x','a?b:c','a,b','{1}','a+']:
            with self.subTest(text=text),self.assertRaises(ExpressionError):parse(text)

    def test_quoted_paths_keep_backslashes_and_operators_literal(self):
        node=parse('#s="folder\\image+&&.png"')
        self.assertEqual(node['children'][1]['value'],'"folder\\image+&&.png"')
        with self.assertRaises(ExpressionError):parse('#s="unterminated')

    def test_unary_shape_has_no_execution_semantics(self):
        node=parse('^(-#a)+2')
        self.assertEqual(node['children'][0]['kind'],'unary_candidate')
        self.assertEqual(node['children'][0]['operator'],'^')
        self.assertEqual(node['semantic_status'],'not_tested')

    def test_nonbmp_source_offsets_use_original_utf16_bytes(self):
        data='#s="😀"'.encode('utf-16-le');text,spans=decode_spans(data,'utf-16-le')
        node=attach_source(parse(text),data,spans,'synthetic.s',hashlib.sha256(data).hexdigest())
        literal=node['children'][1]
        self.assertEqual(data[literal['byte_offset']:literal['byte_offset']+literal['byte_length']],'"😀"'.encode('utf-16-le'))
        self.assertEqual(literal['byte_length'],8)

    def test_cp932_alias_is_not_reencoded_for_node_hashes(self):
        data=b'#s="\x87\x90"';text,spans=decode_spans(data,'cp932')
        node=attach_source(parse(text),data,spans,'synthetic.s',hashlib.sha256(data).hexdigest())
        self.assertEqual(node['children'][1]['raw_bytes_reference']['sha256'],hashlib.sha256(b'"\x87\x90"').hexdigest())

    def test_public_tree_redacts_all_atoms(self):
        node=parse('#secret="合成の秘密"');text=json.dumps(public_tree(node),ensure_ascii=False)
        self.assertNotIn('#secret',text);self.assertNotIn('合成の秘密',text);self.assertNotIn('"value":',text)
        self.assertIn('decoded_atom_sha256',text)

    def test_depth_and_size_limits_fail_explicitly(self):
        for text in ['('*70+'1'+')'*70,'+'.join(['a']*80),'1'*8193]:
            with self.subTest(length=len(text)),self.assertRaises(ExpressionError):parse(text)

    def test_field_failure_preserves_original_byte_reference(self):
        data=b'xx!a';field=dict(byte_offset=2,byte_length=2,raw='!a')
        record=analyze_field(data,field,'cp932','synthetic.s',hashlib.sha256(data).hexdigest(),{'command':'if'})
        self.assertEqual(record['status'],'unsupported');self.assertEqual(record['error_byte_offset'],2)
        self.assertEqual(record['raw_bytes_reference']['sha256'],hashlib.sha256(b'!a').hexdigest())

    def test_operator_literal_requires_mapping_shape_and_termination(self):
        data=synthetic_pe();data[520:526]='*a\0'.encode('utf-16-le');pe=pe32(data)
        tag,ref=literal_tag(data,pe,0x401008);self.assertEqual(tag,'*a');self.assertEqual(ref['offset'],520)
        data[524]=1
        with self.assertRaises(ProbeError):literal_tag(data,pe,0x401008)
        with self.assertRaises(ProbeError):literal_tag(data,pe,0x400000)

    def test_expected_void_function_does_not_require_fake_value_return(self):
        raw=dict(functions=[dict(name='void_helper',variant=dict(status='verified',pseudocode='void f(void) { return; }'))])
        self.assertEqual(model_recovery(raw),'unsupported')
        self.assertEqual(model_recovery(raw,{'void_helper':False}),'verified')
        changed=copy.deepcopy(raw);changed['functions'][0]['variant']['pseudocode']='UNRECOVERED_JUMPTABLE();'
        self.assertEqual(model_recovery(changed,{'void_helper':False}),'unsupported')


if __name__=='__main__':unittest.main()
