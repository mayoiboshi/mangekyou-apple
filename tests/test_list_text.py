"""Owned list text and forged reports, without a Windows-engine oracle."""
import copy
import unittest
from tools.list_text import string_list_text
from tools.verify_native_scripts import fingerprints, validate_trace, sha
from tools.mangekyou_p0 import ProbeError
from tools.research_checks import forbidden_content_fields
import tests.test_native_script_evidence as native_evidence


class ListTextTests(unittest.TestCase):
    def test_markers_comments_duplicates_and_unicode_names_are_preserved_as_metadata(self):
        data=b'key=first//owned\nKEY=second\nmarker=%%none%%\n'+ '鍵=value\n'.encode('utf-8')
        r=string_list_text(b'\xef\xbb\xbf'+data,'owned.txt')
        self.assertEqual((r['lineCount'],r['nameCount'],r['unresolvedNameCount']),(4,2,1))
        self.assertEqual(r['lines'][0]['valueSHA256'],sha(b'first//owned'))
        self.assertEqual(r['lines'][2]['valueSHA256'],sha(b'%%none%%'))
        self.assertEqual(r['lines'][3]['comparisonStatus'],'unsupported')
        self.assertFalse(forbidden_content_fields(r));self.assertNotIn('first//owned',str(r))

    def test_cr_lf_crlf_utf16_and_trailing_terminators_keep_original_spans(self):
        data=b'\xff\xfe'+'a=字😀\rb=2\n\r\nc=3\r\n'.encode('utf-16-le')
        r=string_list_text(data,'owned.txt');self.assertEqual(r['lineCount'],4)
        for n,row in enumerate(r['lines'],1):
            p=row['location'];self.assertEqual(p['lineNumber'],n)
            self.assertEqual(p['rangeSHA256'],sha(data[p['byteOffset']:p['byteOffset']+p['byteLength']]))
        self.assertEqual(string_list_text(b'\xef\xbb\xbf','owned.txt')['lineCount'],0)

    def test_control_bytes_line_caps_source_caps_and_unsafe_paths_fail(self):
        for data,name in [(b'a\0b','owned.txt'),(b'x'*8193,'owned.txt'),(b'a\n'*10001,'owned.txt'),(b' '*(1024*1024+1),'owned.txt'),(b'a','../owned.txt')]:
            with self.subTest(name=name,size=len(data)),self.assertRaises((ProbeError,UnicodeError)):
                string_list_text(data,name)

    def test_v5_snapshot_is_independently_rebuilt_and_cannot_enter_legacy_profile(self):
        machine,data,doc,lookup=native_evidence.NativeScriptEvidenceTests().table_fixture()
        content=b'key=3\n';snapshot=string_list_text(content,'own.txt');snapshot['scope']='Owned candidate'
        machine.update(profile='experimental_static_contracts_v5',tableSnapshots=[],tableObjectCount=0,tableEntryCount=0,
            listObjectCount=1,listLineCount=1,listSnapshots=[snapshot])
        self.assertGreater(validate_trace(machine,data,'root.s',doc,source_lookup=lookup),0)
        for change in ['digest','count','comparison','legacy','raw']:
            wrong=copy.deepcopy(machine)
            if change=='digest':wrong['listSnapshots'][0]['lines'][0]['textSHA256']='0'*64
            elif change=='count':wrong['listSnapshots'][0]['nameCount']=2
            elif change=='comparison':wrong['listSnapshots'][0]['lines'][0]['comparisonStatus']='verified'
            elif change=='legacy':wrong['profile']='experimental_static_contracts_v4'
            else:wrong['listSnapshots'][0]['lines'][0]['decoded_text']='forbidden'
            with self.assertRaises(ProbeError):validate_trace(wrong,data,'root.s',doc,source_lookup=lookup)
