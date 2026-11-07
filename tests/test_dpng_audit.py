"""Owned pixels only; counterfactual models are not original-engine oracles."""
import io
import struct
import unittest

from tools.dpng_audit import audit_pixels,difference,MAX_TILES
from tools.mangekyou_p0 import ProbeError,dpng_metadata

try:
    from PIL import Image
except ImportError:
    Image=None


def fixture(tiles,size=(2,1)):
    data=b'DPNG'+struct.pack('<4I',1,len(tiles),*size)
    for x,y,w,h,color,flag in tiles:
        out=io.BytesIO()
        if color is not None:Image.new('RGBA',(w,h),color).save(out,format='PNG')
        payload=out.getvalue();data+=struct.pack('<7I',x,y,w,h,len(payload),flag,0)+payload
    return data


def owned_paste_oracle(data):
    """Only a test double for the explicitly characterized upstream operation."""
    meta=dpng_metadata(data);image=Image.new('RGBA',(meta['width'],meta['height']))
    for tile in meta['tiles']:
        if tile['length']:
            at=tile['byte_offset']+28
            with Image.open(io.BytesIO(data[at:at+tile['length']])) as source:image.paste(source.convert('RGBA'),(tile['x'],tile['y']))
    out=io.BytesIO();image.save(out,format='PNG');return out.getvalue()


@unittest.skipIf(Image is None,'Research Python with Pillow required; this is not a success')
class DpngAuditTests(unittest.TestCase):
    def test_overlapping_half_alpha_distinguishes_models(self):
        data=fixture([(0,0,1,1,(255,0,0,255),0),(0,0,1,1,(0,0,255,128),0)])
        row=audit_pixels(data,owned_paste_oracle)
        self.assertEqual(row['rectangle_overlap_pairs'],[[0,1]])
        self.assertEqual(row['source_over_counterfactual']['alpha_difference_count'],1)
        self.assertEqual(row['source_over_counterfactual']['rgb_difference_with_either_alpha_nonzero'],1)
        self.assertEqual(row['original_engine_equivalence'],'not_tested')

    def test_flagged_empty_tile_still_fills_rows_and_can_erase_earlier_copy(self):
        data=fixture([(0,0,1,1,(1,2,3,255),0),(0,0,0,1,None,1)])
        row=audit_pixels(data,owned_paste_oracle);candidate=row['flagged_fill_candidate']
        self.assertEqual(candidate['alpha_difference_count'],1)
        self.assertEqual(candidate['rgb_difference_at_both_alpha_zero'],1)
        self.assertEqual(len(row['fill_action_conflicts']),1)
        self.assertEqual(row['tiles'][1]['decode_status'],'not_tested')

    def test_disjoint_flagged_rows_differ_only_in_transparent_uncovered_rgb(self):
        data=fixture([(1,0,1,1,(1,2,3,128),1)])
        row=audit_pixels(data,owned_paste_oracle)
        self.assertEqual(row['rectangle_overlap_pairs'],[])
        self.assertEqual(row['flagged_fill_candidate']['rgb_difference_at_both_alpha_zero'],1)
        self.assertEqual(row['flagged_fill_candidate']['alpha_difference_count'],0)
        self.assertEqual(row['flagged_fill_candidate']['rgb_difference_with_either_alpha_nonzero'],0)

    def test_transparent_rgb_is_not_silently_discarded(self):
        a=Image.new('RGBA',(1,1),(50,60,70,0));b=Image.new('RGBA',(1,1))
        self.assertEqual(difference(a,b)['rgb_difference_at_both_alpha_zero'],1)
        self.assertEqual(difference(a,b)['rgb_difference_with_either_alpha_nonzero'],0)

    def test_unreviewed_flag_is_explicit_even_when_low_byte_is_one(self):
        row=audit_pixels(fixture([(1,0,1,1,(1,2,3,0),257)]),owned_paste_oracle)
        self.assertEqual(row['status'],'unsupported');self.assertTrue(row['unknown_reasons'])

    def test_dimension_bounds_truncation_and_work_limits_fail(self):
        data=fixture([(0,0,1,1,(1,2,3,255),0)])
        for malformed in [data[:-1],data+b'x',data[:20]+struct.pack('<I',3)+data[24:],
            fixture([(0,0,0,0,None,0)]*(MAX_TILES+1)),
            b'DPNG'+struct.pack('<4I',1,0,4000001,1)]:
            with self.subTest(length=len(malformed)),self.assertRaises(ProbeError):audit_pixels(malformed,owned_paste_oracle)
        changed=bytearray(data);struct.pack_into('>I',changed,64,2)
        with self.assertRaisesRegex(ProbeError,'dimension'):audit_pixels(bytes(changed),owned_paste_oracle)

    def test_upstream_mismatch_and_wrong_comparison_shape_fail(self):
        data=fixture([(0,0,1,1,(1,2,3,255),0)])
        wrong=io.BytesIO();Image.new('RGBA',(2,1)).save(wrong,format='PNG')
        with self.assertRaisesRegex(ProbeError,'characterization'):audit_pixels(data,lambda _:wrong.getvalue())
        with self.assertRaises(ProbeError):difference(Image.new('RGB',(1,1)),Image.new('RGBA',(1,1)))


if __name__=='__main__':unittest.main()
