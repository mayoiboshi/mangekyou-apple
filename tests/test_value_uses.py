"""Candidate reference roles, never a storage backend or an engine test."""
import hashlib
import json
import unittest

from tools.qlie_expr import parse,attach_source
from tools.qlie_lex import decode_spans
from tools.value_use_analysis import uses,public_operation
from tools.variable_analysis import unknown_instructions


class ValueUseTests(unittest.TestCase):
    def test_assignment_target_and_value_roles_are_distinct_candidates(self):
        ops,refs=uses(parse('target=source+1'))
        self.assertEqual(len(ops),1);self.assertEqual(ops[0]['status'],'inferred')
        self.assertEqual([(r['name'],r['role']) for r in refs],
            [('target','assignment_base_candidate'),('source','value_identifier_candidate')])

    def test_array_target_preserves_index_dependency(self):
        ops,refs=uses(parse('array[index+1]=value'))
        self.assertEqual(ops[0]['target_kind'],'index_candidate')
        self.assertEqual(ops[0]['subscripts'][0]['kind'],'binary_candidate')
        self.assertEqual([r['role'] for r in refs],
            ['assignment_base_candidate','index_operand_candidate','value_identifier_candidate'])

    def test_postfix_update_is_not_collapsed_into_assignment(self):
        ops,refs=uses(parse('array[index]++'))
        self.assertEqual(ops[0]['operation_kind'],'update_candidate');self.assertEqual(ops[0]['operator'],'++')
        self.assertEqual([r['role'] for r in refs],['update_base_candidate','index_operand_candidate'])

    def test_nested_operations_preserve_order_as_unverified(self):
        ops,refs=uses(parse('a=(b=1)'))
        self.assertEqual(len(ops),2);self.assertFalse(ops[0]['nested']);self.assertTrue(ops[1]['nested'])
        self.assertNotIn('evaluation_order',ops[0])

    def test_literal_and_grouped_targets_remain_explicitly_unsupported(self):
        for text in ['1=2','"name"=3','(name)=2','1++']:
            with self.subTest(text=text):
                ops,_=uses(parse(text));self.assertEqual(ops[0]['status'],'unsupported')
                self.assertIn('unknown_reason',ops[0])

    def test_nested_brackets_do_not_become_runtime_rank_claim(self):
        ops,refs=uses(parse('a[i][j]=b'))
        self.assertEqual(ops[0]['nested_index_syntax_count'],2)
        self.assertNotIn('array_rank',ops[0]);self.assertEqual([r['name'] for r in refs],['a','i','j','b'])

    def test_quoted_text_has_no_identifier_or_operation_effect(self):
        ops,refs=uses(parse('message="array[index]++=other"'))
        self.assertEqual(len(ops),1);self.assertEqual([r['name'] for r in refs],['message'])

    def test_reference_offsets_are_original_utf16_spans(self):
        text='配列[番号]=値';data=text.encode('utf-16-le');_,spans=decode_spans(data,'utf-16-le')
        tree=attach_source(parse(text),data,spans,'synthetic.s',hashlib.sha256(data).hexdigest());ops,refs=uses(tree)
        index=next(r for r in refs if r['name']=='番号')
        self.assertEqual(index['byte_offset'],6);self.assertEqual(index['byte_length'],4)
        self.assertEqual(index['raw_bytes_reference']['sha256'],hashlib.sha256(data[6:10]).hexdigest())

    def test_public_operation_redacts_actual_target_name(self):
        ops,_=uses(parse('合成秘密[0]=1'));public=public_operation(ops[0]);text=json.dumps(public,ensure_ascii=False)
        self.assertNotIn('合成秘密',text);self.assertNotIn('target_name"',text)
        self.assertIn('target_name_sha256',public)

    def test_rhs_index_is_not_an_assignment_target(self):
        ops,refs=uses(parse('out=source[index]'))
        self.assertEqual(ops[0]['target_kind'],'identifier_candidate')
        self.assertEqual([r['role'] for r in refs],
            ['assignment_base_candidate','value_identifier_candidate','index_operand_candidate'])

    def test_linear_unknown_decodes_retain_every_address(self):
        text='  401000: ff ff  <unknown>\n  401002: 90 nop\n  401003: ff ff <unknown>\n'
        self.assertEqual(unknown_instructions(text),['0x401000','0x401003'])

    def test_linear_marker_without_instruction_address_is_not_a_decode(self):
        self.assertEqual(unknown_instructions('limitation: <unknown>\n  401000: c3 ret\n'),[])


if __name__=='__main__':unittest.main()
