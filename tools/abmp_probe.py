#!/usr/bin/env python3
"""Bounded metadata-only ABMP inspection, reusing the pinned upstream parser."""
import argparse
from collections import Counter
import json
import io
from pathlib import Path
import struct
import re
import subprocess
import sys

if __package__:
    from .mangekyou_p0 import ROOT, MAX_PIXELS, ProbeError, absolute, dpng_metadata, read_bounded, safe_member_name, signature, write_json
    from .qlie_lex import digest
    from .upstream_worker import validate_source
else:
    from mangekyou_p0 import ROOT, MAX_PIXELS, ProbeError, absolute, dpng_metadata, read_bounded, safe_member_name, signature, write_json
    from qlie_lex import digest
    from upstream_worker import validate_source

MAX_MEMBER=16*1024*1024
MAX_TOTAL=64*1024*1024
MAX_MEMBERS=4096
MAX_DEPTH=4


class Budget:
    def __init__(self,total=MAX_TOTAL,members=MAX_MEMBERS):
        self.total=0;self.members=0;self.total_limit=total;self.member_limit=members

    def claim(self,raw):
        if raw.startswith(b'1PC\xff'):
            if len(raw)<12:raise ProbeError('short_compressed_member')
            expected=struct.unpack_from('<I',raw,8)[0]
        else:expected=len(raw)
        if expected>MAX_MEMBER:raise ProbeError('member_output_limit')
        if self.total+expected>self.total_limit:raise ProbeError('total_output_limit')
        if self.members>=self.member_limit:raise ProbeError('member_count_limit')
        self.total+=expected;self.members+=1
        return expected


def inspect_container(data, upstream, budget=None, chain=None, depth=0, include_extended_values=False):
    budget=budget or Budget();chain=chain or []
    result=dict(status='unsupported',container_sha256=digest(data),container_chain=chain,
        signature=data[:16].split(b'\0',1)[0].decode('ascii','replace'),members=[],tags=[],
        unknown_spans=[],resource_versions=[],errors=[],animation_semantics='not_tested')
    if depth>=MAX_DEPTH:
        result['errors'].append(dict(category='nesting_limit',depth=depth));return result
    if len(data)>MAX_MEMBER:
        result['errors'].append(dict(category='container_size_limit'));return result
    base_reader,base_add,base_resource=upstream.AbmpReader,upstream._add_member,upstream._resource_name
    active=[];decoded_members=[]
    class Reader(base_reader):
        def __init__(self,raw):
            super().__init__(raw);active.append(self)
        def tag(self):
            start=self.offset;value=super().tag()
            if len(result['tags'])>=MAX_MEMBERS:raise ProbeError('tag_limit')
            result['tags'].append(dict(offset=start,length=16,tag=value))
            return value
        def skip(self,size):
            start=self.offset;super().skip(size)
            result['unknown_spans'].append(dict(offset=start,length=size,sha256=digest(data[start:self.offset]),
                meaning='not_tested'))
    def resource_name(reader,tag):
        if tag == 'absnddat12':
            # Some containers end with several empty sound descriptors.
            # Admit only a tail made entirely of this exact observed record shape.
            empty = bytes.fromhex('01000000000000000100000000')
            tag_bytes = b'absnddat12'.ljust(16,b'\0')
            tail = data[reader.offset:]
            if tail.startswith(empty):
                rest = tail[len(empty):]
                slot = tag_bytes+empty
                if len(rest)%len(slot)==0 and rest==slot*(len(rest)//len(slot)):
                    reader.skip(len(empty))
                    return '',None,False
        if tag in {'abimgdat15','absnddat12'}:
            pos=reader.offset
            if pos+4>len(reader.data):raise ProbeError('short_resource_version')
            version=struct.unpack_from('<I',reader.data,pos)[0]
            result['resource_versions'].append(dict(tag=tag,offset=pos,raw_u32=version,
                meaning='not_tested',variant_status='inferred' if version in {1,2} else 'unsupported'))
        return base_resource(reader,tag)
    def collect(members,name,fallback,raw,type_code,cancel=None):
        expected=budget.claim(raw)
        decoded=upstream._decode_member_data(raw,cancel)
        if len(decoded)!=expected:raise ProbeError('member_decoded_size_mismatch')
        offset=active[-1].offset-len(raw)
        if offset<0 or data[offset:offset+len(raw)]!=raw:raise ProbeError('member_source_span_mismatch')
        inferred_name=upstream._member_name(name,fallback,decoded,type_code)
        item=dict(name=inferred_name,name_is_upstream_format_hint=True,type_code=type_code,
            raw_bytes_reference=dict(container_sha256=digest(data),offset=offset,length=len(raw),sha256=digest(raw)),
            compressed=raw.startswith(b'1PC\xff'),decoded_size=len(decoded),decoded_sha256=digest(decoded),
            format=signature(decoded),signature_status='verified',content_decode_status='not_tested')
        item['signature_hex']=decoded[:16].hex()
        if inferred_name == 'data_000.bin' and decoded.startswith(b'\x06\x00NoName'):
            prefixes = ('*rep[', '*value[')
            item['extended_key_markers_absent'] = not any(
                prefix.encode(encoding) in decoded.lower()
                for prefix in prefixes for encoding in ('ascii','utf-16le'))
            if include_extended_values and not item['extended_key_markers_absent']:
                markers = list(re.finditer(rb'\*(?:rep|value)\[', decoded, re.I))
                text_size = int.from_bytes(decoded[32:34], 'little')
                text = decoded[34:34+text_size] if 34+text_size <= len(decoded) else b''
                rows = list(re.finditer(rb'(?:^|\n)\*value\[(\d{1,2})\]=(-?\d{1,10})(?=\r?\n|\x00|$)', text, re.I))
                values = {int(row[1]): int(row[2]) for row in rows}
                if (len(rows) == len(markers) == len(values) and rows
                    and all(0 <= slot < 32 and -(2**31) <= value < 2**31 for slot,value in values.items())
                    and not any(prefix.encode('utf-16le') in decoded.lower() for prefix in prefixes)):
                    item['extended_scalar_values'] = values
            if include_extended_values and len(decoded) >= 34:
                start = 34 + int.from_bytes(decoded[32:34], 'little')
                tag = b'abmotion10' + bytes(6)
                if start < len(decoded) and decoded[start+1:start+17] == tag:
                    count = decoded[start]
                    names = []
                    for match in re.finditer(re.escape(tag), decoded[start+1:]):
                        offset = start + 1 + match.end()
                        size = int.from_bytes(decoded[offset:offset+2], 'little')
                        if not 0 < size <= 256 or offset+2+size >= len(decoded):
                            break
                        try:
                            names.append(decoded[offset+2:offset+2+size].decode('cp932'))
                        except UnicodeDecodeError:
                            break
                    if 0 < count <= 128 and len(names) == count:
                        item['motion_name_candidates'] = names



        if include_extended_values and inferred_name == 'data_000.bin' and decoded.startswith(b'\x06\x00' + 'NoName'.encode('utf-16le')):
            tag = b'abmotion11' + bytes(6)
            if len(decoded) >= 57 and decoded[41:57] == tag:
                count = decoded[40]
                names = []
                for match in re.finditer(re.escape(tag), decoded[41:]):
                    offset = 41 + match.end()
                    size = int.from_bytes(decoded[offset+4:offset+6], 'little') * 2
                    if decoded[offset:offset+4] != b'\x01\x00\x00\x00' or not 0 < size <= 512 or offset+6+size >= len(decoded):
                        break
                    try:
                        names.append(decoded[offset+6:offset+6+size].decode('utf-16le'))
                    except UnicodeDecodeError:
                        break
                if 0 < count <= 128 and len(names) == count:
                    item['motion_name_candidates'] = names

        try:safe_member_name(inferred_name);item['destination_name_status']='verified'
        except ProbeError:item['destination_name_status']='unsupported'  # Data only, never used as output path.
        if decoded.startswith(b'DPNG'):
            item['dpng']=dpng_metadata(decoded)
        elif item['format'] in {'PNG','JPEG','BMP'}:
            from PIL import Image
            import warnings
            Image.MAX_IMAGE_PIXELS=MAX_PIXELS
            with warnings.catch_warnings():
                warnings.simplefilter('error',Image.DecompressionBombWarning)
                with Image.open(io.BytesIO(decoded)) as image:
                    if image.width*image.height>MAX_PIXELS:raise ProbeError('image_pixel_limit')
                    image.load()
                    item.update(content_decode_status='verified',width=image.width,height=image.height,
                        mode=image.mode,rgba_sha256=digest(image.convert('RGBA').tobytes()))
        elif item['format']=='Unknown':item['content_decode_status']='unsupported'
        result['members'].append(item);decoded_members.append((item,decoded))
        members.append(upstream.AbmpMember(inferred_name,decoded))
    try:
        upstream.AbmpReader=Reader;upstream._add_member=collect;upstream._resource_name=resource_name
        if not upstream.is_abmp(data):raise ProbeError('unknown_abmp_signature')
        upstream.extract_abmp(data)
        result['status']='verified'
        if active:result['bytes_consumed']=active[-1].offset
    except Exception as exc:
        result['errors'].append(dict(category=type(exc).__name__,detail=str(exc),
            byte_offset=active[-1].offset if active else 0))
    finally:
        upstream.AbmpReader=base_reader;upstream._add_member=base_add;upstream._resource_name=base_resource
    for item,decoded in decoded_members:
        if upstream.is_abmp(decoded):
            item['nested']=inspect_container(decoded,upstream,budget,chain+[dict(name=item['name'],
                decoded_parent_sha256=item['decoded_sha256'],parent_raw_reference=item['raw_bytes_reference'])],depth+1)
            if item['nested']['status']!='verified':result['status']='unsupported'
        elif decoded.startswith(b'IMOAVI'):
            # Detection only: untrusted frame count and timing fields are not executed.
            item['imoavi_status']='not_tested'
    result.update(total_budget_bytes=budget.total,total_budget_members=budget.members)
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,default=ROOT/'.research/upstream/qlie-unpack')
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--samples',type=Path,default=ROOT/'private/real-p0/sample-report.json')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p1/abmp-report.json')
    ap.add_argument('--input',type=Path,help=argparse.SUPPRESS)
    ap.add_argument('--private-extended-values',action='store_true',help=argparse.SUPPRESS)
    args=ap.parse_args()
    if args.input:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU,(20,20))
        commit=validate_source(args.source)
        sys.dont_write_bytecode=True;sys.path.insert(0,str(absolute(args.source)))
        from qlie_unpacker import abmp
        result=inspect_container(read_bounded(args.input,MAX_MEMBER),abmp,include_extended_values=args.private_extended_values)
        result['upstream_commit']=commit
        print(json.dumps(result,ensure_ascii=False));return 0
    target=absolute(args.output)
    if ROOT/'reports/p1' not in target.parents and ROOT/'private' not in target.parents:
        raise ProbeError('ABMP report must remain in reports/p1 or private/')
    assets=absolute(args.assets_dir)
    if target==assets or assets in target.parents:raise ProbeError('input/output overlap')
    manifest=json.loads(read_bounded(args.samples));items=[]
    for archive in manifest['archives']:
        for sample in archive.get('entries',[]):
            if Path(sample['name']).suffix.lower()!='.b' or sample.get('status')!='verified':continue
            rel=safe_member_name(sample['copy_path']);path=absolute(args.assets_dir)/rel
            item=dict(source_file=rel,origin=dict(archive=archive['archive'],index=sample['index'],
                offset=sample['offset'],archive_sha256=archive['source_archive_sha256']))
            try:
                if digest(read_bounded(path,MAX_MEMBER))!=sample['sha256']:raise ProbeError('sample_sha256_mismatch')
                command=[sys.executable,str(Path(__file__).resolve()),'--source',str(absolute(args.source)),'--input',str(path)]
                proc=subprocess.run(command,capture_output=True,timeout=25)
                if proc.returncode:raise ProbeError('worker_exit:'+str(proc.returncode))
                item.update(json.loads(proc.stdout))
            except (OSError,ValueError,subprocess.SubprocessError) as exc:
                item.update(status='unsupported',errors=[dict(category=type(exc).__name__,detail=str(exc))])
            items.append(item)
    tags=Counter();formats=Counter();member_count=0
    def count(node):
        nonlocal member_count
        tags.update(t['tag'] for t in node.get('tags',[]))
        for member in node.get('members',[]):
            member_count+=1;formats.update([member['format']])
            if 'nested' in member:count(member['nested'])
    for item in items:count(item)
    report=dict(schema_version=1,dataset='real',status='not_tested' if not items else ('verified' if all(i['status']=='verified' for i in items) else 'unsupported'),
        scope='Existing P0 samples only; container boundaries and bounded member decoding, not animation semantics',
        files=len(items),items=items,member_count=member_count,tag_counts=dict(tags),format_counts=dict(formats),
        game_files_written=False,resource_bytes_exported=False,animation_semantics='unsupported',
        limits=dict(member_bytes=MAX_MEMBER,total_bytes_per_worker=MAX_TOTAL,members=MAX_MEMBERS,depth=MAX_DEPTH,
            cpu_seconds=20,wall_seconds=25,hard_rss_cap='unsupported'))
    write_json(args.output,report)
    print(json.dumps({k:report[k] for k in ['status','files','member_count','tag_counts','format_counts']}))
    return 0 if report['status']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
