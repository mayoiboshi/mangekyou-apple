#!/usr/bin/env python3
"""Bounded DPNG pixel statistics and counterfactual comparisons; no image export."""
import argparse
from collections import Counter
import hashlib
import io
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,dpng_metadata,read_bounded,safe_member_name,upstream_call,write_json
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,dpng_metadata,read_bounded,safe_member_name,upstream_call,write_json
    from control_state_analysis import processing_deadline

MAX_SOURCE=16*1024*1024
MAX_PIXELS=4_000_000
MAX_TILES=32


def sha(data):return hashlib.sha256(data).hexdigest()


def overlap(a,b):
    return (max(a[0],b[0])<min(a[2],b[2]) and max(a[1],b[1])<min(a[3],b[3]))


def difference(a,b):
    from PIL import ImageChops
    if a.mode!='RGBA' or b.mode!='RGBA' or a.size!=b.size:raise ProbeError('dpng_comparison_shape')
    channels=ImageChops.difference(a,b).split()
    binary=lambda channel:channel.point([0]+[255]*255)
    count=lambda channel:channel.histogram()[255]
    rgb=binary(ImageChops.lighter(ImageChops.lighter(channels[0],channels[1]),channels[2]))
    visible=binary(ImageChops.lighter(a.getchannel('A'),b.getchannel('A')))
    return dict(pixel_difference_count=count(ImageChops.lighter(rgb,binary(channels[3]))),
        alpha_difference_count=count(binary(channels[3])),
        rgb_difference_with_either_alpha_nonzero=count(ImageChops.multiply(rgb,visible)),
        rgb_difference_at_both_alpha_zero=count(ImageChops.multiply(rgb,ImageChops.invert(visible))))


def audit_pixels(data,decode):
    """Call a pinned upstream decoder; models characterize candidates, not a new converter."""
    from PIL import Image,ImageDraw
    if len(data)>MAX_SOURCE:raise ProbeError('dpng_source_limit')
    meta=dpng_metadata(data)
    if meta['width']*meta['height']>MAX_PIXELS or len(meta['tiles'])>MAX_TILES:raise ProbeError('dpng_audit_limit')
    if sum(t['width']*t['height'] for t in meta['tiles'])>MAX_PIXELS*2:raise ProbeError('dpng_tile_pixel_budget')
    size=(meta['width'],meta['height']);Image.MAX_IMAGE_PIXELS=MAX_PIXELS
    pasted=Image.new('RGBA',size);composited=Image.new('RGBA',size);filled=Image.new('RGBA',size)
    coverage=Image.new('L',size);draw=ImageDraw.Draw(coverage)
    rows=[];rects=[];actions=[];unknown=[]
    if meta['unknown_header'] not in {0,1}:unknown.append('unreviewed_header_field')
    for tile in meta['tiles']:
        x,y,w,h=(tile[k] for k in ['x','y','width','height']);start=tile['byte_offset']+28
        payload=data[start:start+tile['length']];u1,u2=tile['unknown_fields']
        ref=dict(offset=tile['byte_offset'],length=28+len(payload),sha256=sha(data[tile['byte_offset']:start+len(payload)]))
        row=dict(index=tile['index'],x=x,y=y,width=w,height=h,length=len(payload),
            unknown_fields=[u1,u2],raw_bytes_reference=ref,decode_status='not_tested')
        if u1 not in {0,1} or u2:unknown.append('unreviewed_tile_fields:'+str(tile['index']))
        # Conditional model from selected x86 instructions; native allocation and scheduler unknown.
        if (u1&255)==1 and h:
            filled.paste((136,136,136,0),(0,y,size[0],y+h))
            actions.append((tile['index'],'fill',(0,y,size[0],y+h)))
        if payload:
            if len(payload)<33 or payload[12:16]!=b'IHDR' or struct.unpack_from('>I',payload,8)[0]!=13:
                raise ProbeError('dpng_png_ihdr')
            pw,ph,depth,color=struct.unpack_from('>IIBB',payload,16)
            if (pw,ph)!=(w,h):raise ProbeError('dpng_tile_dimension_mismatch')
            if depth!=8 or color not in {2,6}:unknown.append('unreviewed_png_layout:'+str(tile['index']))
            with Image.open(io.BytesIO(payload)) as source:
                source.load()
                if source.size!=(w,h) or source.format!='PNG':raise ProbeError('dpng_tile_decode_shape')
                rgba=source.convert('RGBA')
            alpha=rgba.getchannel('A').histogram()
            row.update(decode_status='verified',bit_depth=depth,color_type=color,
                alpha_counts=dict(zero=alpha[0],partial=sum(alpha[1:255]),opaque=alpha[255]),rgba_sha256=sha(rgba.tobytes()))
            pasted.paste(rgba,(x,y));composited.alpha_composite(rgba,(x,y));filled.paste(rgba,(x,y))
            rect=(x,y,x+w,y+h);rects.append((tile['index'],rect));actions.append((tile['index'],'copy',rect))
            draw.rectangle((x,y,x+w-1,y+h-1),fill=255)
        rows.append(row)
    converted=decode(data)
    if len(converted)>MAX_SOURCE:raise ProbeError('dpng_converted_limit')
    with Image.open(io.BytesIO(converted)) as upstream:
        if upstream.size!=size:raise ProbeError('dpng_upstream_canvas_shape')
        upstream.load();actual=upstream.convert('RGBA')
    match=difference(pasted,actual)
    if match['pixel_difference_count']:raise ProbeError('dpng_upstream_overwrite_characterization_mismatch')
    overlaps=[[a,b] for i,(a,r) in enumerate(rects) for b,s in rects[i+1:] if overlap(r,s)]
    fill_conflicts=[dict(first_tile=a[0],second_tile=b[0]) for i,a in enumerate(actions) for b in actions[i+1:]
        if a[0]!=b[0] and 'fill' in {a[1],b[1]} and overlap(a[2],b[2])]
    return dict(status='inferred' if not unknown else 'unsupported',scope='Sample decode/statistics plus conditional pixel models; no original renderer execution',
        input_sha256=sha(data),width=size[0],height=size[1],unknown_header=meta['unknown_header'],tiles=rows,
        nonempty_tiles=len(rects),rectangle_overlap_pairs=overlaps,fill_action_conflicts=fill_conflicts,
        covered_pixels=coverage.histogram()[255],uncovered_pixels=size[0]*size[1]-coverage.histogram()[255],
        upstream_decode_status='verified',upstream_rgba_sha256=sha(actual.tobytes()),
        overwrite_characterization=dict(status='verified',**match),
        source_over_counterfactual=dict(status='inferred',rgba_sha256=sha(composited.tobytes()),**difference(actual,composited)),
        flagged_fill_candidate=dict(status='inferred',rgba_sha256=sha(filled.tobytes()),**difference(actual,filled)),
        initial_canvas_zero_assumption='inferred',original_engine_equivalence='not_tested',
        parallel_order='not_tested',unknown_reasons=unknown,images_written=False)


def audit_documents(assets,items,source):
    if not 1<=len(items)<=64:raise ProbeError('dpng_sample_count_limit')
    rows=[];seen=set();total=0
    for item in items:
        relative=safe_member_name(item['path'])
        if relative in seen:raise ProbeError('dpng_duplicate_source')
        seen.add(relative);row=dict(source_file=relative,source_sha256=item['sha256'],status='unsupported',errors=[])
        try:
            data=read_bounded(assets/relative,MAX_SOURCE);total+=len(data)
            if total>128*1024*1024:raise ProbeError('dpng_total_byte_limit')
            if sha(data)!=item['sha256']:raise ProbeError('dpng_source_identity')
            detail=upstream_call(source,'dpng-audit',assets/relative)
            if detail.get('errors') or detail.get('input_sha256')!=item['sha256']:
                raise ProbeError('dpng_worker_failure_or_identity:'+json.dumps(detail.get('errors',[])))
            row.update(detail)
            if sha(read_bounded(assets/relative,MAX_SOURCE))!=item['sha256']:raise ProbeError('dpng_source_changed')
        except (OSError,ValueError) as exc:row.update(status='unsupported',errors=[dict(category=type(exc).__name__,detail=str(exc))])
        rows.append(row)
    return rows


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--assets-dir',required=True,type=Path)
    p.add_argument('--source',type=Path,default=ROOT/'.research/upstream/qlie-unpack')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/dpng-audit-report.json');args=p.parse_args()
    assets=absolute(args.assets_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('dpng_summary_must_be_P1')
    if assets==output or assets in output.parents or output in assets.parents:raise ProbeError('dpng_input_output_overlap')
    manifest=json.loads(read_bounded(ROOT/'reports/p0/asset-report.json'));native_bytes=read_bounded(ROOT/'reports/p1/dpng-native-report.json')
    native=json.loads(native_bytes);required={'flag_one_fill_extents','tile_work_order','fill_constant','fill_stores','rgba_tail_store','rgb_tail_store'}
    if native.get('errors') or native.get('independent_collection',{}).get('status')!='verified' or not required<=set(
        r['id'] for r in native['observations'] if r['status']=='verified'):raise ProbeError('dpng_native_facts_missing')
    items=[r for r in manifest['items'] if r.get('format')=='DPNG']
    with processing_deadline(120):rows=audit_documents(assets,items,args.source)
    report=dict(schema_version=1,status='inferred' if all(r['status']=='inferred' for r in rows) else 'unsupported',dataset='real',
        scope='Six existing bounded P0 samples only; candidate fill and alpha comparisons do not establish rendering equivalence',
        native_report='reports/p1/dpng-native-report.json',native_report_sha256=sha(native_bytes),items=rows,
        sample_count=len(rows),status_counts=dict(Counter(r['status'] for r in rows)),
        nonempty_tile_count=sum(r.get('nonempty_tiles',0) for r in rows),
        overlapping_sample_count=sum(bool(r.get('rectangle_overlap_pairs')) for r in rows),
        original_engine_equivalence='not_tested',real_overlap_equivalence='not_tested',
        original_files_written=False,external_game_data_uploads=False,images_written=False)
    write_json(output,report);print(json.dumps({k:report[k] for k in ['status','sample_count','nonempty_tile_count','overlapping_sample_count']}))
    return 2 if report['status']=='unsupported' else 0


if __name__=='__main__':raise SystemExit(main())
