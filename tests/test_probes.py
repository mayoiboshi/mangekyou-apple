import hashlib
import json
import os
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

from tools.mangekyou_p0 import (ProbeError, MAX_ENTRIES, MAX_PIXELS, collision_key,
    dpng_metadata, footer_probe, inventory, inspect_asset, read_bounded, reference_graph,
    run, safe_member_name, script_probe, signature, tokenize_tag, write_json)


class WorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name).resolve()

    def tearDown(self):
        self.tmp.cleanup()

    def test_inventory_signatures_hashes_and_no_follow(self):
        game = self.root / 'game'; game.mkdir()
        (game / 'audio.fake').write_bytes(b'OggS' + bytes(32))
        (game / 'dll').mkdir()
        (game / 'dll/test.dll').write_bytes(b'MZ' + bytes(80))
        (game / 'alias').symlink_to(game / 'dll', target_is_directory=True)
        (game / 'data.pack').write_bytes(b'bad')
        before = {p.name:p.read_bytes() for p in game.iterdir() if p.is_file()}
        result = inventory(game)
        self.assertEqual(result['file_count'], 3)
        self.assertEqual(result['total_bytes'], 36+82+3)
        self.assertEqual(result['errors'][0]['category'], 'symlink_rejected')
        records = {x['path']:x for x in result['files']}
        self.assertEqual(records['audio.fake']['signature_type'], 'Ogg')
        self.assertEqual(records['data.pack']['sha256'], hashlib.sha256(b'bad').hexdigest())
        self.assertEqual(before, {p.name:p.read_bytes() for p in game.iterdir() if p.is_file()})

    def test_input_symlink_parent_is_rejected(self):
        real = self.root / 'real'; real.mkdir(); (real/'a').write_bytes(b'A')
        (self.root / 'alias').symlink_to(real, target_is_directory=True)
        with self.assertRaises(OSError): read_bounded(self.root/'alias/a')

    def test_size_limit(self):
        p=self.root/'big'; p.write_bytes(b'12345')
        with self.assertRaisesRegex(ProbeError, 'size_limit'): read_bounded(p, 4)

    def test_fifo_is_not_opened(self):
        p=self.root/'fifo'; os.mkfifo(p)
        self.assertEqual(inventory(self.root)['errors'][0]['category'], 'special_file_rejected')

    def test_output_overlap_is_refused_before_writing(self):
        game=self.root/'game'; game.mkdir()
        with self.assertRaisesRegex(ProbeError, 'overlap'): run(game_dir=game, output=game/'reports')
        self.assertEqual(list(game.iterdir()), [])
        with self.assertRaisesRegex(ProbeError, 'overlap'): run(game_dir=game, output=self.root)

    def test_output_symlink_is_refused(self):
        target=self.root/'target'; target.write_text('original')
        alias=self.root/'alias.json'; alias.symlink_to(target)
        with self.assertRaisesRegex(ProbeError, 'symlink'): write_json(alias, {'x':1})
        self.assertEqual(target.read_text(), 'original')

    def test_empty_baseline_does_not_fabricate_inventory(self):
        run(output=self.root/'reports')
        report=json.loads((self.root/'reports/inventory.json').read_text())
        self.assertEqual(report['status'], 'not_tested')
        self.assertIsNone(report['file_count'])
        self.assertIsNone(report['total_bytes'])
        self.assertEqual(report['dataset'], 'absent')

    def test_repeatable_scan(self):
        game=self.root/'game'; game.mkdir(); (game/'something').write_bytes(b'x')
        first=run(game_dir=game, output=self.root/'out1')
        second=run(game_dir=game, output=self.root/'out2')
        self.assertEqual(first,second)

    def test_asset_symlink_error_propagates(self):
        assets=self.root/'assets';assets.mkdir();(assets/'a').symlink_to('/etc/passwd')
        reports=run(assets_dir=assets, output=self.root/'out')
        self.assertEqual(reports['asset-report.json']['error_count'],1)

    def test_decode_failure_is_reported(self):
        assets=self.root/'assets'; assets.mkdir();(assets/'bad.s').write_bytes(b'\x81')
        reports=run(assets_dir=assets,output=self.root/'out')
        self.assertEqual(reports['script-report.json']['error_count'],1)
        self.assertEqual(reports['script-report.json']['items'][0]['status'],'unsupported')

    def test_archive_failure_is_classified(self):
        game=self.root/'game';game.mkdir();(game/'bad.pack').write_bytes(b'broken')
        reports=run(game_dir=game,output=self.root/'out')
        archive=reports['archive-report.json']
        self.assertEqual(archive['errors_by_category'],{'archive_footer_error':1})
        self.assertIsNone(archive['items'][0]['enumerated_resource_count'])

    def test_asset_signature_beats_extension(self):
        p=self.root/'false.png';p.write_bytes(b'OggSfake')
        r=inspect_asset(p,'false.png')
        self.assertEqual(r['format'],'Ogg')
        self.assertEqual(r['codec_status'],'not_tested')

    def test_oversize_png_becomes_an_explicit_report_error(self):
        p=self.root/'bomb.png'
        p.write_bytes(b'\x89PNG\r\n\x1a\n'+struct.pack('>I',13)+b'IHDR'
                     +struct.pack('>IIBBBBB',MAX_PIXELS+1,1,8,6,0,0,0)+bytes(4))
        result=inspect_asset(p,'bomb.png')
        self.assertEqual(result['status'],'unsupported')
        self.assertIn('pixel_limit',result['errors'][0]['detail'])


class FormatTest(unittest.TestCase):
    def footer(self, version='3.1', count=1, offset=20):
        return ('FilePackVer'+version).encode().ljust(16,b'\0')+struct.pack('<IQ',count,offset)

    def test_footer_version_and_64_bit_offset(self):
        r=footer_probe(self.footer(offset=2**32+3),2**32+2000)
        self.assertEqual(r['version'],'FilePackVer3.1')
        self.assertEqual(r['table_offset'],2**32+3)
        self.assertEqual(r['index_status'],'not_tested')

    def test_footer_rejects_truncation_unknown_version_and_bad_offset(self):
        for tail,size in [(b'abc',3),(self.footer(version='9.9'),1200),(self.footer(offset=1200),1200),
                          (self.footer(count=MAX_ENTRIES+1),1200),(self.footer(),1000)]:
            with self.subTest(tail=tail,size=size),self.assertRaises(ProbeError): footer_probe(tail,size)

    def test_member_paths_reject_windows_and_posix_attacks(self):
        for name in ['../x','a/../x','/x','C:\\x','C:x','\\\\server\\x','a\x00b','a//b','./a','a/','a:stream','x.','x ']:
            with self.subTest(name=name),self.assertRaises(ProbeError):safe_member_name(name)
        self.assertEqual(safe_member_name('dir\\a.png'),'dir/a.png')

    def test_case_unicode_collisions(self):
        self.assertEqual(collision_key('BG/É.png'),collision_key('bg/e\u0301.PNG'))

    def test_dpng_metadata_preserves_unknown_fields(self):
        data=b'DPNG'+struct.pack('<4I',123,1,4,4)+struct.pack('<7I',0,0,0,0,0,44,55)
        r=dpng_metadata(data)
        self.assertEqual(r['unknown_header'],123)
        self.assertEqual(r['tiles'][0]['unknown_fields'],[44,55])
        self.assertEqual(r['conversion_status'],'not_tested')

    def test_dpng_rejects_bad_bounds_and_bombs(self):
        cases=[b'DPNG', b'DPNG'+struct.pack('<4I',1,0,MAX_PIXELS+1,1),
          b'DPNG'+struct.pack('<4I',1,99999,1,1),
          b'DPNG'+struct.pack('<4I',1,1,1,1)+struct.pack('<7I',1,0,1,1,0,0,0),
          b'DPNG'+struct.pack('<4I',1,0,1,1)+b'trailing']
        for data in cases:
            with self.subTest(data=data),self.assertRaises(ProbeError):dpng_metadata(data)

    def test_tag_quotes_and_unknown_escapes(self):
        self.assertEqual(tokenize_tag('x,"a,b",key:"c:d"'),['x','"a,b"','key:"c:d"'])
        with self.assertRaises(ProbeError):tokenize_tag('x,"a')


class ScriptTest(unittest.TestCase):
    def test_cp932_raw_offsets_and_redaction(self):
        lines=['@@start\r\n','【調査者】\r\n','合成です。\r\n','^opaque,"image.png"\r\n']
        raw=''.join(lines).encode('cp932')
        r=script_probe(raw,'sample.s')
        self.assertEqual([x['record_type'] for x in r['records']],['label_candidate','name_candidate','text_candidate','line_tag'])
        pos=0
        for text,record in zip(lines,r['records']):
            size=len(text.encode('cp932'))
            self.assertEqual((record['byte_offset'],record['byte_length']),(pos,size))
            self.assertEqual(record['raw_bytes_reference']['sha256'],hashlib.sha256(raw[pos:pos+size]).hexdigest())
            self.assertIsNone(record['decoded_text']);pos+=size
        self.assertEqual(r['levels']['physical_order'],'verified')
        self.assertEqual(r['levels']['execution_semantics'],'unsupported')
        self.assertEqual(r['encoding_status'],'inferred')

    def test_utf16_bom_and_offsets(self):
        for codec,bom in [('utf-16-le',b'\xff\xfe'),('utf-16-be',b'\xfe\xff'),('utf-8',b'\xef\xbb\xbf')]:
            raw=bom+'@@start\r\n合成\n'.encode(codec)
            r=script_probe(raw,'s.s',True)
            self.assertEqual(r['encoding'],codec)
            self.assertEqual(r['records'][0]['byte_offset'],len(bom))
            self.assertEqual(r['records'][1]['decoded_text'],'合成\n')

    def test_binary_s_is_not_called_dialogue(self):
        for raw in [b'\x00\x01BINARY',b'\x81',b'\xff\xfeA']:
            with self.subTest(raw=raw):
                r=script_probe(raw,'binary.s')
                self.assertEqual(r['status'],'unsupported')
                self.assertEqual(r['unparsed_reference']['length'],len(raw))

    def test_unknown_command_retained(self):
        r=script_probe(b'\\op999,13,17\n','x.s',True)['records'][0]
        self.assertEqual(r['token'],'op999')
        self.assertEqual([v['value'] for v in r['operands']],['13','17'])
        self.assertEqual(r['confidence'],'inferred')
        self.assertIn('unknown',r['unknown_reason'])

    def test_unbalanced_quote_explicit_error(self):
        r=script_probe(b'^weird,"broken\n','x.s')
        self.assertEqual(r['records'][0]['record_type'],'unknown_record')
        self.assertEqual(r['errors'][0]['category'],'script_lexical_error')

    def test_reference_evidence_and_unknown_role(self):
        script=script_probe(b'^x,"BG/a.png"\n^x,"bg/b.png"\n','s.s')
        graph=reference_graph([script],['BG/a.png','BG/b.png'])
        first,second=graph['edges']
        self.assertEqual(first['status'],'verified')
        self.assertEqual(first['relationship_type'],'Unknown')
        self.assertEqual(first['byte_offset'],0)
        self.assertEqual(second['match_method'],'casefold_candidate')
        self.assertEqual(second['status'],'inferred')

    def test_unsafe_reference_is_rejected_not_silently_used(self):
        r=script_probe(b'^x,"C:/secret.png"\n','s.s')
        self.assertEqual(r['errors'][0]['category'],'unsafe_reference')
        self.assertEqual(r['records'][0]['literal_references'],[])

    def test_relative_reference_is_symbolic_and_never_opens_a_path(self):
        r=script_probe(b'^x,"../image.png"\n','data7.pack/ui/s.s')
        self.assertEqual(r['errors'],[])
        graph=reference_graph([r],['data7.pack/image.png'])
        self.assertEqual(graph['edges'][0]['candidates'],['data7.pack/image.png'])

    def test_empty_padding_is_losslessly_referenced_as_span(self):
        raw=b'@@start\r\n'+b'\r\n'*1000+b'^x,1\n'
        r=script_probe(raw,'s.s')
        self.assertEqual(len(r['records']),3)
        span=r['records'][1]
        self.assertEqual(span['record_type'],'empty_span')
        self.assertEqual(span['line_count'],1000)
        self.assertEqual(span['byte_length'],2000)
        self.assertEqual(span['raw_bytes_reference']['sha256'],hashlib.sha256(b'\r\n'*1000).hexdigest())

    def test_duplicate_assets_are_ambiguous(self):
        script=script_probe(b'^x,"image.png"\n','s.s')
        r=reference_graph([script],['data7.pack/image.png','data8.pack/image.png'])
        self.assertEqual(r['edges'][0]['status'],'inferred')


class SampleAndProjectionTest(unittest.TestCase):
    setUp=WorkspaceTest.setUp
    tearDown=WorkspaceTest.tearDown
    def test_sample_never_overwrites_different_file(self):
        from tools.sample_resources import copy_exclusive
        root=self.root/'copies'
        copy_exclusive(root,'a/sample.txt',b'first')
        copy_exclusive(root,'a/sample.txt',b'first')
        with self.assertRaisesRegex(ProbeError,'no overwrite'):
            copy_exclusive(root,'a/sample.txt',b'second')
        self.assertEqual((root/'a/sample.txt').read_bytes(),b'first')

    def test_sample_path_attacks_never_escape(self):
        from tools.sample_resources import copy_exclusive
        root=self.root/'copies';root.mkdir()
        for name in ['../x','/absolute','C:/x']:
            with self.subTest(name=name),self.assertRaises(ProbeError):copy_exclusive(root,name,b'x')
        outside=self.root/'outside';outside.mkdir();(root/'alias').symlink_to(outside,target_is_directory=True)
        with self.assertRaises(OSError):copy_exclusive(root,'alias/x',b'x')
        self.assertEqual(list(outside.iterdir()),[])

    def test_msg_projection_preserves_name_order_newline_and_selection(self):
        from tools.crosscheck_msg import projection
        data='【調査者】\n合成[n]テスト\n^select,"一,二","三"\n^savetext,"説明"\n'.encode('cp932')
        messages,offsets=projection(data,'synthetic.s')
        self.assertEqual(messages,[{'name':'調査者','message':'合成\nテスト'},
            {'message':'一,二'},{'message':'三'},{'message':'説明'}])
        self.assertEqual(len(offsets),4)

    def test_no_text_reference_guessing(self):
        r=script_probe(b'file.png\n','s.s')
        self.assertEqual(r['records'][0]['literal_references'],[])


if __name__ == '__main__':
    unittest.main()
