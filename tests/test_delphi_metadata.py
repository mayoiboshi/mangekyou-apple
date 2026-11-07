"""Invented PE/RTTI fixtures; no commercial bytes, execution or Delphi runtime."""
import struct
import unittest

from tools.delphi_metadata import Image,parse_class,parse_record,validate_type_plan
from tools.mangekyou_p0 import ProbeError
from tests.test_semantic_evidence import synthetic_pe


def fixture():
    data=synthetic_pe();data.extend(b'\0'*(8192-len(data)))
    section=0x98+224;struct.pack_into('<I',data,section+8,7680);struct.pack_into('<I',data,section+16,7680)
    def put(va,raw):data[512+va-0x401000:512+va-0x401000+len(raw)]=raw
    def u32(va,value):put(va,struct.pack('<I',value))
    def short(va,text):put(va,bytes([len(text)])+text.encode())
    vmt=0x401100
    for offset,value in [(-88,vmt),(-72,0x401540),(-68,0x401400),(-64,0x401300),(-56,0x401500),(-52,64),(-48,0),(-4,0x401010)]:u32(vmt+offset,value)
    for offset in [0,4,8,12]:u32(vmt+offset,0x401020)
    short(0x401500,'ToyRoutine');put(0x401540,b'\x07\x0aToyRoutine');u32(0x40154c,vmt)
    put(0x401300,struct.pack('<HHIHh',0,1,0x401350,0x4a,3))
    put(0x401350,struct.pack('<HI',12,0x401020)+b'\x03Add\x00\x00')
    put(0x401400,struct.pack('<HIHBII',0,0,1,2,0,8)+b'\x05Scope'+struct.pack('<H',2))
    put(0x401600,b'\x0e\x09ToyRecord'+struct.pack('<II',16,0)+b'\x00'+struct.pack('<I',1))
    put(0x401618,struct.pack('<IIB',0,0,2)+b'\x05Value'+struct.pack('<H',2))
    return data,put,u32


class DelphiMetadataTests(unittest.TestCase):
    def test_record_only_plan_is_admitted_without_inventing_a_class(self):
        validate_type_plan(dict(classes=[],records=[dict(type_info='0x401600')]))
        with self.assertRaises(ProbeError):validate_type_plan(dict(classes=[],records=[]))

    def test_type_plan_rejects_duplicate_records_and_excessive_counts(self):
        for rows in [[dict(type_info='0x401600')]*2,[dict(type_info=hex(i)) for i in range(17)]]:
            with self.subTest(count=len(rows)),self.assertRaises(ProbeError):validate_type_plan(dict(classes=[],records=rows))

    def test_zero_positive_slots_do_not_treat_following_data_as_code(self):
        data,_,u32=fixture();u32(0x401100,14)
        result=parse_class(Image(data),0x401100,0,'ToyRoutine')
        self.assertEqual([s['byte_offset'] for s in result['slots']],[-4])
        self.assertEqual(result['methods'][0]['virtual_slot_match'],'not_tested')
        self.assertEqual(result['live_dispatch'],'not_tested')

    def test_slot_count_still_rejects_negative_or_excessive_ranges(self):
        data,_,_=fixture()
        for count in [-1,17]:
            with self.subTest(count=count),self.assertRaises(ProbeError):parse_class(Image(data),0x401100,count)

    def test_class_self_identity_and_virtual_method_agree(self):
        data,_,_=fixture();result=parse_class(Image(data),0x401100,4,'ToyRoutine')
        self.assertEqual(result['instance_size'],64);self.assertEqual(result['methods'][0]['name'],'Add')
        self.assertEqual(result['methods'][0]['virtual_slot_match'],'verified')
        self.assertEqual(result['live_dispatch'],'not_tested');self.assertEqual(result['status'],'inferred')

    def test_wrong_self_pointer_is_rejected_before_member_walk(self):
        data,_,u32=fixture();u32(0x401100-88,0x401104)
        with self.assertRaises(ProbeError):parse_class(Image(data),0x401100,4)

    def test_typeinfo_class_pointer_must_match_vmt(self):
        data,_,u32=fixture();u32(0x40154c,0x401104)
        with self.assertRaises(ProbeError):parse_class(Image(data),0x401100,4)

    def test_mismatched_slot_preserves_both_addresses(self):
        data,_,u32=fixture();u32(0x401352,0x401024);result=parse_class(Image(data),0x401100,4)
        method=result['methods'][0];self.assertEqual(method['virtual_slot_match'],'unsupported')
        self.assertEqual(method['code_address'],'0x401024');self.assertEqual(method['slot_target'],'0x401020')

    def test_field_offsets_outside_instance_are_rejected(self):
        data,_,u32=fixture();u32(0x40140d,64)
        with self.assertRaises(ProbeError):parse_class(Image(data),0x401100,4)

    def test_member_count_and_entry_size_are_bounded(self):
        for count,length in [(65,12),(1,7)]:
            data,put,_=fixture();put(0x401302,struct.pack('<H',count));put(0x401350,struct.pack('<H',length))
            with self.subTest(count=count,length=length),self.assertRaises(ProbeError):parse_class(Image(data),0x401100,4)

    def test_record_layout_preserves_omitted_type_and_unknown_prefix_meaning(self):
        data,_,_=fixture();result=parse_record(Image(data),0x401600,0x401614,'ToyRecord')
        self.assertEqual(result['declared_size'],16);self.assertEqual(result['fields'][0]['name'],'Value')
        self.assertEqual(result['fields'][0]['type_info']['status'],'not_tested')
        self.assertEqual(result['extended_prefix']['meaning'],'not_tested')

    def test_unreviewed_record_prefix_is_explicitly_rejected(self):
        data,put,_=fixture();put(0x401613,b'\x01')
        with self.assertRaises(ProbeError):parse_record(Image(data),0x401600,0x401614)

    def test_nonempty_attribute_payload_is_retained_as_unsupported(self):
        data,put,_=fixture();put(0x401417,struct.pack('<H',4)+b'XY')
        result=parse_class(Image(data),0x401100,4);attr=result['fields'][0]['attributes']
        self.assertEqual(attr['status'],'unsupported');self.assertEqual(attr['raw_bytes_reference']['length'],4)

    def test_input_address_and_total_read_limits_are_enforced(self):
        data,_,_=fixture();image=Image(data,budget=8)
        with self.assertRaises(ProbeError):parse_class(image,0x401100,4)
        for va,size in [(0x401000,0),(0xffffffff,2),(0x400000,4),(0x401000,8193)]:
            with self.subTest(va=va,size=size),self.assertRaises(ProbeError):Image(data).read(va,size)

    def test_truncated_declared_section_cannot_supply_metadata(self):
        data,_,_=fixture()
        with self.assertRaises(ProbeError):Image(data[:-1])

    def test_signature_tail_is_hashed_without_semantic_guess(self):
        data,_,_=fixture();tail=parse_class(Image(data),0x401100,4)['methods'][0]['signature_tail']
        self.assertEqual(tail['status'],'not_tested');self.assertEqual(tail['length'],2)
        self.assertIn('sha256',tail['raw_bytes_reference'])

    def test_enum_values_preserve_declared_minimum_and_source_references(self):
        data,put,u32=fixture();u32(0x401700,0x401704)
        put(0x401704,b'\x03\x04Mode'+struct.pack('<BiiI',1,5,6,0x401700)+b'\x03One\x03Two')
        enum=Image(data).type_reference(0x401700)['enum_header']
        self.assertEqual([(m['value'],m['name']) for m in enum['members']],[(5,'One'),(6,'Two')])
        self.assertEqual(enum['execution_semantics'],'not_tested');self.assertEqual(enum['status'],'inferred')
        self.assertTrue(all('sha256' in m['raw_bytes_reference'] for m in enum['members']))

    def test_enum_base_must_point_back_to_same_type(self):
        data,put,u32=fixture();u32(0x401700,0x401704);u32(0x401780,0x401540)
        put(0x401704,b'\x03\x04Mode'+struct.pack('<BiiI',1,0,1,0x401780)+b'\x03One\x03Two')
        with self.assertRaises(ProbeError):Image(data).type_reference(0x401700)

    def test_enum_count_and_reversed_range_are_rejected(self):
        for minimum,maximum in [(0,256),(2,1),(-2147483648,2147483647)]:
            data,put,u32=fixture();u32(0x401700,0x401704)
            put(0x401704,b'\x03\x04Mode'+struct.pack('<BiiI',1,minimum,maximum,0x401700))
            with self.subTest(minimum=minimum,maximum=maximum),self.assertRaises(ProbeError):Image(data).type_reference(0x401700)

    def test_duplicate_enum_symbols_remain_an_error(self):
        data,put,u32=fixture();u32(0x401700,0x401704)
        put(0x401704,b'\x03\x04Mode'+struct.pack('<BiiI',1,0,1,0x401700)+b'\x03One\x03One')
        with self.assertRaises(ProbeError):Image(data).type_reference(0x401700)


if __name__=='__main__':unittest.main()
