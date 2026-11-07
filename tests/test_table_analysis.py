"""Owned text fixtures only; static projections are not original-engine tests."""
import hashlib
import json
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools.mangekyou_p0 import ProbeError
from tools.research_checks import forbidden_content_fields
from tools.table_analysis import table_text, lexical_sites, analyze_corpus, key_links, main, MAX_TABLE_BYTES


class TableAnalysisTests(unittest.TestCase):
    def test_first_duplicate_value_is_selected_before_slash_filter(self):
        r = table_text(b'Key=bad//owned\r\nkey=good\r\n', 'owned.txt')
        self.assertEqual(r['candidate_counts'], {'rejected_slash_candidate': 2})
        self.assertTrue(r['lines'][1]['duplicate_ascii_name'])
        self.assertEqual(r['lines'][1]['selected_line_reference']['offset'], 0)
        self.assertEqual(r['lines'][1]['source_value_sha256'], hashlib.sha256(b'good').hexdigest())
        self.assertEqual(r['lines'][1]['selected_value_sha256'], hashlib.sha256(b'bad//owned').hexdigest())
        self.assertEqual(r['lines'][1]['status'], 'inferred')

    def test_marker_empty_and_missing_name_are_not_collapsed_to_stored_count(self):
        r = table_text(b'a=%%none%%\nb=\n=emptyName\nnoSeparator\n\n', 'owned.txt')
        self.assertEqual(r['candidate_counts'], dict(empty_marker_candidate=1,
            empty_value_candidate=1, empty_name=1, no_separator=1, blank=1))
        self.assertEqual(r['stored_entry_count'], 'not_tested')
        self.assertEqual(r['query_results'], 'not_tested')

    def test_whitespace_and_extra_equals_are_preserved(self):
        r = table_text(b' key = first=second \n', 'owned.txt')['lines'][0]
        self.assertTrue(r['outer_name_whitespace'])
        self.assertTrue(r['outer_value_whitespace'])
        self.assertEqual(r['name_sha256'], hashlib.sha256(b' key ').hexdigest())
        self.assertEqual(r['selected_value_sha256'], hashlib.sha256(b' first=second ').hexdigest())

    def test_slash_anywhere_in_either_field_rejects_whole_pair_candidate(self):
        r = table_text(b'a//b=c\nx=https://example.invalid/owned\ny=/single\n', 'owned.txt')
        self.assertEqual(r['candidate_counts'], dict(rejected_slash_candidate=2, value_candidate=1))

    def test_cp932_and_utf16_references_recover_exact_source_ranges(self):
        for data in ['own=字\r\nlast=終'.encode('cp932'), b'\xff\xfe'+'own=字😀\r\nlast=終'.encode('utf-16-le')]:
            with self.subTest(sha=hashlib.sha256(data).hexdigest()):
                r = table_text(data, 'owned.txt')
                self.assertEqual(r['physical_lines'], 2)
                for row in r['lines']:
                    ref = row['raw_bytes_reference']
                    self.assertEqual(ref['source_file'], 'owned.txt')
                    self.assertEqual(ref['source_sha256'], hashlib.sha256(data).hexdigest())
                    self.assertEqual(ref['sha256'], hashlib.sha256(data[ref['offset']:ref['offset']+ref['length']]).hexdigest())
                self.assertFalse(forbidden_content_fields(r))
                self.assertNotIn('字', json.dumps(r, ensure_ascii=False))

    def test_non_ascii_name_is_explicitly_unsupported_without_discarding_other_rows(self):
        r = table_text('鍵=own\na=ok\n'.encode('cp932'), 'owned.txt')
        self.assertEqual(r['status'], 'unsupported')
        self.assertEqual(r['lines'][0]['candidate_disposition'], 'unresolved_non_ascii_name')
        self.assertEqual(r['lines'][1]['candidate_disposition'], 'value_candidate')

    def test_invalid_encoding_bare_cr_and_bounds_are_rejected_or_reported(self):
        with self.assertRaises((UnicodeError, ProbeError)):
            table_text(b'\xff\xfe\x01', 'owned.txt')
        self.assertEqual(table_text(b'a=1\rb=2', 'owned.txt')['lines'][0]['status'], 'unsupported')
        for data in [b'x'*(MAX_TABLE_BYTES+1), b'a='+b'x'*8192]:
            with self.assertRaises(ProbeError):
                table_text(data, 'owned.txt')
        with patch('tools.table_analysis.MAX_TABLE_LINES', 1), self.assertRaises(ProbeError):
            table_text(b'a=1\nb=2\n', 'owned.txt')

    def test_all_variants_remain_and_script_fields_are_redacted(self):
        items = [dict(source_file=f'pack{i}/own.txt', logical_path='own.txt', sha256=str(i)*64) for i in [1, 2]]
        data = b'\\var,table,secretTable\n\\scp,secretTable\n\\l,"own.txt"\n\\?v,"secretKey","secretDefault"'
        rows = lexical_sites(data, 'owned.s', items)
        load = next(r for r in rows if r['command'] == 'l')
        self.assertEqual(len(load['declaration_candidates']), 1)
        self.assertEqual(len(load['resource_candidates']), 2)
        self.assertEqual(load['differing_variant_count'], 2)
        self.assertEqual(load['reference_type'], 'Unknown')
        self.assertEqual(rows[-1]['default_field_shape'], 'string_literal')
        self.assertNotIn('secret', json.dumps(rows))
        self.assertFalse(forbidden_content_fields(rows))

    def test_control_flow_barrier_removes_scope_hint_and_keeps_unbound_commands(self):
        rows = lexical_sites(b'\\var,table,owned\n\\scp,owned\n\\sub,@@Other\n\\l,"own.txt"\n', 'owned.s', [])
        self.assertEqual(rows[-1]['declaration_candidates'], [])
        self.assertEqual(rows[-1]['status'], 'unsupported')

    def test_key_links_preserve_all_versions_and_both_script_and_table_bytes(self):
        data = b'\\var,table,owned\n\\scp,owned\n\\l,"own.txt"\n\\?v,"Key","privateDefault"'
        tables = [table_text(b'Key=privateFirst\nkey=privateSecond\n', 'p1/own.txt'),
                  table_text(b'KEY=privatePatch\n', 'p2/own.txt')]
        items = [dict(source_file=r['source_file'], sha256=r['source_sha256'], logical_path='own.txt') for r in tables]
        sites = lexical_sites(data, 'owned.s', items)
        links = key_links(sites, tables)
        self.assertEqual(len(links), 2)
        for link in links:
            self.assertEqual(link['status'], 'inferred')
            self.assertEqual(link['query_reference']['source_file'], 'owned.s')
            self.assertEqual(link['load_reference']['source_file'], 'owned.s')
            self.assertEqual(len(link['candidate_line_references']), 1)
            self.assertEqual(link['candidate_line_references'][0]['offset'], 0)
            self.assertEqual(link['actual_query'], 'not_tested')
        self.assertNotIn('private', json.dumps(links))
        self.assertFalse(forbidden_content_fields(links))

    def test_unresolved_key_load_and_missing_scope_each_have_explicit_link(self):
        for script in [b'\\?v,"noScope"',
                       b'\\var,table,owned\n\\scp,owned\n\\l,"missing.txt"\n\\?v,"key"']:
            links = key_links(lexical_sites(script, 'owned.s', []), [])
            self.assertEqual(len(links), 1)
            self.assertEqual(links[0]['status'], 'unsupported')
            self.assertIn('unknown_reason', links[0])

    def test_dynamic_unsafe_missing_and_non_ascii_resource_names_stay_unknown(self):
        for field in ['#dynamic', '"../escape.txt"', '"/absolute.txt"', '"missing.txt"', '"字.txt"']:
            rows = lexical_sites(('\\l,'+field).encode('cp932'), 'owned.s', [])
            self.assertEqual(rows[0]['status'], 'unsupported')
            self.assertEqual(rows[0]['resource_candidates'], [])
            self.assertIn('unknown_reason', rows[0])

    def test_corpus_digest_duplicates_symlinks_and_input_are_checked(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            script = b'\\var,table,owned\n\\scp,owned\n\\l,"own.txt"'
            table = b'a=1\n'
            (root/'owned.s').write_bytes(script)
            (root/'own.txt').write_bytes(table)
            items = [dict(source_file=n, logical_path=n, sha256=hashlib.sha256(d).hexdigest()) for n, d in [('owned.s', script), ('own.txt', table)]]
            r = analyze_corpus(root, items, ['owned.s'])
            self.assertEqual(r['table_text_count'], 1)
            self.assertEqual((root/'owned.s').read_bytes(), script)
            self.assertEqual((root/'own.txt').read_bytes(), table)
            self.assertEqual(r['execution_semantics'], 'not_tested')
            for bad_items, bad_scripts in [(items+items[:1], ['owned.s']), (items, ['owned.s', 'owned.s']),
                                           ([dict(items[0], sha256='0'*64), items[1]], ['owned.s']), (items, ['../owned.s'])]:
                with self.assertRaises(ProbeError):
                    analyze_corpus(root, bad_items, bad_scripts)
            (root/'alias.s').symlink_to(root/'owned.s')
            with self.assertRaises((OSError, ProbeError)):
                analyze_corpus(root, [dict(items[0], source_file='alias.s')], ['alias.s'])

    def test_cli_failure_creates_redacted_report_only_after_output_is_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve()
            output = root/'reports/p1/failed.json'
            args = ['table_analysis', '--game-dir', str(root/'game'), '--assets-dir', str(root/'assets'),
                '--exe', 'owned.exe', '--script-file', 'owned.s', '--output', str(output)]
            with patch('tools.table_analysis.ROOT', root), patch('sys.argv', args), redirect_stdout(io.StringIO()):
                self.assertEqual(main(), 2)
            report = json.loads(output.read_text())
            self.assertEqual(report['status'], 'unsupported')
            self.assertFalse(report['original_files_written'])
            self.assertNotIn(str(root), json.dumps(report))
            self.assertFalse(forbidden_content_fields(report))
            blocked = root/'game/reports/p1/no-write.json'
            # Use ROOT as input to exercise overlap refusal even for a workspace output.
            args[args.index('--game-dir')+1] = str(root)
            args[-1] = str(root/'reports/p1/no-write.json')
            with patch('tools.table_analysis.ROOT', root), patch('sys.argv', args), redirect_stdout(io.StringIO()):
                self.assertEqual(main(), 2)
            self.assertFalse((root/'reports/p1/no-write.json').exists())
            self.assertFalse(blocked.exists())


if __name__ == '__main__':
    unittest.main()
