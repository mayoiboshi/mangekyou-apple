"""Synthetic metadata comparison safeguards; no game or Ghidra dependency."""
import copy
import json
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.ghidra_tail_probe import model_recovery, summary, validate_result
from tools.command_ids import identifier_candidate


def comparison():
    return dict(status='verified',source_sha256='a'*64,program_bytes_patched=False,target_executed=False,
        functions=[dict(name='synthetic',status='verified',memory_unchanged=True,
            source_memory_sha256='b'*64,memory_sha256_after='b'*64,
            baseline={'status':'verified','pseudocode':'void synthetic(void) { return; }'},
            variant={'status':'verified','pseudocode':'int synthetic(void) { return 4660; }'})])


class TailProbeTests(unittest.TestCase):
    def test_ascii_case_and_truncation_are_explicit_collision_candidates(self):
        self.assertEqual(identifier_candidate('SuB')['identifier_hex'],'0x00627573')
        self.assertEqual(identifier_candidate('sub')['identifier_hex'],identifier_candidate('SuB')['identifier_hex'])
        a=identifier_candidate('abcde');b=identifier_candidate('abcdx')
        self.assertEqual(a['identifier_hex'],b['identifier_hex'])
        self.assertTrue(a['truncated']);self.assertEqual(a['truncated_character_count'],1)
        self.assertEqual(a['dispatch_meaning'],'not_tested')

    def test_nonascii_command_names_are_not_silently_casefolded(self):
        for text in ['','İf','日本','😀']:
            with self.subTest(text=text):self.assertEqual(identifier_candidate(text)['status'],'unsupported')
        self.assertEqual(identifier_candidate('?sfs')['identifier_hex'],'0x7366733f')

    def test_public_projection_preserves_digests_but_not_full_code(self):
        raw=comparison();raw['functions'][0]['variant']['pseudocode']='int x(void) { /* 合成秘密 */ return 7; }'
        public=summary(raw);text=json.dumps(public,ensure_ascii=False)
        self.assertNotIn('合成秘密',text);self.assertNotIn('return 7',text)
        self.assertIn('pseudocode_sha256',text)
        self.assertTrue(public['functions'][0]['variant']['has_value_return'])

    def test_completion_with_unknown_indirect_flow_is_not_recovery(self):
        raw=comparison();self.assertEqual(model_recovery(raw),'verified')
        raw['functions'][0]['variant']['pseudocode']='int synthetic(void) { UNRECOVERED_JUMPTABLE(); return 7; }'
        self.assertEqual(model_recovery(raw),'unsupported')

    def test_void_return_or_no_functions_is_not_recovery(self):
        raw=comparison();raw['functions'][0]['variant']['pseudocode']='void synthetic(void) { return; }'
        self.assertEqual(model_recovery(raw),'unsupported')
        self.assertEqual(model_recovery({'functions':[]}),'unsupported')

    def test_memory_and_scope_mismatches_are_refused(self):
        raw=comparison();validate_result(raw,'a'*64,['synthetic'])
        for mutation in ['digest','flag','executed','patched']:
            changed=copy.deepcopy(raw)
            if mutation=='digest':changed['functions'][0]['memory_sha256_after']='c'*64
            if mutation=='flag':changed['functions'][0]['memory_unchanged']=False
            if mutation=='executed':changed['target_executed']=True
            if mutation=='patched':changed['program_bytes_patched']=True
            with self.subTest(mutation=mutation),self.assertRaises(ProbeError):validate_result(changed,'a'*64,['synthetic'])

    def test_identity_function_set_and_partial_decompilation_are_refused(self):
        raw=comparison()
        with self.assertRaises(ProbeError):validate_result(raw,'b'*64,['synthetic'])
        with self.assertRaises(ProbeError):validate_result(raw,'a'*64,['missing'])
        raw['functions'][0]['variant']['status']='unsupported'
        with self.assertRaises(ProbeError):validate_result(raw,'a'*64,['synthetic'])

    def test_success_flag_cannot_hide_empty_pseudocode(self):
        raw=comparison();raw['functions'][0]['variant']['pseudocode']=''
        with self.assertRaises(ProbeError):validate_result(raw,'a'*64,['synthetic'])


if __name__=='__main__':unittest.main()
