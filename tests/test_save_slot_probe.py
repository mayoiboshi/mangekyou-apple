import struct
import unittest

from tools.mangekyou_p0 import ProbeError
from tools.save_slot_probe import decode_runlengthpack, decode_state_transform, inspect_system_hash, payload_checksum, probe


class SaveSlotProbeTests(unittest.TestCase):
    def test_system_hash_checks_bucket_and_record_identity(self):
        def sample(bucket, stored_hash):
            records = bytearray()
            for slot in range(256):
                records += struct.pack("<I", int(slot == bucket))
                if slot == bucket:
                    records += struct.pack("<h", 3) + "abc".encode("utf-16le")
                    records += struct.pack("<QI", 0, stored_hash)
            records += struct.pack("<i", 73)
            block = len(records) & ~3
            packed = bytearray(64)
            packed[:14] = b"runlengthpack\0"
            struct.pack_into("<III", packed, 16, 1, block, len(records) - block)
            packed[28:28 + len(records) - block] = records[block:]
            for offset in range(0, block, 252):
                chunk = records[offset:min(offset + 252, block)]
                packed += struct.pack("<b", -(len(chunk) // 4)) + chunk
            header = bytearray(68)
            header[:10] = b"HashVer1.4"
            struct.pack_into("<6I", header, 16, 256, 1, 4, len(packed), 2, 0)
            return bytes(header) + decode_state_transform(packed, 7)
        self.assertEqual(inspect_system_hash(sample(103, 1378), 7)["entry_count"], 1)
        for bucket, hash_value in [(102, 1378), (103, 1379)]:
            with self.assertRaisesRegex(ProbeError, "system_hash_entry_identity"):
                inspect_system_hash(sample(bucket, hash_value), 7)

    def test_system_sections_are_bounded_and_header_must_match(self):
        header = bytearray(124)
        header[:12] = b"IMOSYSDATA12"
        struct.pack_into("<i", header, 56, 2)
        payload = bytes(header) + struct.pack("<i", 4) + b"abcd" + bytes(8)
        envelope = struct.pack("<III", 0xFD324D4E, payload_checksum(payload), len(payload)) + payload
        result = probe(envelope)
        self.assertEqual([section["length"] for section in result["sections"]], [4, 0, 0])
        self.assertEqual(result["system_variables"]["status"], "not_tested")
        with self.assertRaisesRegex(ProbeError, "system_header_verification_mismatch"):
            probe(envelope, system_header_template=bytes(range(44)))
        bad = bytes(header) + struct.pack("<i", 100) + bytes(8)
        wrapped = struct.pack("<III", 0xFD324D4E, payload_checksum(bad), len(bad)) + bad
        with self.assertRaisesRegex(ProbeError, "invalid_system_section_length"):
            probe(wrapped)

    def test_outer_envelope(self):
        # For one zero block both rotated accumulators are 0x1abc9d3d.
        header = struct.pack("<III", 0xFD324D4E, 0x28E49A99, 9)
        slot = header + bytes(8) + b"x"
        result = probe(slot)
        self.assertEqual(result["checksum_ignored_tail_length"], 1)
        self.assertEqual(result["inner_kind"], "unknown")
        self.assertEqual(result["restore"], "not_tested")
        with self.assertRaisesRegex(ProbeError, "envelope_length_mismatch"):
            probe(slot[:-1])
        with self.assertRaisesRegex(ProbeError, "envelope_checksum_mismatch"):
            probe(header + b"y" + slot[13:])

    def test_runlengthpack_repeat_literal_reference_and_tail(self):
        header = bytearray(64)
        header[:14] = b"runlengthpack\0"
        struct.pack_into("<III", header, 16, 1, 16, 1)
        header[28] = ord("!")
        blocks = b"\xffABCD\xc0\x02efgh"
        self.assertEqual(decode_runlengthpack(header + blocks), b"ABCDABCDefghefgh!")
        with self.assertRaisesRegex(ProbeError, "undefined_runlengthpack_reference"):
            decode_runlengthpack(header + b"\xc0")

    def test_uncompressed_slot_reports_reader_cursor(self):
        thread = b"thread\0\0" + struct.pack("<ii", 10, 0)
        reader = struct.pack("<iiiB", 10, 3, 5, 1) + bytes(64)
        paths = struct.pack("<ih", 1, 1) + b"A\0" + b"\x01"
        table = bytes(76 + 256 * 24)
        sound = (b"dsnd\0\0\0\0" + struct.pack("<i", 2) + bytes(2 * 88)
                 + b"ssnd\0\0\0\0" + struct.pack("<i", 1) + bytes(135))
        generator = b"vgene\0\0\0" + struct.pack("<i", 3) + bytes(44)
        image_prefix = bytes(0xA5E + 2 + 33 * 6 + 64 * 2 + 256) + generator * 4
        descriptor = "x:1\\y:2".encode("utf-16le")
        first_image = image_prefix + struct.pack("<h", len(descriptor) // 2) + descriptor + generator * 2 + bytes(50)
        second_image = image_prefix + bytes(52)
        state_prefix = thread + reader + bytes(14) + paths + table + sound
        display = bytes(140 + 2)
        post_display = bytes(69 + 4 + 4 + 27 * 14 + 141)
        variables = b"CalVal\0\0" + struct.pack("<iii", 1, 0, 0)
        engine = bytes(419 + 14 + 69 + 69 + 4 + 68 + 4)
        imotwt = b"imotwt".ljust(264, b"\0")
        final_object = (bytes(53) + struct.pack("<i", 3) + bytes(121) + generator * 4
                        + bytes(10) + struct.pack("<i", 2) + bytes(28 + 16))
        images_end = len(state_prefix) + len(first_image) + len(second_image)
        state = (state_prefix + first_image + second_image + display + post_display
                 + variables + engine + imotwt + final_object)
        slot_header = b"IMOSAVE110".ljust(138, b"\0")
        payload = slot_header + bytes(20) + struct.pack("<i", len(state)) + state
        envelope = struct.pack("<III", 0xFD324D4E, payload_checksum(payload), len(payload))
        report = probe(envelope + payload)
        self.assertEqual(report["reader_record"]["decoded_offset"], 16)
        self.assertEqual(report["reader_metadata"]["utf16_position"], 5)
        self.assertEqual(report["path_record"]["entry_count"], 1)
        self.assertEqual(report["path_record"]["next_decoded_offset"], len(state_prefix) - len(table) - len(sound))
        self.assertEqual(report["reader_metadata"]["next_decoded_offset"], len(state_prefix) - len(paths) - len(table) - len(sound))
        self.assertEqual(report["state_table"]["next_decoded_offset"], len(state_prefix) - len(sound))
        self.assertEqual(report["sound_records"]["dsnd"]["entry_count"], 2)
        self.assertEqual(report["sound_records"]["ssnd"]["next_decoded_offset"], len(state_prefix))
        self.assertEqual(report["image_library"]["generator_group_entry_count"], 2)
        self.assertEqual(report["second_image_library"]["decoded_offset"], len(state_prefix) + len(first_image))
        self.assertEqual(report["second_image_library"]["next_decoded_offset"], images_end)
        self.assertEqual(report["final_object_prefix"]["next_decoded_offset"], len(state))
        self.assertEqual(report["remaining_state"]["length"], 0)
        self.assertEqual(report["state_structure_status"], "verified")
        self.assertEqual(report["restore"], "not_tested")
