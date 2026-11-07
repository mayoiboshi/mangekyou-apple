"""Native-backed grouping hypothesis on invented snippets, not execution."""
import unittest
from tools.qlie_lex import split_fields,lex,digest,MAX_FIELDS
from tools.mangekyou_p0 import ProbeError
from tools.subp_analysis import field_ref


class FieldGroupingTests(unittest.TestCase):
    def test_field_count_limit_is_explicit_and_keeps_source_coverage(self):
        for grouping in [False,True]:
            with self.subTest(grouping=grouping):
                self.assertEqual(len(split_fields(','.join(['x']*MAX_FIELDS),grouping)),MAX_FIELDS)
                with self.assertRaises(ProbeError):split_fields(','.join(['x']*(MAX_FIELDS+1)),grouping)
        data=b'\\cal'+b',x'*MAX_FIELDS;doc=lex(data,'owned.s',field_model='native_grouping')
        self.assertEqual(doc['status'],'unsupported');self.assertEqual(doc['byte_coverage'],'verified')
        self.assertIn('field_count_limit',str(doc['errors']))

    def test_bracket_and_parenthesis_commas_stay_inside_one_field(self):
        text='cal,a[1,2],f(3,4)'
        self.assertEqual([f['raw'] for f in split_fields(text,True)],['cal','a[1,2]','f(3,4)'])
        self.assertEqual(len(split_fields(text)),5)

    def test_quoted_delimiters_do_not_change_signed_counter(self):
        text='x,"[(,)]",y["a,b",2]'
        self.assertEqual([f['raw'] for f in split_fields(text,True)],['x','"[(,)]"','y["a,b",2]'])

    def test_grouping_is_a_counter_not_a_matching_stack_validator(self):
        self.assertEqual(len(split_fields('x,([)],z',True)),3)
        self.assertEqual(len(split_fields('x,],z',True)),3)

    def test_historical_model_remains_explicitly_reproducible(self):
        data=b'\\cal,f(1,2)'
        old=lex(data,'invented.s');new=lex(data,'invented.s',field_model='native_grouping')
        self.assertEqual(len(old['records'][0]['operands']),2);self.assertEqual(len(new['records'][0]['operands']),1)
        self.assertEqual(old['grammar_profile']['field_model'],'quote_only')
        self.assertEqual(new['records'][0]['operand_split_model'],'native_grouping')

    def test_grouped_fields_keep_cp932_alias_and_surrogate_source_bytes(self):
        for data in [b'\\cal,a[1,2]+"\x81\x61"\\ret',b'\xff\xfe'+'\\cal,a[1,2]+"😀,字"\\ret'.encode('utf-16le')]:
            doc=lex(data,'invented.s',field_model='native_grouping');r=next(r for r in doc['records'] if r.get('token')=='cal')
            self.assertEqual(doc['status'],'verified');self.assertEqual(len(r['operands']),1)
            f=r['operands'][0];ref=field_ref(doc,f,data)['raw_bytes_reference']
            self.assertEqual(ref['sha256'],digest(data[ref['offset']:ref['offset']+ref['length']]))
            self.assertEqual(sum(r['byte_length'] for r in doc['records']),len(data))

    def test_depth_limit_and_unknown_models_fail_explicitly(self):
        data=('\\cal,'+'('*65+'x'+')'*65).encode()
        doc=lex(data,'invented.s',field_model='native_grouping')
        self.assertEqual(doc['status'],'unsupported');self.assertEqual(doc['byte_coverage'],'verified')
        self.assertIn('field_group_depth_limit',str(doc['errors']))
        with self.assertRaises(ProbeError):lex(b'\\ret','invented.s',field_model='invented')

    def test_trailing_empty_is_retained_as_source_ir_not_runtime_list_count(self):
        self.assertEqual([f['raw'] for f in split_fields('subp,@@Own,,',True)],['subp','@@Own','',''])


if __name__=='__main__':unittest.main()
