"""Owned linear decoder output verifies referenced byte extents, not runtime behavior."""
import unittest

from tools.review_native import linear_decode_issues


class LinearWindowCoverageTests(unittest.TestCase):
    def test_complete_instruction_bytes_fit_the_reference(self):
        r=linear_decode_issues('  1000: 5f  \tpop edi\n 1001: c2 04 00  \tret 0x4\n',0x1000,0x1004)
        self.assertFalse(any(r.values()))

    def test_decoded_instruction_can_extend_past_stop_address(self):
        r=linear_decode_issues('1000: ff ff  <unknown>\n1002: ff 13  call [ebx]\n',0x1000,0x1003)
        self.assertEqual(r['unknown_instruction_addresses'],['0x1000'])
        self.assertEqual(r['instruction_span_outside_reference'],['0x1002'])

    def test_missing_bytes_and_before_start_are_not_silently_accepted(self):
        r=linear_decode_issues('fff: 90 \tnop\n1000: ret\n',0x1000,0x1001)
        self.assertEqual(r['instruction_span_outside_reference'],['0xfff'])
        self.assertEqual(r['malformed_instruction_lines'],['0x1000'])


if __name__=='__main__':unittest.main()
