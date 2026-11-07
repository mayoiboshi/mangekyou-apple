"""Synthetic evidence tests. These do not execute or contain game code."""
import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.pe_probe import locate, pe32, probe, selector_patterns
from tools.qlie_lex import digest, lex
from tools.native_summary import evaluate_fact
from tools.rea_static import checked_evidence, unpack, validate_plan
from tools.semantic_evidence import (
    annotate_regions, assignment_target, blocks, core_contracts, load_documents,
    parameter_footprints, public_contract, range_evidence, save_boundaries,
)


def document(text, name='synthetic.pack/test.s'):
    data=text.encode('utf-16')
    doc=lex(data,name)
    doc.update(_bytes=data,logical_path=name.split('/',1)[-1])
    annotate_regions(doc)
    return doc


def synthetic_pe():
    data=bytearray(1024)
    data[:2]=b'MZ';struct.pack_into('<I',data,60,0x80)
    data[0x80:0x84]=b'PE\0\0'
    struct.pack_into('<HH',data,0x84,0x14c,1)
    struct.pack_into('<H',data,0x94,224)
    struct.pack_into('<H',data,0x98,0x10b)
    struct.pack_into('<I',data,0x98+16,0x1000)
    struct.pack_into('<I',data,0x98+28,0x400000)
    section=0x98+224
    data[section:section+8]=b'.text\0\0\0'
    struct.pack_into('<4I',data,section+8,512,0x1000,512,512)
    struct.pack_into('<I',data,section+36,0x60000020)
    return data


class PEProbeTests(unittest.TestCase):
    def test_exact_variable_pattern_retains_unknown_scope(self):
        data=synthetic_pe()
        data[520:531]=b'\x81\x7d\xd0svar\x75\x02\xb3\x01'
        result=probe(bytes(data));hit=result['variable_category_patterns'][0]
        self.assertEqual(hit['va'],0x401008)
        self.assertEqual(hit['selected_bl_u8'],1)
        self.assertEqual(hit['number_meaning'],'not_tested')
        self.assertEqual(result['variable_scope_semantics'],'not_tested')

    def test_data_section_and_near_misses_are_not_dispatch_evidence(self):
        data=synthetic_pe();data[520:531]=b'\x81\x7d\xd0svar\x75\x02\xb3\x01'
        section=0x98+224;struct.pack_into('<I',data,section+36,0x40000040)
        self.assertEqual(selector_patterns(data,pe32(data)),[])
        struct.pack_into('<I',data,section+36,0x60000020)
        data[527]=0x74
        self.assertEqual(selector_patterns(data,pe32(data)),[])

    def test_truncation_and_invalid_header_pointer_fail(self):
        data=synthetic_pe()
        for truncated in [bytes(data[:63]),bytes(data[:0x98+223]),bytes(data[:700])]:
            with self.subTest(size=len(truncated)),self.assertRaises(ProbeError):pe32(truncated)
        struct.pack_into('<I',data,60,0xffffffff)
        with self.assertRaises(ProbeError):pe32(data)

    def test_section_range_and_rva_overflow_fail(self):
        data=synthetic_pe();section=0x98+224
        struct.pack_into('<I',data,section+20,1020)
        with self.assertRaises(ProbeError):pe32(data)
        data=synthetic_pe();struct.pack_into('<I',data,section+12,0xffffff80)
        with self.assertRaises(ProbeError):pe32(data)

    def test_unmapped_and_negative_offsets_are_explicit(self):
        pe=pe32(synthetic_pe())
        self.assertIsNone(locate(pe,511)['va'])
        self.assertIsNone(locate(pe,1023,2)['va'])
        with self.assertRaises(ProbeError):locate(pe,-1)


class SemanticEvidenceTests(unittest.TestCase):
    def test_nested_block_model_is_only_hypothesis(self):
        doc=document('\\if,1\\then\n\\for\n\\case,2\n\\end\\end\\else\\end\n')
        result=core_contracts([doc]);model=result['block_hypothesis']
        self.assertEqual(model['paired_blocks'],3)
        self.assertEqual(model['maximum_depth'],3)
        self.assertEqual(model['zero_operand_for'],1)
        self.assertEqual(model['status'],'inferred')
        self.assertEqual(result['execution_semantics'],'unsupported')
        self.assertTrue(all(not c['runtime_implemented'] for c in result['contracts']))

    def test_unmatched_end_and_open_block_are_reported(self):
        result=blocks(document('\\end\n\\if,1\n'))
        self.assertEqual(result['status'],'unsupported')
        self.assertEqual({i['category'] for i in result['issues']},{'unpaired_end','unclosed_candidate_block'})

    def test_then_requires_top_if_and_label_crossing_is_preserved(self):
        result=blocks(document('\\if,1\n@@Cross\n\\for\n\\then\n\\end\\end\n'))
        self.assertEqual(len(result['label_crossings']),1)
        self.assertEqual(result['issues'][0]['category'],'then_without_top_if')

    def test_if_without_then_and_one_operand_ret_are_not_normalized_away(self):
        result=core_contracts([document('\\if,1\n\\end\n\\ret,7\n')])
        self.assertEqual(result['block_hypothesis']['if_without_then'],1)
        ret=next(c for c in result['contracts'] if c['token']=='ret')
        self.assertEqual(ret['observed_arity_counts'],{1:1})
        self.assertEqual(ret['semantic_contract'],'inferred')

    def test_registers_in_strings_are_not_code_and_dynamic_indices_are_hashed(self):
        refs,unclosed=parameter_footprints('ParamInt[2]+"ParamStr[3]"+ResultInt[index+1]')
        self.assertFalse(unclosed)
        self.assertEqual([r['register'] for r in refs],['ParamInt','ResultInt'])
        self.assertEqual(refs[0]['index'],2)
        self.assertIsNone(refs[1]['index'])
        self.assertEqual(refs[1]['dynamic_index_sha256'],digest(b'index+1'))
        self.assertTrue(parameter_footprints('"unclosed')[1])

    def test_assignment_candidate_does_not_evaluate_expression(self):
        self.assertEqual(assignment_target('#value += 3'),'#value')
        self.assertIsNone(assignment_target('#value == 3'))
        self.assertIsNone(assignment_target('"#secret=3"'))
        self.assertTrue(assignment_target('#array[2]++').startswith('sha256:'))

    def test_object_selector_does_not_cross_lines(self):
        doc=document('\\scp,dat\\s,"first"\n\\s,"second"\n','synthetic.pack/saveload.s')
        report=save_boundaries([doc],{'files':[]})
        self.assertEqual([r['same_line_selector'] for r in report['operations']],['dat',None])
        self.assertEqual(report['slot_save_schema'],'not_tested')

    def test_diff_span_offsets_are_utf16_bytes_and_insertion_can_be_empty(self):
        doc=document('@@Top\n\\ret\n')
        span=range_evidence(doc,2,3)
        self.assertEqual(doc['_bytes'][span['byte_offset']:span['byte_offset']+span['byte_length']],'\\ret\n'.encode('utf-16-le'))
        self.assertEqual(range_evidence(doc,3,3)['byte_length'],0)
        with self.assertRaises(ProbeError):range_evidence(doc,0,2)

    def test_public_projection_does_not_leak_dialogue_or_operands(self):
        secret='合成秘密テキスト'
        report=public_contract(core_contracts([document('\\sub,@@Fn,"'+secret+'"\n\\cal,#a="'+secret+'"\n')]))
        text=json.dumps(report,ensure_ascii=False)
        self.assertNotIn(secret,text)
        self.assertNotIn('"raw":',text)
        self.assertEqual(report['transfer_spelling_records_count'],1)

    def test_header_without_game_directory_is_not_tested(self):
        inventory={'files':[{'path':'SystemData.dat','size':100,'extension':'.dat'},
                            {'path':'other.dat','size':99,'extension':'.dat'}]}
        report=save_boundaries([],inventory)
        self.assertEqual(report['save_header_candidates'][0]['status'],'not_tested')
        self.assertEqual(len(report['excluded_dat_files']),1)
        self.assertFalse(report['save_files_written'])

    def test_ir_identity_and_record_tampering_fail(self):
        doc=document('\\ret\n');data=doc.pop('_bytes')
        corpus={'items':[{'source_file':doc['source_file'],'sha256':digest(data),'logical_path':'test.s'}]}
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp).resolve();assets=root/'assets';ir=root/'ir';name=doc['source_file']
            (assets/name).parent.mkdir(parents=True);(assets/name).write_bytes(data)
            (ir/(name+'.json')).parent.mkdir(parents=True)
            p=ir/(name+'.json');p.write_text(json.dumps(doc))
            self.assertEqual(len(load_documents(corpus,assets,ir)),1)
            changed=copy.deepcopy(doc);changed['records'][0]['raw_bytes_reference']['sha256']='0'*64
            p.write_text(json.dumps(changed))
            with self.assertRaises(ProbeError):load_documents(corpus,assets,ir)
            changed=copy.deepcopy(doc);changed['source_file']='wrong.s';p.write_text(json.dumps(changed))
            with self.assertRaises(ProbeError):load_documents(corpus,assets,ir)


class NativeEvidenceTests(unittest.TestCase):
    def test_nonstatic_operations_and_duplicate_names_are_refused(self):
        q=dict(name='example',operation='procedure_assembly',address='0x401000')
        self.assertEqual(validate_plan(dict(schema_version=1,queries=[q])),[q])
        for rows in [[dict(q,operation='launch_binary')],[q,q],
                     [dict(q,name='../outside')],[dict(q,address='0x100000000')]]:
            with self.subTest(rows=rows),self.assertRaises(ProbeError):
                validate_plan(dict(schema_version=1,queries=rows))

    def test_rpc_failure_or_bad_json_is_not_success(self):
        self.assertEqual(unpack({'content':[dict(type='text',text='{"result":null}')]}),{'result':None})
        for value in [{'isError':True},{'structuredContent':{'error':'bad','code':'invalid_request'}},
                      {'content':[]},{'structuredContent':[]}]:
            with self.subTest(value=value),self.assertRaises(ProbeError):unpack(value)

    def test_evidence_requires_exact_binary_provider_operation_and_selector(self):
        d=dict(subject=dict(digest=dict(sha256='a'*64)),provider=dict(id='ghidra',version='12.1.4'),
               operation='procedure_assembly',normalized_result='instruction',evidence_id='synthetic',
               parameters={'procedure':'0x401000'})
        self.assertEqual(checked_evidence(d,'a'*64,'procedure_assembly','0x401000')['status'],'verified')
        for changed in [dict(d,subject={}),dict(d,provider={'id':'other'}),dict(d,operation='other'),
                        dict(d,normalized_result=None),dict(d,parameters={'procedure':'0x402000'})]:
            with self.subTest(changed=changed),self.assertRaises(ProbeError):
                checked_evidence(changed,'a'*64,'procedure_assembly','0x401000')

    def test_missing_anchor_fails_and_hypothesis_is_never_promoted(self):
        spec=dict(id='test',status='inferred',evidence='synthetic',observation='Hypothesis',anchors=['TEST'])
        self.assertEqual(evaluate_fact(spec,{'normalized_result':'TEST'},'synthetic','a'*64)['status'],'inferred')
        failed=evaluate_fact(spec,{'normalized_result':'other'},'synthetic','a'*64)
        self.assertEqual(failed['status'],'unsupported')
        self.assertEqual(failed['missing_anchor_count'],1)


if __name__=='__main__':unittest.main()
