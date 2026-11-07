"""Owned metadata and IPC fixtures; do not implement a PACK parser or copy assets."""
from copy import deepcopy
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest

from tools.gpl_archive_probe import request_for, parse_output, canonical, sha, merge_spans, private_bytes
from tools.mangekyou_p0 import ProbeError
from tools.research_checks import forbidden_content_fields


def metadata():
    key = dict(index=0, name='pack_keyfile_kfueheish15538fa9or.key', offset=0,
        compressed_size=80, original_size=80, compressed=False, encryption_method=1)
    resource = dict(index=1, name='owned.txt', offset=80, compressed_size=3,
        original_size=3, compressed=False, encryption_method=2)
    archive = dict(path='GameData/owned.pack', version='FilePackVer3.1', table_offset=100,
        declared_entry_count=2, index=dict(entries=[key, resource]))
    sample = dict(resource, copy_path='owned.pack/owned.txt', sha256=sha(b'abc'))
    return archive, [sample]


def frames(rows):
    result = bytearray()
    for row in rows:
        if isinstance(row, bytes):
            result.extend(row)
        else:
            data = canonical(row)
            result.extend(struct.pack('<I', len(data))+data)
    return bytes(result)


def protocol(payload=b'abc', header=None, counter='OK: 0, Ignored: 0, Error: 0, Warning: 0'):
    return frames([dict(kind='index', names=['key', 'owned.txt']),
        header or dict(kind='payload', index=1, status='verified', length=len(payload)),
        payload, dict(kind='end', counter=counter)])


class GPLArchiveProbeTests(unittest.TestCase):
    def test_request_allows_only_tail_key_and_explicit_payload_ranges(self):
        archive, selected = metadata()
        r = request_for(archive, selected, 1200)
        self.assertEqual(r['entries'], [dict(index=1, decoded_size=3)])
        self.assertEqual(r['allowed_spans'], [dict(start=0, end=83), dict(start=100, end=1200)])
        self.assertEqual(merge_spans([(1,3), (2,4), (4,6), (10,11)]), [dict(start=1,end=6),dict(start=10,end=11)])

    def test_key_is_bounded_uncompressed_and_never_selected_for_output(self):
        for change in [dict(compressed=True), dict(original_size=81), dict(encryption_method=2), dict(compressed_size=79,original_size=79)]:
            archive, selected = metadata(); archive['index']['entries'][0].update(change)
            with self.subTest(change=change), self.assertRaises(ProbeError):
                request_for(archive, selected, 1200)
        archive, _ = metadata(); key = archive['index']['entries'][0]
        with self.assertRaises(ProbeError):
            request_for(archive, [dict(key,copy_path='owned.pack/'+key['name'])], 1200)

    def test_request_rejects_traversal_overlap_unknown_methods_and_boolean_integers(self):
        for change in [dict(name='../escape'), dict(offset=99), dict(encryption_method=3), dict(offset=True)]:
            archive, selected = metadata(); archive['index']['entries'][1].update(change)
            with self.subTest(change=change), self.assertRaises(ProbeError):
                request_for(archive, selected, 1200)

    def test_source_identity_duplicate_indexes_copy_path_and_size_are_checked(self):
        archive, selected = metadata()
        for bad in [[dict(selected[0], name='changed.txt')], selected*2,
                    [dict(selected[0], copy_path='other.pack/owned.txt')],
                    [dict(selected[0], index=True)]]:
            with self.subTest(bad=bad), self.assertRaises(ProbeError):
                request_for(archive, bad, 1200)
        archive['index']['entries'][1]['original_size'] = 16*1024*1024+1
        selected[0]['original_size'] = 16*1024*1024+1
        with self.assertRaises(ProbeError):
            request_for(archive, selected, 1200)

    def test_protocol_hashes_locally_and_never_returns_payload_body(self):
        _, selected = metadata()
        r = parse_output(protocol(), ['key','owned.txt'], selected)
        self.assertEqual(r[0]['status'], 'verified')
        self.assertEqual(r[0]['observed_sha256'], sha(b'abc'))
        self.assertNotIn('abc', json.dumps(r))
        self.assertFalse(forbidden_content_fields(r))

    def test_wrong_decoded_digest_and_upstream_failure_stay_unsupported(self):
        _, selected = metadata()
        self.assertEqual(parse_output(protocol(b'xyz'), ['key','owned.txt'], selected)[0]['status'], 'unsupported')
        bad = frames([dict(kind='index',names=['key','owned.txt']),dict(kind='payload',index=1,status='unsupported',code='upstream_decode'),
            dict(kind='end',counter='OK: 0, Ignored: 0, Error: 0, Warning: 0')])
        self.assertEqual(parse_output(bad, ['key','owned.txt'], selected)[0]['code'], 'upstream_decode')

    def test_truncated_extra_wrong_order_and_overlarge_frames_are_rejected(self):
        _, selected = metadata()
        bad = [protocol()[:-1], protocol()+b'X', struct.pack('<I', 8*1024*1024+1),
            protocol(header=dict(kind='payload',index=2,status='verified',length=3)),
            protocol(header=dict(kind='payload',index=1,status='verified',length=4))]
        for data in bad:
            with self.subTest(length=len(data)), self.assertRaises((ProbeError, ValueError)):
                parse_output(data, ['key','owned.txt'], selected)

    def test_name_mismatch_warning_or_fatal_cannot_be_counted_as_success(self):
        _, selected = metadata()
        for data, names in [(protocol(),['wrong']), (protocol(counter='OK: 0, Ignored: 0, Error: 0, Warning: 1'),['key','owned.txt']),
                            (frames([dict(kind='fatal',code='upstream_panic')]),['key','owned.txt'])]:
            with self.assertRaises(ProbeError):
                parse_output(data,names,selected)

    def test_private_logs_reject_file_and_parent_symlinks(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp).resolve(); target = root/'owned.txt'; target.write_bytes(b'unchanged')
            (root/'alias').symlink_to(target)
            with self.assertRaises((OSError,ProbeError)):
                private_bytes(root/'alias', b'overwrite')
            (root/'diralias').symlink_to(root, target_is_directory=True)
            with self.assertRaises((OSError,ProbeError)):
                private_bytes(root/'diralias/new.txt', b'write')
            self.assertEqual(target.read_bytes(), b'unchanged')


if __name__ == '__main__':
    unittest.main()
