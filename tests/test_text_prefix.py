"""Invented prefix snippets; no commercial scripts or expression execution."""
import json
from pathlib import Path
import tempfile
import unittest

from tools.text_prefix_analysis import literal_shape,setter_candidate,analyze_documents
from tools.qlie_lex import lex,digest
from tools.mangekyou_p0 import ProbeError


class PrefixShapeTests(unittest.TestCase):
    def test_literal_metadata_never_contains_payload_or_argument_text(self):
        r=literal_shape('"\\scp,privateObject\\m,privateDialogue"')
        self.assertEqual(r['command_token_candidates'],{'scp':1,'m':1})
        self.assertEqual(r['leading_category'],'backslash');self.assertEqual(r['status'],'inferred')
        self.assertNotIn('privateObject',json.dumps(r));self.assertNotIn('privateDialogue',json.dumps(r))
        self.assertEqual(r['execution_semantics'],'not_tested')

    def test_empty_literal_is_an_observation_not_an_executed_empty_pointer(self):
        r=literal_shape('""');self.assertEqual(r['leading_category'],'empty')
        self.assertEqual(r['character_count'],0);self.assertEqual(r['escaped_string_semantics'],'not_tested')

    def test_expressions_and_embedded_quotes_are_not_evaluated(self):
        for raw in ['Name','nil','"a"+"b"','"a""b"']:
            with self.subTest(raw=raw):
                r=literal_shape(raw);self.assertEqual(r['status'],'not_tested')
                self.assertNotIn('command_token_candidates',r);self.assertNotIn('character_count',r)

    def test_control_characters_and_oversized_fields_are_rejected_explicitly(self):
        for raw in ['"one\ntwo"','"one\0two"']:
            with self.subTest(raw=raw):self.assertEqual(literal_shape(raw)['status'],'unsupported')
        with self.assertRaises(ProbeError):literal_shape('x'*8193)

    def test_unbounded_command_spelling_is_hashed_instead_of_published(self):
        r=literal_shape('"\\privateSpelling,content"')
        self.assertEqual(r['status'],'unsupported');self.assertEqual(r['command_token_candidates'],{})
        self.assertEqual(sum(r['unknown_command_token_hashes'].values()),1)
        self.assertNotIn('privateSpelling',json.dumps(r));self.assertNotIn('content',json.dumps(r))

    def test_source_field_references_remain_exact_for_cp932_and_utf16(self):
        source='\\et,"\\m,例"'
        for data in [source.encode('cp932'),b'\xff\xfe'+source.encode('utf-16le')]:
            doc=lex(data,'invented.s');record=next(r for r in doc['records'] if r['record_type']=='command')
            result=setter_candidate(doc,record,'privateSelector',data)
            ref=result['parent_field_reference']['raw_bytes_reference'];part=data[ref['offset']:ref['offset']+ref['length']]
            self.assertEqual(ref['sha256'],digest(part));self.assertEqual(ref['source_sha256'],digest(data))
            self.assertEqual(result['namespace_binding'],'not_tested');self.assertNotIn('privateSelector',json.dumps(result))

    def test_wrong_arity_and_bad_field_span_never_become_setter_success(self):
        data=b'\\nt,"one","two"';doc=lex(data,'invented.s');r=doc['records'][0]
        self.assertEqual(setter_candidate(doc,r,None,data)['status'],'unsupported')
        data=b'\\et,"one"';doc=lex(data,'invented.s');r=doc['records'][0];r['operands'][0]['byte_length']=1000
        with self.assertRaises(ProbeError):setter_candidate(doc,r,None,data)

    def test_physical_versions_are_retained_and_all_source_hashes_checked(self):
        with tempfile.TemporaryDirectory() as root:
            assets=Path(root).resolve();data=b'\\scp,privateSelector\\et,"\\m,"';items=[]
            for name in ['one.txt','two.txt']:
                (assets/name).write_bytes(data);items.append(dict(source_file=name,sha256=digest(data)))
            rows,counts,files=analyze_documents(assets,items)
            self.assertEqual(counts,{'et':2});self.assertEqual(len(rows),2);self.assertEqual(len(files),2)
            self.assertNotIn('privateSelector',json.dumps(rows));items[1]['sha256']='0'*64
            with self.assertRaises(ProbeError):analyze_documents(assets,items)

    def test_input_directory_aliases_are_still_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            assets=Path(root).resolve();data=b'\\et,""';(assets/'one.txt').write_bytes(data)
            alias=assets/'alias';alias.symlink_to(assets,target_is_directory=True)
            with self.assertRaises((OSError,ProbeError)):
                analyze_documents(alias,[dict(source_file='one.txt',sha256=digest(data))])

    def test_bom_and_trivia_records_do_not_break_command_line_context(self):
        with tempfile.TemporaryDirectory() as root:
            assets=Path(root).resolve();data=b'\xff\xfe'+'\\scp,privateSelector \\et,"\\m,"\r\n'.encode('utf-16le')
            (assets/'one.txt').write_bytes(data)
            rows,counts,_=analyze_documents(assets,[dict(source_file='one.txt',sha256=digest(data))])
            self.assertEqual(counts,{'et':1});self.assertEqual(rows[0]['selector_sha256'],digest(b'privateSelector'))
            self.assertEqual(rows[0]['namespace_binding'],'not_tested')


if __name__=='__main__':unittest.main()
