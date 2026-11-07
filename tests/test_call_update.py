"""Synthetic evidence guards and annotations; never execute an engine or values."""
import copy
import hashlib
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tools.mangekyou_p0 import ProbeError
from tools.native_summary import evaluate_fact,summarize
from tools.call_update_analysis import validate_facts,ret_constraint,call_slot_shapes
from tools.value_use_analysis import checked_phase_profile,annotate_phase,uses,public_operation
from tools.qlie_expr import parse


def toy_fact():
    return dict(id='synthetic',status='verified',evidence='toy',start='0x401000',end='0x401010',
        require_anchor_order=True,anchors=['0x401000: FIRST','0x401004: SECOND'])


def toy_profile():
    ids=['tokenizer_increment_call','tokenizer_decrement_call','update_read_add_write','tokenizer_precedes_transform']
    return dict(dataset='synthetic',status='inferred',errors=0,source_sha256='0'*64,execution_semantics='not_tested',
        observations=[dict(id=k,status='verified') for k in ids])


def toy_ret(count):
    return dict(token='ret',arity=count,source_file='synthetic.s',source_sha256='1'*64,
        byte_offset=4,byte_length=10,record_sha256='2'*64,literal_label='synthetic_secret',operand_shape=['private_shape'])


class CallUpdateTests(unittest.TestCase):
    def test_anchor_presence_alone_does_not_prove_listed_order(self):
        definition=toy_fact()
        positive=evaluate_fact(definition,dict(normalized_result='0x401000: FIRST\n0x401004: SECOND'),'synthetic.exe','0'*64)
        negative=evaluate_fact(definition,dict(normalized_result='0x401004: SECOND\n0x401000: FIRST'),'synthetic.exe','0'*64)
        self.assertEqual(positive['status'],'verified');self.assertEqual(negative['status'],'unsupported')
        self.assertEqual(negative['missing_anchor_count'],0);self.assertEqual(negative['anchor_order_status'],'unsupported')

    def test_fact_anchor_cannot_be_outside_its_byte_reference(self):
        plan=dict(schema_version=1,source_sha256='0'*64,queries=[dict(name='toy',operation='procedure_assembly',address='0x401000')])
        definition=dict(schema_version=1,source_sha256='0'*64,facts=[toy_fact()])
        self.assertEqual(len(validate_facts(definition,plan)),1)
        definition['facts'][0]['start']='0x401001'
        with self.assertRaises(ProbeError):validate_facts(definition,plan)

    def test_machine_fact_requires_assembly_query(self):
        plan=dict(schema_version=1,source_sha256='0'*64,queries=[dict(name='toy',operation='procedure_pseudo_code',address='0x401000')])
        with self.assertRaises(ProbeError):validate_facts(dict(schema_version=1,source_sha256='0'*64,facts=[toy_fact()]),plan)

    def test_duplicate_fact_ids_are_rejected(self):
        plan=dict(schema_version=1,source_sha256='0'*64,queries=[dict(name='toy',operation='procedure_assembly',address='0x401000')])
        with self.assertRaises(ProbeError):validate_facts(dict(schema_version=1,source_sha256='0'*64,facts=[toy_fact(),toy_fact()]),plan)

    def test_native_summary_rejects_wrong_actual_source_bytes(self):
        identity=dict(source_sha256=hashlib.sha256(b'expected synthetic bytes').hexdigest())
        plan=dict(schema_version=1,source_sha256=identity['source_sha256'],queries=[dict(name='toy',operation='procedure_assembly',address='0x401000')])
        with patch('tools.native_summary.read_bounded',return_value=json.dumps(identity).encode()),self.assertRaises(ProbeError):
            summarize(Path('/synthetic'),plan,fact_specs=[],program=b'different synthetic bytes')

    def test_ret_arguments_are_context_target_candidates_not_verified_return_values(self):
        empty=ret_constraint(toy_ret(0));named=ret_constraint(toy_ret(1))
        self.assertEqual(empty['argument_role'],'default_caller_context_candidate')
        self.assertEqual(named['argument_role'],'context_target_expression_candidate')
        self.assertEqual(named['status'],'inferred');self.assertEqual(named['return_value_semantics'],'not_tested')

    def test_unreviewed_ret_arity_remains_unsupported(self):
        result=ret_constraint(toy_ret(2));self.assertEqual(result['status'],'unsupported');self.assertIn('unknown_reason',result)
        row=toy_ret(1);row['token']='sub';self.assertIsNone(ret_constraint(row))

    def test_ret_metadata_does_not_copy_label_or_operand_data(self):
        public=json.dumps(ret_constraint(toy_ret(1)))
        self.assertNotIn('synthetic_secret',public);self.assertNotIn('private_shape',public)
        self.assertIn('record_sha256',public)

    def test_update_profile_requires_verified_primitive_facts_and_matching_binary(self):
        for mutate in ['identity','fact','duplicate']:
            value=toy_profile()
            if mutate=='identity':value['source_sha256']='1'*64
            elif mutate=='fact':value['observations'][0]['status']='inferred'
            else:value['observations'].append(copy.deepcopy(value['observations'][0]))
            with self.subTest(mutate=mutate),self.assertRaises(ProbeError):checked_phase_profile(value,'0'*64,{'path':'synthetic.json'})

    def test_phase_annotation_is_inferred_and_does_not_mutate_input(self):
        operation=uses(parse('counter++'))[0][0];before=copy.deepcopy(operation)
        profile=checked_phase_profile(toy_profile(),'0'*64,{'path':'synthetic.json'})
        annotated=annotate_phase(operation,profile)
        self.assertEqual(operation,before);self.assertEqual(annotated['phase_status'],'inferred')
        self.assertEqual(annotated['phase_evidence']['old_value_capture'],'not_tested')
        self.assertNotIn('evaluated_value',annotated)
        unsupported=uses(parse('1++'))[0][0];self.assertNotIn('phase_status',annotate_phase(unsupported,profile))

    def test_phase_metadata_still_redacts_actual_identifier(self):
        operation=uses(parse('合成秘密++'))[0][0];profile=checked_phase_profile(toy_profile(),'0'*64,{'path':'synthetic.json'})
        text=json.dumps(public_operation(annotate_phase(operation,profile)),ensure_ascii=False)
        self.assertNotIn('合成秘密',text);self.assertIn('target_name_sha256',text)

    def test_phase_profile_does_not_promote_static_semantics_to_execution(self):
        value=toy_profile();value['execution_semantics']='verified'
        with self.assertRaises(ProbeError):checked_phase_profile(value,'0'*64,{'path':'synthetic.json'})

    def test_raw_empty_argument_is_distinct_from_quoted_empty_string(self):
        shape=call_slot_shapes([dict(raw=s) for s in ['@@Synthetic','self','','""','value']])
        self.assertEqual(shape['raw_empty_positions'],[0]);self.assertEqual(shape['quoted_empty_positions'],[1])
        self.assertTrue(shape['sparse_raw_fields']);self.assertEqual(shape['runtime_argument_count'],'not_tested')

    def test_extra_argument_slots_remain_explicit_metadata(self):
        shape=call_slot_shapes([dict(raw='x') for _ in range(19)])
        self.assertEqual(shape['argument_field_count'],17);self.assertEqual(shape['outside_reviewed_slot_count'],1)
        self.assertEqual(shape['nil_pointer_mapping'],'not_tested')


if __name__=='__main__':unittest.main()
