"""Owned call spellings and index geometry; no frame or game execution."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from tools.frame_scope_audit import return_projection,site_shape,analyze_documents
from tools.mangekyou_p0 import ProbeError
from tools.qlie_lex import lex


def command(text):
    return next(r for r in lex(text.encode(),'owned.s',field_model='native_grouping')['records'] if r['record_type']=='command')


class FrameScopeAuditTests(unittest.TestCase):
    def test_ordinary_return_projects_to_retained_caller(self):
        r=return_projection(4,2);self.assertEqual(r['retained_count'],3);self.assertEqual(r['resume_data_source_index'],3)
        self.assertEqual(r['removed_count'],1);self.assertEqual(r['actual_return'],'not_tested')

    def test_nonlocal_return_uses_first_removed_frame_not_top(self):
        r=return_projection(5,1);self.assertEqual(r['resume_data_source_index'],2)
        self.assertEqual(r['removed_count'],3);self.assertEqual(r['result_restore_condition'],'first_removed_routine_flag')

    def test_invalid_targets_and_projection_limits_are_explicit(self):
        for count,target in [(0,0),(1,0),(4,-1),(4,3),(4,4)]:
            with self.subTest(count=count,target=target):self.assertEqual(return_projection(count,target)['status'],'unsupported')
        for count,target in [(1025,0),(True,0),(4,1.0)]:
            with self.subTest(count=count,target=target),self.assertRaises(ProbeError):return_projection(count,target)

    def test_call_variants_keep_packing_and_snapshot_roles_distinct(self):
        rows={t:site_shape(command('\\'+t+',@@Own,,"privateValue"')) for t in ['sub','subp','subr']}
        self.assertEqual(rows['subp']['packing_role'],'raw_field_tail_merge_candidate')
        self.assertIn('snapshot',rows['subr']['result_snapshot_role'])
        self.assertNotEqual(rows['sub']['result_snapshot_role'],rows['subr']['result_snapshot_role'])
        for row in rows.values():
            self.assertEqual(row['new_routine_scope'],'init_clears_sixteen_candidate');self.assertEqual(row['actual_call'],'not_tested')
            self.assertNotIn('privateValue',json.dumps(row))

    def test_returns_are_target_roles_and_never_return_values(self):
        self.assertEqual(site_shape(command('\\ret'))['target_role'],'default_count_minus_two_candidate')
        r=site_shape(command('\\ret,privateTarget'));self.assertEqual(r['target_role'],'normalized_named_context_candidate')
        self.assertNotIn('privateTarget',json.dumps(r))
        self.assertEqual(site_shape(command('\\ret,one,two'))['status'],'unsupported')

    def test_non_frame_command_is_not_silently_annotated(self):
        with self.assertRaises(ProbeError):site_shape(command('\\scp,rep'))

    def test_all_versions_and_utf16_source_positions_are_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();items=[]
            for name,data in [('one.s',b'\\sub,@@Own,,"privateValue"\n\\ret'),('two.s',b'\xff\xfe'+'\\subp,@@Own,,"字"\n\\ret'.encode('utf-16le'))]:
                (root/name).write_bytes(data);items.append(dict(source_file=name,sha256=hashlib.sha256(data).hexdigest()))
            rows,files=analyze_documents(root,items);self.assertEqual((len(rows),len(files)),(4,2))
            for row in rows:
                data=(root/row['source_file']).read_bytes();ref=row['raw_bytes_reference']
                self.assertEqual(hashlib.sha256(data[ref['offset']:ref['offset']+ref['length']]).hexdigest(),ref['sha256'])
            self.assertNotIn('privateValue',json.dumps(rows))

    def test_hash_duplicate_and_symlink_failures_are_retained_as_rejections(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();data=b'\\ret';(root/'one.s').write_bytes(data)
            item=dict(source_file='one.s',sha256=hashlib.sha256(data).hexdigest())
            with self.assertRaises(ProbeError):analyze_documents(root,[item,item])
            with self.assertRaises(ProbeError):analyze_documents(root,[dict(item,sha256='0'*64)])
            (root/'alias.s').symlink_to(root/'one.s')
            with self.assertRaises((OSError,ProbeError)):analyze_documents(root,[dict(item,source_file='alias.s')])


if __name__=='__main__':unittest.main()
