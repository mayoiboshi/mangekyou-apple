import hashlib
import importlib
import importlib.util
import io
import json
from pathlib import Path
import struct
import sys
import unittest
import zlib

from tools.mangekyou_p0 import ROOT, ProbeError
from tools.qlie_lex import decode_spans, digest, lex, sanitized, split_fields
from tools.p1_static import overlay_report, path_options, public_projection, resource_report, symbol_report, validate_outputs
from tools.abmp_probe import Budget, MAX_MEMBER, MAX_DEPTH, inspect_container


def document(name, text, codec='cp932'):
    data=text.encode(codec)
    d=lex(data,name)
    d.update(logical_path=name.split('/',1)[1] if '.pack/' in name else name,
        normalized_text_sha256=digest(text.replace('\r\n','\n').encode()),
        nonblank_text_sha256=digest(text.encode()),origin={'archive':'synthetic.pack'},_normalized_lines=text.splitlines())
    return d


class LexerTests(unittest.TestCase):
    def assert_coverage(self,data,report):
        cursor=0;parts=[]
        for r in report['records']:
            self.assertEqual(r['byte_offset'],cursor)
            raw=data[cursor:cursor+r['byte_length']]
            self.assertEqual(hashlib.sha256(raw).hexdigest(),r['raw_bytes_reference']['sha256'])
            cursor+=r['byte_length'];parts.append(raw)
        self.assertEqual(cursor,len(data));self.assertEqual(b''.join(parts),data)

    def test_inline_commands_tabs_and_quoted_backslashes(self):
        data=b'  \\if,#v>1\\then\t\\sub,@@!Fn,"dir\\x.s"\t\\end\r\n'
        r=lex(data,'test.s');commands=[x for x in r['records'] if x['record_type']=='command']
        self.assertEqual([x['token'] for x in commands],['if','then','sub','end'])
        self.assertEqual(commands[2]['operands'][1]['value'],'dir\\x.s')
        self.assert_coverage(data,r)

    def test_utf16_surrogates_preserve_byte_positions(self):
        data=b'\xff\xfe'+'\\x,"😀"\t\\ret\r\n'.encode('utf-16-le')
        r=lex(data,'test.s');command=[x for x in r['records'] if x['token']=='ret'][0]
        self.assertEqual(data[command['byte_offset']:command['byte_offset']+command['byte_length']],'\\ret'.encode('utf-16-le'))
        self.assert_coverage(data,r)

    def test_cp932_alias_is_not_reencoded_for_raw_reference(self):
        data=b'\\x,"\x87\x90"\t\\ret\n'
        r=lex(data,'test.s');self.assert_coverage(data,r)
        first=[x for x in r['records'] if x['token']=='x'][0]
        self.assertEqual(data[first['byte_offset']:first['byte_offset']+first['byte_length']],b'\\x,"\x87\x90"')

    def test_byte_coverage_empty_bom_padding(self):
        for data in [b'',b'\xff\xfe',b'\xef\xbb\xbf',b'\n\n\t\r\n',b'\xff\xfe'+('\n'*1000).encode('utf-16-le')]:
            with self.subTest(data=data[:6]):self.assert_coverage(data,lex(data,'s.s'))

    def test_include_path_is_not_inline_command_stream(self):
        r=lex(b'@@@!avg\\header.s\r\n','s.s')
        includes=[x for x in r['records'] if x['record_type']=='include']
        self.assertEqual(len(includes),1);self.assertEqual(includes[0]['identifier'],'!avg\\header.s')

    def test_empty_operand_offsets_are_inside_the_command(self):
        r=lex(b'\\x,,z\n','s.s')
        command=next(x for x in r['records'] if x['record_type']=='command')
        self.assertEqual(command['operands'][0]['byte_length'],0)
        self.assertEqual(command['operands'][0]['byte_offset'],3)

    def test_colons_in_quotes_are_literal(self):
        fields=split_fields('file:"a,b:c",7,,name:value')
        self.assertEqual(fields[0]['key'],'file');self.assertEqual(fields[0]['value'],'a,b:c')
        self.assertEqual(fields[2]['value'],'');self.assertEqual(fields[3]['key'],'name')

    def test_unclosed_quote_does_not_drop_unknown_record(self):
        r=lex(b'\\x,"broken\\ret\n','s.s')
        self.assertEqual(r['status'],'unsupported')
        self.assertTrue(any(x['record_type']=='unknown_record' for x in r['records']))
        self.assert_coverage(b'\\x,"broken\\ret\n',r)

    def test_binary_and_incomplete_encodings_are_rejected(self):
        for data in [b'\0\x01',b'\x81',b'\xff\xfea']:
            with self.subTest(data=data),self.assertRaises((ProbeError,UnicodeError)):lex(data,'s.s')

    def test_public_projection_redacts_rhs_and_operands(self):
        r=lex('^select,"合成の台詞"\n'.encode('cp932'),'s.s')
        public=sanitized(next(x for x in r['records'] if x['token']=='select'))
        text=json.dumps(public,ensure_ascii=False)
        self.assertNotIn('合成の台詞',text);self.assertNotIn('"raw":',text)
        self.assertIn('value_sha256',text)


class GraphTests(unittest.TestCase):
    def test_overlay_encoding_change_never_selects_precedence(self):
        left=document('data7.pack/a.s','@@Top\r\n\\ret\r\n')
        right=document('data8.pack/a.s','@@Top\n\\ret\n','utf-16')
        r=overlay_report([left,right],[])
        self.assertEqual(r['comparison_counts'],{'line_ending_normalized_text_equal':1})
        self.assertEqual(r['groups'][0]['load_precedence'],'not_tested')
        self.assertEqual(r['behavioral_equivalence'],'not_tested')

    def test_overlay_changed_lines_exclude_content(self):
        a=document('data7.pack/a.s','@@Top\n\\ret\n')
        b=document('data8.pack/a.s','@@Top\n\\zero\n')
        r=overlay_report([a,b],[])
        self.assertEqual(r['comparison_counts'],{'normalized_text_changed':1})
        self.assertTrue(r['groups'][0]['normalized_line_diffs'][0]['changes'])
        self.assertFalse(r['groups'][0]['same_token_sequence'])
        self.assertNotIn('\\zero',json.dumps(r))

    def test_third_variant_is_not_lost_when_first_two_are_equal(self):
        a=document('data0.pack/a.s','@@Top\n\\ret\n')
        b=document('data7.pack/a.s','@@Top\n\\ret\n')
        c=document('data8.pack/a.s','@@Top\n\\zero\n')
        group=overlay_report([a,b,c],[])['groups'][0]
        self.assertEqual(group['relation'],'normalized_text_changed')
        self.assertEqual(len(group['normalized_line_diffs']),2)
        self.assertTrue(group['normalized_line_diffs'][1]['changes'])

    def test_unchanged_command_fields_do_not_imply_unchanged_text_or_behavior(self):
        a=document('data7.pack/a.s','@@Top\n合成A\n\\ret\n')
        b=document('data8.pack/a.s','@@Top\n合成B\n\\ret\n')
        group=overlay_report([a,b],[])['groups'][0]
        self.assertEqual(group['relation'],'normalized_text_changed')
        self.assertTrue(group['same_lexical_fields'])
        self.assertEqual(group['load_precedence'],'not_tested')

    def test_bang_and_parent_paths_remain_explicit_hypotheses(self):
        self.assertIn('avg/custom.s',path_options('avg/main.s','!Custom.s'))
        self.assertEqual(path_options('a.s','../../escape.s'),[])
        self.assertEqual(path_options('a.s','C:\\x.s'),[])
        self.assertIn('image.png',path_options('avg/a.s','../image.png'))

    def test_explicit_file_label_reference_preserves_duplicate_variants(self):
        source=document('data0.pack/a.s','\\sub,@@!Fn,"target.s"\n')
        a=document('data7.pack/target.s','@@!Fn\n\\ret\n')
        b=document('data8.pack/target.s','@@!Fn\n\\ret\n')
        r=symbol_report([source,a,b]);edge=r['label_references'][0]
        self.assertEqual(len(edge['candidates']),2)
        self.assertEqual(edge['status'],'inferred');self.assertEqual(edge['execution_edge'],'not_tested')

    def test_missing_explicit_file_cannot_bind_an_unrelated_global_label(self):
        source=document('a.s','\\sub,@@!Fn,"missing.s"\n')
        target=document('b.s','@@!Fn\n')
        edge=symbol_report([source,target])['label_references'][0]
        self.assertEqual(edge['status'],'unsupported');self.assertEqual(edge['candidates'],[])

    def test_include_cycles_terminate_without_execution(self):
        a=document('a.s','@@@b.s\n\\sub,@@!Fn\n')
        b=document('b.s','@@@a.s\n@@!Fn\n')
        r=symbol_report([a,b])
        self.assertEqual(r['include_count'],2)
        self.assertEqual(r['label_references'][0]['basis'],'include_closure_hypothesis')

    def test_dollar_reference_is_not_assumed_to_be_a_macro_or_number(self):
        d=document('template.txt','$fade=100\n$test=$fade,$ABCD\n')
        r=symbol_report([d])
        self.assertEqual(r['macro_definition_count'],2)
        self.assertTrue(all(e['status']!='verified' for e in r['macro_references']))

    def test_extensionless_resource_identifier_is_only_a_candidate(self):
        d=document('a.s','^opaque,file:"bg"\n％voice001\n')
        archives=[dict(path='GameData/data1.pack',index=dict(entries=[dict(index=0,name='images/bg.png'),dict(index=1,name='voice/voice001.ogg')]))]
        r=resource_report([d],archives)
        self.assertEqual(r['matched_candidate_edges'],2)
        self.assertTrue(all(e['relationship_type']=='Unknown' and e['runtime_binding']=='not_tested' for e in r['edges']))

    def test_expression_resource_field_is_not_evaluated(self):
        d=document('a.s','^opaque,file:"bg"+ResultStr[0]\n')
        r=resource_report([d],[])
        self.assertEqual(r['matched_candidate_edges'],0)
        self.assertEqual(r['dynamic_fields']['expression_or_template_fields'],1)

    def test_malformed_template_rhs_is_reported_not_silently_skipped(self):
        d=document('a.txt','$file="not closed\n')
        r=resource_report([d],[])
        self.assertEqual(r['dynamic_fields']['unparsed_assignment_rhs'],1)
        self.assertEqual(r['field_errors'][0]['category'],'unclosed_quote')

    def test_computed_label_target_is_retained_as_unknown(self):
        d=document('a.s','\\sub,ResultStr[0]\n')
        r=symbol_report([d])
        self.assertEqual(r['dynamic_control_target_count'],1)
        self.assertEqual(r['dynamic_control_targets'][0]['status'],'unsupported')

    def test_public_edge_truncation_is_explicit(self):
        r=public_projection('resource-report.json',dict(edges=[{'i':i} for i in range(220)],unresolved=[]))
        self.assertEqual(len(r['edges']),200);self.assertEqual(r['edges_retained_total'],220)

    def test_game_directory_cannot_be_used_as_report_output(self):
        with self.assertRaisesRegex(ProbeError,'overlap'):
            validate_outputs(ROOT/'private/real-assets',ROOT,ROOT/'private/p1',ROOT/'reports/p1')
        with self.assertRaisesRegex(ProbeError,'public P1 output'):
            validate_outputs(ROOT/'private/real-assets',None,ROOT/'private/p1',Path('/tmp/original-game'))


class ContainerLimitTests(unittest.TestCase):
    def test_declared_decompression_bomb_rejected_before_decode(self):
        payload=b'1PC\xff'+struct.pack('<II',1,MAX_MEMBER+1)
        with self.assertRaisesRegex(ProbeError,'member_output_limit'):Budget().claim(payload)

    def test_cumulative_budget_and_member_count_are_enforced(self):
        b=Budget(total=4,members=2);b.claim(b'ab');b.claim(b'cd')
        with self.assertRaisesRegex(ProbeError,'total_output_limit'):b.claim(b'x')
        b=Budget(total=100,members=1);b.claim(b'')
        with self.assertRaisesRegex(ProbeError,'member_count_limit'):b.claim(b'')

    def test_partial_bpe_header_rejected(self):
        with self.assertRaisesRegex(ProbeError,'short_compressed_member'):Budget().claim(b'1PC\xff')


HAS_UPSTREAM=sys.version_info>=(3,10) and importlib.util.find_spec('PIL') is not None and (ROOT/'.research/upstream/qlie-unpack/qlie_unpacker/abmp.py').is_file()


@unittest.skipUnless(HAS_UPSTREAM,'ABMP integration needs pinned source and Python >=3.10')
class ContainerIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        from tools.upstream_worker import validate_source
        source=ROOT/'.research/upstream/qlie-unpack';validate_source(source)
        sys.dont_write_bytecode=True;sys.path.insert(0,str(source))
        cls.upstream=importlib.import_module('qlie_unpacker.abmp')

    def tag(self,s):return s.encode().ljust(16,b'\0')

    def test_synthetic_container_payload_span_and_nested_provenance(self):
        inner=self.tag('abmp12')+self.tag('abdata14')+struct.pack('<I',4)+b'OWN!'
        outer=self.tag('abmp12')+self.tag('abdata13')+struct.pack('<I',len(inner))+inner
        r=inspect_container(outer,self.upstream)
        self.assertEqual(r['status'],'verified');m=r['members'][0]
        self.assertEqual(m['raw_bytes_reference']['offset'],36)
        self.assertEqual(m['nested']['container_sha256'],digest(inner))
        self.assertEqual(m['nested']['members'][0]['raw_bytes_reference']['offset'],36)
        self.assertEqual(m['nested']['container_chain'][0]['parent_raw_reference']['container_sha256'],digest(outer))

    def test_unknown_section_retains_partial_evidence_and_error(self):
        raw=self.tag('abmp12')+self.tag('not_supported')
        r=inspect_container(raw,self.upstream)
        self.assertEqual(r['status'],'unsupported');self.assertTrue(r['errors'])
        self.assertEqual(r['tags'][0]['tag'],'not_supported')

    def test_nesting_limit_is_not_silently_ignored(self):
        raw=self.tag('abmp12')
        r=inspect_container(raw,self.upstream,depth=MAX_DEPTH)
        self.assertEqual(r['errors'][0]['category'],'nesting_limit')


if __name__=='__main__':unittest.main()
