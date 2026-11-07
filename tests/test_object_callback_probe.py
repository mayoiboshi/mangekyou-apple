"""Owned PE32 snippets and invented declarations; no game bytes or execution."""
import struct
import unittest

from tools.delphi_metadata import Image
from tools.mangekyou_p0 import ProbeError
from tools.object_callback_probe import event_layout,initializer,relative_call
from tests.test_delphi_metadata import fixture


def record():
    return dict(declared_size=32,managed_fields=[],fields=[dict(name=n,offset=8*i,
        type_info=dict(kind_u8=8,name='ToyMethod'),attributes=dict(length=2),
        raw_bytes_reference=dict(offset=100+i,length=1,sha256='0'*64))
        for i,n in enumerate(['ObjectCreate','ObjectDestroy','ObjectSave','ObjectLoad'])])


def stores():
    data,put,_=fixture();at=0x401700
    raw=b''.join(bytes([0x89,0x75,(-28+8*i)&255,0xc7,0x45,(-32+8*i)&255])+
        struct.pack('<I',0x401020+16*i) for i in range(4))
    put(at,raw)
    return data,put,at


class ObjectCallbackTests(unittest.TestCase):
    def test_method_offsets_are_two_words_and_signature_is_unknown(self):
        r=event_layout(record());self.assertEqual([f['data_offset'] for f in r['fields']],[4,12,20,28])
        self.assertEqual(r['declaration_bytes_status'],'verified');self.assertEqual(r['status'],'inferred')
        self.assertEqual(r['method_signature'],'not_tested');self.assertEqual(r['runtime_invocation'],'not_tested')

    def test_method_kind_cannot_be_confused_with_set_or_procedure(self):
        for kind in [6,7,22]:
            r=record();r['fields'][0]['type_info']['kind_u8']=kind
            with self.subTest(kind=kind),self.assertRaises(ProbeError):event_layout(r)

    def test_wrong_event_order_or_offset_is_not_silently_accepted(self):
        for change in ['offset','name']:
            r=record();r['fields'][0][change]=8 if change=='offset' else 'OtherEvent'
            with self.subTest(change=change),self.assertRaises(ProbeError):event_layout(r)

    def test_record_size_managed_fields_and_attributes_are_bounded(self):
        for change in ['size','managed','count','attributes']:
            r=record()
            if change=='size':r['declared_size']=64
            if change=='managed':r['managed_fields']=[{}]
            if change=='count':r['fields'].pop()
            if change=='attributes':r['fields'][0]['attributes']['length']=4
            with self.subTest(change=change),self.assertRaises(ProbeError):event_layout(r)

    def test_initializer_preserves_create_and_load_as_distinct_events(self):
        data,_,at=stores();r=initializer(Image(data),at,event_layout(record()))
        self.assertEqual(r['events'][0]['target'],'0x401020');self.assertEqual(r['events'][3]['target'],'0x401050')
        self.assertEqual(r['owner_identity'],'not_tested');self.assertEqual(r['instruction_bytes_status'],'verified')
        self.assertEqual([f['raw_bytes_reference']['length'] for f in r['events']],[10]*4)

    def test_wrong_register_displacement_or_opcode_refuses_binding(self):
        for index,value in [(1,0x55),(2,0xe0),(3,0xb8),(5,0xe4)]:
            data,put,at=stores();put(at+index,bytes([value]))
            with self.subTest(index=index),self.assertRaises(ProbeError):initializer(Image(data),at,event_layout(record()))

    def test_initializer_rejects_target_outside_file_mapping(self):
        data,put,at=stores();put(at+6,struct.pack('<I',0xffffffff))
        with self.assertRaises(ProbeError):initializer(Image(data),at,event_layout(record()))

    def test_direct_call_keeps_evidence_without_runtime_claim(self):
        data,put,_=fixture();at=0x401720;target=0x401020
        put(at,b'\xe8'+struct.pack('<i',target-at-5));r=relative_call(Image(data),at,target)
        self.assertEqual(r['target'],hex(target));self.assertEqual(r['raw_bytes_reference']['length'],5)
        self.assertNotIn('execution_semantics',r)

    def test_jump_or_wrong_call_target_is_not_a_factory_call(self):
        for opcode,target in [(0xe9,0x401020),(0xe8,0x401030)]:
            data,put,_=fixture();at=0x401720;put(at,bytes([opcode])+struct.pack('<i',target-at-5))
            with self.subTest(opcode=opcode,target=target),self.assertRaises(ProbeError):relative_call(Image(data),at,0x401020)


if __name__=='__main__':unittest.main()
