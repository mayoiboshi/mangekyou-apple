"""Owned encoding/PE fixtures; no Windows decoder or commercial-engine oracle."""
from copy import deepcopy
import hashlib
import tempfile
from pathlib import Path
import struct
import unittest
from unittest.mock import patch

from tools.encoding_audit import audit_text, prefix_profile, compare_variants, audit_corpus, minimal_class, bind_import, reference, constructor_arguments
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tools.research_checks import forbidden_content_fields
from tests.test_delphi_metadata import fixture


class EncodingAuditTests(unittest.TestCase):
    def test_cp932_and_cp936_can_both_accept_different_text(self):
        r = audit_text('own=字\r\n'.encode('cp932'), 'owned.txt')
        self.assertTrue(r['cp932_cp936_both_accept'])
        self.assertTrue(r['cp932_cp936_disagree'])
        self.assertEqual(r['research_model_codec_status'], 'inferred')
        self.assertEqual(r['actual_windows_codepage'], 'not_tested')
        self.assertEqual(r['runtime_decoding'], 'not_tested')
        self.assertFalse(forbidden_content_fields(r))
        self.assertNotIn('own=', str(r))
        self.assertNotIn('字', str(r))

    def test_matching_bom_only_is_removed_for_each_codec(self):
        for marker, codec in [(b'\xff\xfe', 'utf-16-le'), (b'\xfe\xff', 'utf-16-be'), (b'\xef\xbb\xbf', 'utf-8')]:
            with self.subTest(codec=codec):
                data = marker+'Owned😀\r\n'.encode(codec)
                r = audit_text(data, 'owned.txt')
                row = next(c for c in r['candidates'] if c['codec'] == codec)
                self.assertEqual(r['bom_codec'], codec)
                self.assertEqual(row['consumed_matching_bom_bytes'], len(marker))
                self.assertEqual(row['decoded_utf8_sha256'], hashlib.sha256('Owned😀\r\n'.encode()).hexdigest())
                self.assertEqual(row['scalar_count'], 8)

    def test_trial_decoding_never_changes_existing_research_codec(self):
        r = audit_text('é'.encode('utf-8'), 'owned.txt')
        self.assertEqual(r['research_model_codec'], 'cp932')
        self.assertEqual(next(c for c in r['candidates'] if c['codec'] == 'utf-8')['status'], 'verified')
        self.assertIsNone(r['bom_codec'])
        self.assertEqual(r['native_encoding_branch_candidate'], 'system_default_codepage')

    def test_partial_prefixes_and_utf32_prefix_are_not_falsely_certified(self):
        for data in [b'', b'\xff', b'\xef\xbb', b'\xfe']:
            self.assertEqual(prefix_profile(data), (None, 0))
        # The observed native prefix order recognizes FF FE first, not UTF-32.
        r = audit_text(b'\xff\xfe\x00\x00A\x00\x00\x00', 'owned.txt')
        self.assertEqual(r['bom_codec'], 'utf-16-le')
        self.assertGreater(next(c for c in r['candidates'] if c['codec'] == 'utf-16-le')['control_character_count'], 0)

    def test_bom_relative_decode_failures_point_to_original_bytes(self):
        data = b'\xff\xfeA\x00\x01'
        r = audit_text(data, 'owned.txt')
        self.assertEqual(r['status'], 'unsupported')
        ref = next(c for c in r['candidates'] if c['codec'] == 'utf-16-le')['failure_reference']
        self.assertEqual((ref['offset'], ref['length']), (4, 1))
        self.assertEqual(ref['sha256'], hashlib.sha256(data[4:5]).hexdigest())
        self.assertEqual(ref['source_sha256'], hashlib.sha256(data).hexdigest())

    def test_invalid_surrogate_is_explicit_and_not_replaced(self):
        r = audit_text(b'\xff\xfe\x00\xd8', 'owned.txt')
        self.assertEqual(r['research_model_decode_status'], 'unsupported')
        row = next(c for c in r['candidates'] if c['codec'] == 'utf-16-le')
        self.assertNotIn('decoded_utf8_sha256', row)
        self.assertEqual(row['failure_reference']['length'], 2)

    def test_comparison_preserves_line_endings_and_unicode_scalar_distinctions(self):
        cases = [('A\r\n', 'A\n'), ('É', 'E\u0301'), ('A', 'a')]
        for left, right in cases:
            with self.subTest(left=repr(left), right=repr(right)):
                rows = [audit_text(b'\xef\xbb\xbf'+s.encode(), n) for s, n in [(left, 'left.txt'), (right, 'right.txt')]]
                for r in rows:
                    r['logical_path'] = 'owned.txt'
                g = compare_variants(rows)[0]
                self.assertFalse(g['exact_decoded_scalars_equal'])
                self.assertEqual(g['original_behavioral_equivalence'], 'not_tested')

    def test_matching_model_text_does_not_choose_between_encoded_sources(self):
        rows = [audit_text('owned=字\r\n'.encode('cp932'), 'a.txt'),
                audit_text(b'\xff\xfe'+'owned=字\r\n'.encode('utf-16-le'), 'b.txt')]
        for row in rows:
            row['logical_path'] = 'owned.txt'
        g = compare_variants(rows)[0]
        self.assertTrue(g['exact_decoded_scalars_equal'])
        self.assertFalse(g['raw_bytes_equal'])
        self.assertEqual(len(g['variants']), 2)
        self.assertEqual(g['actual_package_winner'], 'not_tested')

    def test_corpus_identity_failure_and_symlink_are_reported_per_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            data = b'owned=1\n'
            (root/'one.txt').write_bytes(data)
            item = dict(source_file='one.txt', logical_path='one.txt', sha256=hashlib.sha256(data).hexdigest(), encoding='cp932')
            okay = audit_corpus(root, [item])
            self.assertEqual(okay['physical_files'], 1)
            self.assertEqual((root/'one.txt').read_bytes(), data)
            failed = audit_corpus(root, [dict(item, sha256='0'*64)])
            self.assertEqual(failed['rows'][0]['unknown_reason'], 'encoding_source_digest_mismatch')
            (root/'alias.txt').symlink_to(root/'one.txt')
            failed = audit_corpus(root, [dict(item, source_file='alias.txt')])
            self.assertEqual(failed['status'], 'unsupported')
            self.assertEqual(failed['rows'][0]['research_model_decode_status'], 'unsupported')
            self.assertFalse(forbidden_content_fields(failed))

    def test_corpus_selection_and_catalog_limits_are_checked(self):
        item = dict(source_file='one.txt', logical_path='one.txt', sha256='0'*64, encoding='cp932')
        for items, selected in [([], None), ([item, item], None), ([item], []),
                                ([item], ['one.txt', 'one.txt']), ([item], ['../escape.txt']), ([item], ['missing.txt'])]:
            with self.subTest(selected=selected), self.assertRaises(ProbeError):
                audit_corpus(Path('/unused'), items, selected)

    def test_file_and_total_bytes_are_bounded_before_more_decoding(self):
        with patch('tools.encoding_audit.MAX_FILE_BYTES', 2), self.assertRaises(ProbeError):
            audit_text(b'abc', 'owned.txt')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root/'owned.txt').write_bytes(b'abc')
            item = dict(source_file='owned.txt', logical_path='owned.txt', encoding='cp932', sha256=hashlib.sha256(b'abc').hexdigest())
            with patch('tools.encoding_audit.MAX_TOTAL_BYTES', 2), self.assertRaises(ProbeError):
                audit_corpus(root, [item])

    def test_catalog_encoding_disagreement_is_not_silently_relabelled(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            (root/'owned.txt').write_bytes(b'abc')
            item = dict(source_file='owned.txt', logical_path='owned.txt', encoding='utf-8', sha256=hashlib.sha256(b'abc').hexdigest())
            r = audit_corpus(root, [item])
            self.assertEqual(r['status'], 'unsupported')
            self.assertEqual(r['rows'][0]['unknown_reason'], 'encoding_corpus_label_mismatch')

    def test_failed_variant_comparison_cannot_claim_equality(self):
        valid = audit_text(b'abc', 'one.txt')
        invalid = audit_text(b'\xff\xfe\x00', 'two.txt')
        valid['logical_path'] = invalid['logical_path'] = 'owned.txt'
        row = compare_variants([valid, invalid])[0]
        self.assertEqual(row['status'], 'unsupported')
        self.assertIsNone(row['exact_decoded_scalars_equal'])

    def test_minimal_class_preserves_absent_extended_fields_without_inventing_layout(self):
        data, _, u32 = fixture()
        u32(0x401100-68, 0)
        r = minimal_class(Image(data), 0x401100, 'ToyRoutine', [(12, 0x401020)])
        self.assertFalse(r['extended_field_table_present'])
        self.assertEqual(r['complete_layout'], 'not_tested')
        self.assertEqual(r['actual_dispatch'], 'not_tested')
        with self.assertRaises(ProbeError):
            minimal_class(Image(data), 0x401100, 'WrongName', [])
        with self.assertRaises(ProbeError):
            minimal_class(Image(data), 0x401100, 'ToyRoutine', [(12, 0x401030)])

    def import_fixture(self):
        data, put, u32 = fixture()
        put(0x401020, b'\xff\x25'+struct.pack('<I', 0x401700))
        u32(0x401700, 0x1750)
        put(0x401750, b'\x00\x00OwnedAPI\x00')
        put(0x401790, b'kernel32.dll\x00')
        proof = dict(operation='inspect_pe_imports', provider=dict(id='rea-pe-imports'),
            subject=dict(digest=dict(sha256=hashlib.sha256(data).hexdigest())),
            normalized_result=dict(imports=[dict(name='kernel32.dll', name_rva=0x1790,
                functions=[dict(name='OwnedAPI', iat_rva=0x1700, thunk_hex='1750')])]))
        return data, proof

    def test_import_binding_checks_exact_slot_name_and_source_bytes(self):
        data, proof = self.import_fixture()
        r = bind_import(Image(data), proof, 'OwnedAPI', 0x401020, 0x401700)
        self.assertEqual(r['status'], 'verified')
        self.assertEqual(r['execution'], 'not_tested')
        for k in ['thunk_reference', 'iat_reference', 'name_reference', 'dll_reference']:
            ref = r[k]
            self.assertEqual(ref['sha256'], hashlib.sha256(data[ref['offset']:ref['offset']+ref['length']]).hexdigest())

    def test_import_binding_rejects_wrong_source_duplicates_and_pointer_tampering(self):
        data, proof = self.import_fixture()
        wrong = deepcopy(proof)
        wrong['subject']['digest']['sha256'] = '0'*64
        duplicate = deepcopy(proof)
        duplicate['normalized_result']['imports'] *= 2
        for record in [wrong, duplicate]:
            with self.assertRaises(ProbeError):
                bind_import(Image(data), record, 'OwnedAPI', 0x401020, 0x401700)
        data[512+0x20] = 0x90
        proof['subject']['digest']['sha256'] = hashlib.sha256(data).hexdigest()
        with self.assertRaises(ProbeError):
            bind_import(Image(data), proof, 'OwnedAPI', 0x401020, 0x401700)

    def test_reference_rejects_traversal_and_invalid_ranges(self):
        for source, start, size in [('../owned', 0, 1), ('owned', -1, 1), ('owned', 0, 4), ('owned', 1, -1)]:
            with self.assertRaises(ProbeError):
                reference(b'abc', source, start, size)

    def test_x86_earlier_push_maps_to_decode_flag_not_last_push(self):
        data, put, _ = fixture()
        put(0x401020, b'\x6a\x08\x6a\x00\xb9'+struct.pack('<I', 65001))
        r = constructor_arguments(Image(data), 0x401020, 0x401022, 0x401024)
        self.assertEqual(r['codepage_argument'], 65001)
        self.assertEqual(r['decode_flags_argument'], 8)
        self.assertEqual(r['encode_flags_argument'], 0)
        self.assertEqual(r['status'], 'inferred')
        put(0x401020, b'\x6a\x00\x6a\x00\x33\xc9')
        r = constructor_arguments(Image(data), 0x401020, 0x401022, 0x401024)
        self.assertEqual((r['codepage_argument'], r['decode_flags_argument'], r['encode_flags_argument']), (0, 0, 0))

    def test_unreviewed_constructor_instruction_forms_are_rejected(self):
        for raw in [b'\x6a\xff\x6a\x00\x33\xc9', b'\x90\x08\x6a\x00\x33\xc9', b'\x6a\x08\x6a\x00\x33\xc0']:
            data, put, _ = fixture()
            put(0x401020, raw)
            with self.subTest(raw=raw.hex()), self.assertRaises(ProbeError):
                constructor_arguments(Image(data), 0x401020, 0x401022, 0x401024)


if __name__ == '__main__':
    unittest.main()
