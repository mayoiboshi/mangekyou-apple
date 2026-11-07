"""Owned text and forged metadata exercise the native evidence boundary."""
import copy
import unittest
from tools.verify_native_scripts import fingerprints,compare_document,validate_trace,sha
from tools.mangekyou_p0 import ProbeError


class NativeScriptEvidenceTests(unittest.TestCase):
    def test_v4_preserves_strict_source_and_equivalence_boundary(self):
        machine,data,doc,lookup=self.table_fixture()
        machine['profile']='experimental_static_contracts_v4'
        self.assertGreater(validate_trace(machine,data,'root.s',doc,source_lookup=lookup),0)
        for key,value in [('originalEngineEquivalence','verified'),('profile','experimental_static_contracts_v5'),('decoded_text','forbidden')]:
            forged=copy.deepcopy(machine);forged[key]=value
            with self.assertRaises(ProbeError): validate_trace(forged,data,'root.s',doc,source_lookup=lookup)

    def table_fixture(self):
        data=b'\\l,"own.txt"';table=b'key=3\n'
        _,doc=fingerprints(data,'root.s');_,tdoc=fingerprints(table,'own.txt')
        def ref(name,body):return dict(sourceFile=name,sourceSHA256=sha(body),byteOffset=0,byteLength=len(body),rangeSHA256=sha(body),lineNumber=1)
        root_ref=ref('root.s',data);table_ref=ref('own.txt',table)
        snapshot=dict(status='inferred',scope='Owned candidate',source=table_ref,entryCount=1,emptyValueCount=0,
            lines=[dict(status='inferred',location=table_ref,action='stored',keySHA256=sha(b'key'),selectedValueSHA256=sha(b'3'))])
        machine=dict(profile='experimental_static_contracts_v3',originalEngineEquivalence='not_tested',phase='finished',steps=1,
            sourceSnapshotCount=2,tableObjectCount=1,tableEntryCount=1,tableAuxiliaryResultFlags='not_tested',tableSnapshots=[snapshot],
            trace=[dict(sequence=1,location=root_ref,recordType='command',command='l',commandSHA256=sha(b'l'),
                status='inferred',action='load_table_candidate',resource=table_ref)])
        def lookup(name):
            if name!='own.txt':raise ProbeError('unbound_fixture')
            return table,tdoc
        return machine,data,doc,lookup

    def test_fingerprints_cover_cp932_alias_bytes_not_roundtrip_encoding(self):
        first,_=fingerprints(b'\\cal,"\xfa\x40"','owned.s')
        second,_=fingerprints(b'\\cal,"\xee\xef"','owned.s')
        self.assertEqual(first['decodedUTF8SHA256'],second['decodedUTF8SHA256'])
        # Same decoded text/shape and byte spans; file/range SHA pins the differing original bytes separately.
        self.assertNotEqual(sha(b'\xfa\x40'),sha(b'\xee\xef'))

    def test_native_comparison_cannot_succeed_with_missing_or_wrong_identity(self):
        data=b'\\cal,1';fp,_=fingerprints(data,'owned.s')
        native=dict(sourceFile='owned.s',sourceSHA256=sha(data),lexical=fp,issue=None)
        self.assertEqual(compare_document(native,data,'owned.s')[0]['status'],'verified')
        forged=copy.deepcopy(native);forged['lexical']['scalarFingerprint']='0'*64
        self.assertEqual(compare_document(forged,data,'owned.s')[0]['mismatched_fields'],['scalarFingerprint'])
        for row in [dict(native,lexical=None),dict(native,sourceSHA256='0'*64),dict(native,sourceFile='../owned.s')]:
            with self.assertRaises(ProbeError):compare_document(row,data,'owned.s')

    def test_stop_location_and_reference_digest_are_validated(self):
        data=b'\\unknown,private';_,doc=fingerprints(data,'owned.s')
        ref=dict(sourceFile='owned.s',sourceSHA256=sha(data),byteOffset=0,byteLength=len(data),rangeSHA256=sha(data),lineNumber=1)
        row=dict(sequence=1,location=ref,status='unsupported',action='stop',reason='unsupported_command',
            recordType='command',command='unknown',commandSHA256=sha(b'unknown'))
        machine=dict(profile='experimental_static_contracts_v1',originalEngineEquivalence='not_tested',trace=[row],steps=1,
            phase='stopped',currentLocation=ref,stopReason='unsupported_command')
        self.assertEqual(validate_trace(machine,data,'owned.s',doc),2)
        for change in ['digest','equivalence','location']:
            forged=copy.deepcopy(machine)
            if change=='digest':forged['trace'][0]['location']['rangeSHA256']='0'*64
            elif change=='equivalence':forged['originalEngineEquivalence']='verified'
            else:forged['currentLocation']={**ref,'byteOffset':1}
            with self.assertRaises(ProbeError):validate_trace(forged,data,'owned.s',doc)

    def test_skipped_source_cannot_be_silently_under_counted(self):
        data=b'\\cal,1\n\\unknown,private';_,doc=fingerprints(data,'owned.s')
        ref=dict(sourceFile='owned.s',sourceSHA256=sha(data),byteOffset=0,byteLength=len(data),rangeSHA256=sha(data),lineNumber=1)
        first={**ref,'byteLength':6,'rangeSHA256':sha(data[:6])}
        machine=dict(profile='experimental_static_contracts_v1',originalEngineEquivalence='not_tested',steps=1,phase='ready',
            trace=[dict(sequence=1,location=first,status='inferred',action='branch',recordType='command',command='cal',commandSHA256=sha(b'cal'),
                skipped=dict(location=ref,recordCount=1,recordTypes={'command':1}))])
        with self.assertRaisesRegex(ProbeError,'skipped_span_accounting'):validate_trace(machine,data,'owned.s',doc)

    def test_public_boundary_rejects_added_operand_or_variable_content(self):
        data=b'\\cal,1';_,doc=fingerprints(data,'owned.s')
        for extra in [{'decodedText':'private'},{'variableCounts':{'privateName':1}}]:
            machine=dict(profile='experimental_static_contracts_v1',originalEngineEquivalence='not_tested',trace=[],steps=0,phase='ready',**extra)
            with self.assertRaises(ProbeError):validate_trace(machine,data,'owned.s',doc)

    def test_cross_file_trace_requires_a_pinned_source_lookup_for_every_reference(self):
        root=b'\\sub,@@Work,"worker.s"';other=b'@@Work\n\\unknown,private'
        _,root_doc=fingerprints(root,'root.s');_,other_doc=fingerprints(other,'copy/worker.s')
        def ref(name,data,a,b,line):return dict(sourceFile=name,sourceSHA256=sha(data),byteOffset=a,byteLength=b-a,rangeSHA256=sha(data[a:b]),lineNumber=line)
        caller=ref('root.s',root,0,len(root),1);target=ref('copy/worker.s',other,0,6,1);stopped=ref('copy/worker.s',other,7,len(other),2)
        rows=[dict(sequence=1,location=caller,status='inferred',action='module_call',recordType='command',command='sub',commandSHA256=sha(b'sub'),target=target),
            dict(sequence=2,location=stopped,status='unsupported',action='stop',recordType='command',command='unknown',commandSHA256=sha(b'unknown'),reason='unsupported_command')]
        machine=dict(profile='experimental_static_contracts_v2',originalEngineEquivalence='not_tested',trace=rows,steps=2,
            phase='stopped',currentLocation=stopped,stopReason='unsupported_command',moduleSnapshotCount=2,moduleSnapshotBytes=len(root)+len(other))
        with self.assertRaisesRegex(ProbeError,'without_pinned_lookup'):validate_trace(machine,root,'root.s',root_doc)
        def lookup(name):
            if name!='copy/worker.s':raise ProbeError('unknown_source')
            return other,other_doc
        self.assertEqual(validate_trace(machine,root,'root.s',root_doc,source_lookup=lookup),4)
        changed=copy.deepcopy(machine);changed['trace'][0]['target']['rangeSHA256']='0'*64
        with self.assertRaisesRegex(ProbeError,'byte_reference'):validate_trace(changed,root,'root.s',root_doc,source_lookup=lookup)

    def test_table_source_lines_and_value_hashes_match_independent_model(self):
        machine,data,doc,lookup=self.table_fixture()
        self.assertEqual(validate_trace(machine,data,'root.s',doc,source_lookup=lookup),4)
        for name in ['value','count','private','flags','offset']:
            bad=copy.deepcopy(machine)
            if name=='value':bad['tableSnapshots'][0]['lines'][0]['selectedValueSHA256']='0'*64
            elif name=='count':bad['tableSnapshots'][0]['entryCount']=2
            elif name=='private':bad['tableSnapshots'][0]['decodedText']='private'
            elif name=='flags':bad['tableAuxiliaryResultFlags']='verified'
            else:bad['tableSnapshots'][0]['lines'][0]['location']['byteOffset']=1
            with self.subTest(name=name),self.assertRaises(ProbeError):validate_trace(bad,data,'root.s',doc,source_lookup=lookup)

    def test_table_fields_cannot_be_added_to_legacy_profiles(self):
        machine,data,doc,lookup=self.table_fixture();machine['profile']='experimental_static_contracts_v2'
        with self.assertRaisesRegex(ProbeError,'require_v3'):validate_trace(machine,data,'root.s',doc,source_lookup=lookup)


if __name__=='__main__':unittest.main()
