"""Owned lexical fixtures only; no regex evaluation or commercial text."""
import hashlib
import json
import struct
from pathlib import Path
import tempfile
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.replacement_audit import string_shape,mode_shape,inspect_document,analyze_documents,native_bytes
from tools.delphi_metadata import Image
from tests.test_delphi_metadata import fixture


def native_fixture():
    data,put,u32=fixture();guard=0x401600;table=0x401620
    put(guard,b'\x83\xf8\x04\x0f\x87'+b'\0'*4+b'\xff\x24\x85'+struct.pack('<I',table))
    constants=[];cases=[]
    for i in range(5):
        at=0x401800+i;put(at,bytes([i]));constants.append(dict(id='toy'+str(i),address=hex(at),value=i))
        case=0x401650+i*20;call=case+4;helper=0x401020;u32(table+i*4,case)
        put(call,b'\xe8'+struct.pack('<i',helper-call-5))
        cases.append(dict(mode=i,case=hex(case),call=hex(call),helper=hex(helper)))
    return data,put,dict(constants=constants,cases=cases,guard=hex(guard),table=hex(table))


class ReplacementAuditTests(unittest.TestCase):
    def test_native_mode_routes_and_constants_are_byte_checks_only(self):
        data,_,plan=native_fixture();r=native_bytes(Image(data),plan)
        self.assertEqual(len(r['routes']),5);self.assertEqual(r['status'],'verified')
        self.assertEqual(r['option_names'],'not_tested');self.assertEqual(r['complete_regex_semantics'],'not_tested')

    def test_wrong_native_constant_guard_table_or_call_is_rejected(self):
        for at,raw in [(0x401800,b'\xff'),(0x401602,b'\x05'),(0x401620,b'\0'*4),(0x401654,b'\xe9')]:
            data,put,plan=native_fixture();put(at,raw)
            with self.subTest(at=at),self.assertRaises(ProbeError):native_bytes(Image(data),plan)

    def test_literal_shape_is_redacted_and_does_not_claim_regex_validity(self):
        shape=string_shape('"privateToken[0-9]+"')
        self.assertEqual(shape['special_character_counts'],{'+':1,'[':1,']':1})
        self.assertEqual(shape['regex_validity'],'not_tested');self.assertNotIn('privateToken',json.dumps(shape))

    def test_empty_raw_and_quoted_empty_are_distinct(self):
        self.assertEqual(string_shape('')['shape'],'raw_empty')
        self.assertEqual(string_shape('""')['shape'],'simple_quoted_empty')
        self.assertEqual(string_shape('""')['runtime_value'],'not_tested')

    def test_complex_quotes_and_oversize_stay_unknown_or_unsupported(self):
        self.assertEqual(string_shape('"one"+"two"')['status'],'not_tested')
        self.assertEqual(string_shape('"'+'a'*8192+'"')['status'],'unsupported')

    def test_mode_spelling_does_not_evaluate_or_coerce(self):
        for value in ['"2"','+2','2+0','5','02','variable','']:
            shape,number=mode_shape(value)
            with self.subTest(value=value):self.assertIsNone(number);self.assertEqual(shape['status'],'not_tested')
        shape,number=mode_shape('2');self.assertEqual(number,2);self.assertNotIn('2',json.dumps(shape))
        self.assertEqual(shape['actual_evaluated_mode'],'not_tested')

    def test_source_fields_keep_cp932_and_utf16_byte_provenance(self):
        text='\\scp,rep\\a,"日[0-9]","secret",2\r\n'
        for data in [text.encode('cp932'),b'\xff\xfe'+text.encode('utf-16le')]:
            doc,rows,counts=inspect_document(data,'toy.s');row=rows[0]
            self.assertEqual(counts,{'2':1});self.assertTrue(row['same_line_selector_hint']['matches_builtin_rep_literal'])
            for ref in row['field_references']:
                raw=ref['raw_bytes_reference'];chunk=data[raw['offset']:raw['offset']+raw['length']]
                self.assertEqual(hashlib.sha256(chunk).hexdigest(),raw['sha256'])
            self.assertNotIn('secret',json.dumps(rows));self.assertNotIn('raw',row)

    def test_nearest_region_hint_is_not_silently_a_same_line_binding(self):
        _,rows,_=inspect_document(b'\\scp,rep\n\\a,"x","y",0\n@@Other\n\\a,"x","y",1','toy.s')
        self.assertIsNone(rows[0]['same_line_selector_hint'])
        self.assertTrue(rows[0]['nearest_region_selector_hint']['matches_builtin_rep_literal'])
        self.assertIsNone(rows[1]['nearest_region_selector_hint'])
        self.assertEqual(rows[0]['namespace_binding'],'not_tested')

    def test_other_namespaces_and_bad_arity_remain_reported(self):
        _,rows,_=inspect_document(b'\\scp,other\\a,"x","y",0\n\\a,"x"','toy.s')
        self.assertFalse(rows[0]['same_line_selector_hint']['matches_builtin_rep_literal'])
        self.assertEqual(rows[1]['status'],'unsupported');self.assertIn('unknown_reason',rows[1])

    def test_omitted_mode_is_not_fabricated_as_zero(self):
        _,rows,modes=inspect_document(b'\\scp,rep\\a,"x","y"','toy.s')
        self.assertEqual(rows[0]['mode_shape']['shape'],'omitted');self.assertEqual(modes,{})
        self.assertEqual(rows[0]['mode_shape']['actual_evaluated_mode'],'not_tested')

    def test_versions_are_preserved_and_exact_duplicate_inputs_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();items=[]
            for name,mode in [('one.s',0),('two.s',4)]:
                data=('\\a,"x","y",'+str(mode)).encode();(root/name).write_bytes(data)
                items.append(dict(source_file=name,sha256=hashlib.sha256(data).hexdigest()))
            rows,modes,files=analyze_documents(root,items)
            self.assertEqual(len(files),2);self.assertEqual(modes,{'0':1,'4':1})
            with self.assertRaises(ProbeError):analyze_documents(root,[items[0],items[0]])

    def test_identity_mismatch_and_symlink_input_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();(root/'owned.s').write_bytes(b'\\a,"x","y",0')
            with self.assertRaises(ProbeError):analyze_documents(root,[dict(source_file='owned.s',sha256='0'*64)])
            (root/'alias.s').symlink_to(root/'owned.s')
            with self.assertRaises((OSError,ProbeError)):analyze_documents(root,[dict(source_file='alias.s',sha256='0'*64)])

    def test_non_ascii_units_and_field_limit_do_not_run_patterns(self):
        shape=string_shape('"😀.*"');self.assertEqual(shape['utf16_code_units'],4);self.assertFalse(shape['ascii_only'])
        _,rows,_=inspect_document(('\\a,"'+'a'*8192+'","b",0').encode(),'toy.s')
        self.assertEqual(rows[0]['status'],'unsupported')


if __name__=='__main__':unittest.main()
