"""Synthetic precedence and native-window tests; no commercial fixtures."""
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.native_windows import validate_windows, window_reference
from tools.pe_probe import pe32
from tools.p1_resolution import conditional_choice, overlay_model, tail_observation
from tools.rea_static import checked_evidence, validate_plan
from tests.test_semantic_evidence import synthetic_pe


def variant(slot,source=None,archive=None):
    return dict(source_file=source or ('data'+str(slot)+'.pack/test.s'),sha256='a'*64,
        origin=dict(archive=archive or ('GameData/data'+str(slot)+'.pack'),archive_sha256='b'*64,index=1))


class ConditionalOverlayTests(unittest.TestCase):
    def test_numeric_descending_slots_are_not_lexical_archive_sort(self):
        result=conditional_choice([variant(9),variant(10),variant(2)])
        self.assertEqual([v['slot'] for v in result['candidates']],[10,9,2])
        self.assertEqual(result['conditional_winner']['slot'],10)
        self.assertEqual(result['effective_runtime_winner'],'not_tested')
        self.assertEqual(result['status'],'inferred')

    def test_preconditions_are_not_silently_verified(self):
        result=conditional_choice([variant(8)])
        self.assertEqual(result['preconditions']['no_matching_loose_file'],'not_tested')
        self.assertEqual(result['preconditions']['secondary_mounts'],'not_tested')
        self.assertEqual(result['preconditions']['mapping'],'inferred')

    def test_loose_file_candidate_blocks_pack_winner(self):
        result=conditional_choice([variant(8)],loose_present=True)
        self.assertIsNone(result['conditional_winner'])
        self.assertEqual(result['status'],'unsupported')

    def test_restricted_slot_does_not_use_higher_slot(self):
        result=conditional_choice([variant(7),variant(8)],restricted_slot=7)
        self.assertEqual(result['conditional_winner']['slot'],7)
        self.assertIsNone(conditional_choice([variant(8)],restricted_slot=7)['conditional_winner'])
        for slot in [-1,32]:
            with self.subTest(slot=slot),self.assertRaises(ProbeError):conditional_choice([variant(8)],restricted_slot=slot)

    def test_duplicate_slot_or_unknown_archive_remains_unresolved(self):
        for variants in [[variant(8),variant(8,source='other.pack/test.s')],
                         [variant(8),variant(99)],
                         [variant(8,archive='other/data8.pack')]]:
            with self.subTest(variants=variants):
                r=conditional_choice(variants)
                self.assertIsNone(r['conditional_winner']);self.assertTrue(r['unknown'])

    def test_model_retains_all_variants_and_marks_changed_groups(self):
        a=variant(7);b=variant(8)
        for item in [a,b]:item['logical_path']='test.s'
        r=overlay_model({'items':[a,b]},{'test.s'})
        self.assertEqual(r['logical_paths'],1);self.assertEqual(r['files'],2)
        self.assertEqual(r['items'][0]['variant_count'],2)
        self.assertTrue(r['items'][0]['changed_duplicate'])
        self.assertFalse(r['source_variants_deleted'])


class NativeWindowTests(unittest.TestCase):
    def test_missing_function_tail_is_observed_without_mutating_provider(self):
        provider=dict(subject={'digest':{'sha256':'a'*64}},normalized_result='0x401000: RET',evidence_id='synthetic-provider')
        window=dict(source_sha256='a'*64,source_file='synthetic',evidence_id='synthetic-window',
            normalized_result='  401002: 8b c3    mov eax, ebx\n')
        observation=tail_observation(provider,window,0x401002)
        self.assertTrue(observation['omitted_from_provider_instructions'])
        self.assertEqual(observation['instruction_byte_length'],2)
        self.assertEqual(provider['normalized_result'],'0x401000: RET')
        self.assertEqual(tail_observation(provider,window,0x401008)['status'],'unsupported')
        with self.assertRaises(ProbeError):tail_observation(provider,dict(window,source_sha256='b'*64),0x401002)

    def test_file_backed_window_offsets_and_size_bounds(self):
        pe=pe32(synthetic_pe())
        self.assertEqual(window_reference(pe,0x401008,0x401020),{'offset':520,'length':24})
        for start,end in [(0x401000,0x401000),(0x401000,0x403001),(0x400fff,0x401001),
                          (0x4011ff,0x401201),(-1,10)]:
            with self.subTest(start=start,end=end),self.assertRaises(ProbeError):window_reference(pe,start,end)

    def test_nonexecutable_and_duplicate_windows_refused(self):
        pe=pe32(synthetic_pe());row={'name':'test','start':'0x401000','end_exclusive':'0x401010'}
        self.assertEqual(len(validate_windows(pe,[row])),1)
        for rows in [[row,row],[dict(row,name='../escape')],[]]:
            with self.subTest(rows=rows),self.assertRaises(ProbeError):validate_windows(pe,rows)
        pe['sections'][0]['executable']=False
        with self.assertRaises(ProbeError):window_reference(pe,0x401000,0x401010)

    def test_static_reference_queries_and_negative_coverage_are_distinct(self):
        q=dict(name='instruction',operation='inspect_native_instruction',address='0x401000')
        self.assertEqual(validate_plan(dict(schema_version=1,queries=[q])),[q])
        record=dict(subject=dict(digest=dict(sha256='a'*64)),provider=dict(id='ghidra',version='12.1.4'),
            evidence_id='synthetic',operation=q['operation'],parameters={'address':q['address']},
            normalized_result={'status':'undecodable'})
        observation=checked_evidence(record,'a'*64,q['operation'],q['address'])
        self.assertEqual(observation['status'],'verified')
        self.assertEqual(observation['observation_support'],'unsupported')
        record.update(operation='xrefs',normalized_result=[])
        self.assertEqual(checked_evidence(record,'a'*64,'xrefs',q['address'])['status'],'verified')
        record['normalized_result']={}
        with self.assertRaises(ProbeError):checked_evidence(record,'a'*64,'xrefs',q['address'])


if __name__=='__main__':unittest.main()
