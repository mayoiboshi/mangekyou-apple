"""Owned selector snippets and byte fixtures only; no script execution."""
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from tools.scope_audit import selector_chain,field_shape,inspect_document,analyze_documents
from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tests.test_delphi_metadata import fixture


def chain_fixture():
    data,put,_=fixture();steps=[]
    for i,value in enumerate([0x10,0x20,0x30]):
        at=0x401600+i*16;target=0x401700+i*16
        put(at,b'\x2d'+struct.pack('<I',value)+b'\x0f\x84'+struct.pack('<i',target-at-11))
        steps.append(dict(address=hex(at),subtract=hex(value),zero_target=hex(target)))
    return data,put,steps


class ScopeAuditTests(unittest.TestCase):
    def test_selector_chain_checks_bytes_but_does_not_claim_reachability(self):
        data,_,steps=chain_fixture();r=selector_chain(Image(data),steps,0x60)
        self.assertEqual(r['instruction_bytes_status'],'verified');self.assertEqual(r['status'],'inferred')
        self.assertEqual(r['command_id'],'0x60')

    def test_wrong_subtraction_condition_target_and_sum_are_rejected(self):
        for at,raw in [(0x401600,b'\x05'),(0x401601,b'\x11'),(0x401606,b'\x85'),(0x401607,b'\0'*4)]:
            data,put,steps=chain_fixture();put(at,raw)
            with self.subTest(at=at),self.assertRaises(ProbeError):selector_chain(Image(data),steps,0x60)
        data,_,steps=chain_fixture()
        with self.assertRaises(ProbeError):selector_chain(Image(data),steps,0x61)

    def test_bare_object_reference_and_string_literal_stay_distinct(self):
        a=field_shape('rep');b=field_shape('"rep"')
        self.assertTrue(a['bare_builtin_rep_identifier']);self.assertTrue(b['quoted_builtin_rep_string'])
        self.assertNotEqual(a['shape'],b['shape']);self.assertEqual(a['evaluated_tag'],'not_tested')
        self.assertEqual(field_shape('')['shape'],'raw_empty');self.assertTrue(field_shape('""')['quoted_empty'])

    def test_unknown_syntax_and_field_limit_do_not_become_object_names(self):
        self.assertEqual(field_shape('function(1)')['status'],'unsupported')
        self.assertEqual(field_shape('x'*8193)['status'],'unsupported')
        self.assertNotIn('privateObject',json.dumps(field_shape('privateObject[0]')))

    def test_source_positions_and_empty_gaps_are_preserved_without_compaction(self):
        rows,edges=inspect_document(b'\\scp,first,,third\\a,"x","y"','owned.s');r=rows[0]
        self.assertEqual([f['position'] for f in r['field_shapes']],[0,1,2])
        self.assertEqual(r['raw_empty_positions'],[1]);self.assertTrue(r['raw_empty_before_later_source'])
        self.assertEqual(r['field_shapes'][1]['runtime_nil_mapping'],'not_tested')
        self.assertEqual(edges[0]['dispatch_after_success_candidate'],'continue_next_slot')

    def test_same_line_edges_reset_at_new_line_and_new_selector(self):
        data=b'\\scp,rep\\a,"x","y"\\scp,other\\nt,""\n\\a,"x","y"'
        rows,edges=inspect_document(data,'owned.s')
        self.assertEqual([e['command'] for e in edges],['a','nt'])
        self.assertNotEqual(edges[0]['selector_reference']['byte_offset'],edges[1]['selector_reference']['byte_offset'])
        self.assertNotIn('other',json.dumps(rows));self.assertEqual(edges[0]['actual_dispatch'],'not_tested')

    def test_empty_selector_and_more_than_sixteen_source_fields_are_explicit(self):
        rows,_=inspect_document(b'\\scp\\a,"x","y"','owned.s');self.assertTrue(rows[0]['omitted_or_empty_scope'])
        rows,_=inspect_document(('\\scp,'+','.join('x'+str(i) for i in range(17))).encode(),'owned.s')
        self.assertEqual(rows[0]['status'],'unsupported');self.assertEqual(rows[0]['unclassified_field_count'],1)
        self.assertEqual(len(rows[0]['field_shapes']),16)

    def test_cp932_and_utf16_provenance_does_not_store_parameter_text(self):
        text='\\scp,日,"privateName"\\a,"x","y"\r\n'
        for data in [text.encode('cp932'),b'\xff\xfe'+text.encode('utf-16le')]:
            rows,_=inspect_document(data,'owned.s')
            for f in rows[0]['field_shapes']:
                ref=f['field_reference']['raw_bytes_reference'];chunk=data[ref['offset']:ref['offset']+ref['length']]
                self.assertEqual(hashlib.sha256(chunk).hexdigest(),ref['sha256'])
            self.assertNotIn('privateName',json.dumps(rows))

    def test_versions_are_preserved_and_duplicate_or_changed_inputs_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();items=[]
            for name in ['one.s','two.s']:
                data=b'\\scp,rep\\a,"x","y"';(root/name).write_bytes(data)
                items.append(dict(source_file=name,sha256=hashlib.sha256(data).hexdigest()))
            rows,edges,files=analyze_documents(root,items);self.assertEqual((len(rows),len(edges),len(files)),(2,2,2))
            with self.assertRaises(ProbeError):analyze_documents(root,[items[0],items[0]])
            (root/'one.s').write_bytes(b'changed')
            with self.assertRaises(ProbeError):analyze_documents(root,items)

    def test_symlink_input_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();(root/'owned.s').write_bytes(b'\\scp');(root/'alias.s').symlink_to(root/'owned.s')
            with self.assertRaises((OSError,ProbeError)):analyze_documents(root,[dict(source_file='alias.s',sha256='0'*64)])


if __name__=='__main__':unittest.main()
