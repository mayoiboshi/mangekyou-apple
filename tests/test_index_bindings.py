"""Owned PE metadata and bytes; no original engine oracle."""
import unittest
from tests.test_delphi_metadata import fixture
from tools.delphi_metadata import Image
from tools.index_bindings import bind_class, pattern
from tools.mangekyou_p0 import ProbeError
from tools.research_checks import forbidden_content_fields


class IndexBindingTests(unittest.TestCase):
    def test_binding_requires_both_field_offsets_and_virtual_slots(self):
        data,_,_=fixture()
        row=bind_class(Image(data),0x401100,'ToyRoutine',64,{'Scope':8},{8:0x401020})
        self.assertEqual(row['status'],'verified'); self.assertEqual(row['live_dispatch'],'not_tested')
        self.assertFalse(forbidden_content_fields(row))
        for fields,slots in [({'Scope':12},{8:0x401020}),({'Missing':8},{8:0x401020}),({'Scope':8},{8:0x401024})]:
            with self.assertRaises(ProbeError): bind_class(Image(data),0x401100,'ToyRoutine',64,fields,slots)

    def test_wrong_class_identity_or_instance_size_cannot_bind(self):
        data,_,_=fixture()
        for name,size in [('Other',64),('ToyRoutine',68)]:
            with self.assertRaises(ProbeError): bind_class(Image(data),0x401100,name,size,{}, {})

    def test_pattern_references_exact_owned_bytes_and_rejects_mismatch(self):
        data,put,_=fixture();put(0x401020,bytes.fromhex('8b4640'))
        r=pattern(Image(data),'owned',0x401020,'8b4640')
        self.assertEqual(r['raw_bytes_reference']['length'],3)
        self.assertFalse(forbidden_content_fields(r))
        for raw in ['','8b4740','00'*65]:
            with self.assertRaises(ProbeError): pattern(Image(data),'owned',0x401020,raw)
