#!/usr/bin/env python3
"""Bounded metadata-only ABMP inspection, reusing the pinned upstream parser."""
import argparse
from collections import Counter
import json
import io
from itertools import islice
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

MAX_MEMBER=32*1024*1024
MAX_CONTAINER=32*1024*1024
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


def legacy_transform_value(value: int) -> int:
    """Translate the two reserved ranges used by the original 0x591d00 converter."""
    if 0x7fbc <= value < 0x7fcc:
        return 0x10000000 + value - 0x7fbc
    if 0x7fd0 <= value < 0x7fe0:
        return 0x10000100 + value - 0x7fd0
    return value


def wide_motion_layers(data, header_end, end):
    """Describe the observed ablayer22 layout without assigning draw semantics."""
    if header_end + 9 > end or data[header_end:header_end+8] != bytes(8):
        return None
    count = data[header_end+8]
    cursor = header_end + 9
    layers = []
    for _ in range(count):
        if cursor + 18 > end or data[cursor:cursor+16] != b'ablayer22' + bytes(7):
            return None
        name_units = struct.unpack_from('<H', data, cursor+16)[0]
        body = cursor + 18 + 2 * name_units
        if body + 3 > end or data[body] != 1:
            return None
        # 0x5929dd reads the count, then 0x5929f7 reads a separate byte.
        key_count = data[body+1]
        first_key = body + 3
        stride = 0x1b8  # Both native loaders read this stride directly into the key array.
        next_layer = first_key + key_count * stride
        if not key_count or next_layer > end:
            return None
        keys = []
        for offset in range(first_key, next_layer, stride):
            time = struct.unpack_from('<i', data, offset)[0]
            raw_type = data[offset+4]  # The native evaluator reads only this byte at 0x58d81a.
            # These offsets match fields in ablayer21. Preserve the raw
            # values until the ablayer22 conversion path is confirmed.
            word_offsets = (0x04, 0x08, 0x0c, 0x1c, 0x20, 0x24, 0x28, 0x84, 0x88, 0xa8, 0xc4)
            key = dict(decoded_offset=offset, time=time, raw_type=raw_type,
                sha256=digest(data[offset:offset+stride]),
                raw_words={hex(field): struct.unpack_from('<i', data, offset+field)[0]
                           for field in word_offsets})
            # 0x57f5c4 consumes these four fields while advancing one layer clock.
            key['time_control_inputs'] = [data[offset+0xd0], *struct.unpack_from('<3i', data, offset+0xd4)]
            if raw_type in (4, 10):
                # The first texture evaluator reads the mode byte and signed
                # input at 0x58c05b and 0x58c096 respectively.
                # 0x58d82e and 0x58d842 copy the draw modes as bytes.
                key['draw_mode_inputs'] = dict(blend=data[offset+8], sampling=data[offset+12])
                key['geometry_inputs'] = dict(
                    source_areas=[list(struct.unpack_from('<4i', data, offset+field))
                                  for field in (0x50, 0x60)],
                    anchor_ratio_inputs=list(struct.unpack_from('<2i', data, offset+0x70)),
                    transform_fields={hex(field): struct.unpack_from('<i', data, offset+field)[0]
                                      for field in range(0x84, 0xac, 4)})
                # 0x58ad83 and 0x58b3af share literal rectangle, anchor and
                # transform values when the selector is zero. Keep the
                # nested raster path to the neutral color inputs at 0x58c2b0.
                additive, multiplier = struct.unpack_from('<2I', data, offset+0xbc)
                transfer, command = struct.unpack_from('<2I', data, offset+0xc8)
                basic_draw_state = all(data[offset+field] == 0 for field in (0x14, 0x48, 0xb0))
                ordinary_texture = raw_type == 4 and (transfer, command) == (255, 0)
                # 0x584ce0 uses the second texture anchor. The direct
                # scanner profile uses two complete surfaces without offsets.
                mask_texture = (raw_type == 10 and transfer <= 255 and command <= 7
                                and data[offset+0x10] == 0
                                and struct.unpack_from('<I', data, offset+0x18)[0] == 0
                                and struct.unpack_from('<2i', data, offset+0x3c) == (0, 0)
                                and key['geometry_inputs']['source_areas'] == [[0, 0, 0, 0]] * 2)
                neutral_draw_state = (basic_draw_state and ordinary_texture
                                      and (additive, multiplier) == (0, 0x00ffffff))
                transform_mode, color_mode = data[offset+0x7c], data[offset+0xb4]
                key['literal_draw_state'] = neutral_draw_state and transform_mode == color_mode == 0
                # These interpolation curves return the current value at zero progress.
                key['literal_draw_state_at_key'] = (neutral_draw_state and transform_mode in (0, 1, 3, 4)
                                                     and color_mode in (0, 1, 3, 4))
                if (basic_draw_state and (ordinary_texture or mask_texture)
                    and transform_mode == 0 and max(additive, multiplier) <= 0x00ffffff):
                    # 0x58dae3 normalizes the shared curve strength. Bits 0/1
                    # of +0x180 independently enable the alpha and RGB modes.
                    key['nested_color_curve'] = dict(
                        mode=color_mode if data[offset+0x180] & 2 else 0,
                        strength=struct.unpack_from('<i', data, offset+0xb8)[0],
                        additive=additive, multiplier=multiplier, transfer=transfer)
                    if mask_texture:
                        key['nested_mask_mode'] = command
                key['first_texture_input'] = dict(mode=data[offset+0x1c],
                                                  number=key['raw_words']['0x24'])
                if raw_type == 4:
                    # The same mode selects the child action at 0x58c0d4.
                    # 0x58bf43/0x58bf89 evaluate the child's independent clock.
                    key['first_texture_input']['action'] = key['raw_words']['0x28']
                    key['child_time_input'] = dict(mode=data[offset+0x2c],
                                                   value=struct.unpack_from('<i', data, offset+0x34)[0])
                else:
                    key['second_texture_number'] = key['raw_words']['0x28']
            blend = data[offset+8]
            if (raw_type == 20 and blend in (0, 7)
                and all(data[offset+f] == 0 for f in (12, 0x10, 0x14, 0x1c, 0x7c, 0xb4))):
                additive, multiplier = struct.unpack_from('<2I', data, offset+0xbc)
                if (struct.unpack_from('<I', data, offset+0x18)[0] == 0
                    and additive == 0 and multiplier <= 0x00ffffff
                    and (blend == 7 or multiplier == 0x00ffffff)
                    and data[offset+0x48] in (0, 1) and data[offset+0x2c] in (0, 1)):
                    key['first_texture_input'] = dict(mode=0, number=key['raw_words']['0x24'])
                    key['draw_mode_inputs'] = dict(blend=blend, sampling=data[offset+12])
                    if multiplier != 0x00ffffff:
                        # 0x587287 passes the evaluated RGB multiplier to the particle draw.
                        key['nested_color_curve'] = dict(mode=0, strength=0, additive=0, multiplier=multiplier)
                    # 0x586b3b–0x586c5f uses the seed and two evaluated areas.
                    # 0x586f7f–0x586fba uses the separately evaluated clock endpoints.
                    key['type20_input'] = dict(
                        first_area=struct.unpack_from('<4i', data, offset+0x50),
                        second_area=struct.unpack_from('<4i', data, offset+0x60),
                        first_area_interpolates=bool(data[offset+0x48] and data[offset+0x178] & 2),
                        second_area_interpolates=bool(data[offset+0x48] and data[offset+0x178] & 4),
                        volume=struct.unpack_from('<3i', data, offset+0x90),
                        seed=struct.unpack_from('<I', data, offset+0xcc)[0],
                        clock_interpolates=bool(data[offset+0x2c]),
                        clock_range=struct.unpack_from('<2i', data, offset+0x34))
                    key['geometry_inputs'] = dict(
                        anchor_ratio_inputs=list(struct.unpack_from('<2i', data, offset+0x70)),
                        transform_fields={hex(field): struct.unpack_from('<i', data, offset+field)[0]
                                          for field in range(0x84, 0xac, 4)})
            if (raw_type in (4, 20)
                and all(data[offset+f] == 0 for f in (8, 12, 0x10, 0x14, 0x1c, 0xb0, 0xb4))
                and struct.unpack_from('<I', data, offset+0x18)[0] == 0
                and struct.unpack_from('<2I', data, offset+0xbc) == (0, 0x00ffffff)
                and struct.unpack_from('<2i', data, offset+0x9c) == (0, 0)
                and (raw_type == 20 and 'type20_input' in key
                     or raw_type == 4 and data[offset+0x48] == 0
                     and key['geometry_inputs']['source_areas'] == [[0, 0, 0, 0]] * 2)
                and data[offset+0x7c] in (0, 1)):
                # 0x58c61b gates Z-angle interpolation; 0x58c662 converts to turns.
                key['particle_raster_mode'] = dict(mode=data[offset+0x7c], flags=data[offset+0x17c])
            elif (raw_type == 20 and 'type20_input' in key and blend == 7
                  and data[offset+0x2c] == 0
                  and struct.unpack_from('<2i', data, offset+0xac) == (100, 0)):
                # 0x58d86d supplies rotation order; 0x58486c dispatches order zero as X, Y, Z.
                key['particle_raster_mode'] = dict(mode=0, flags=data[offset+0x17c], rotation_order=0)
            # 0x58c2c3 gates the mode and 0x58c2de reads the next key's value.
            key['opacity_input'] = dict(mode=data[offset+0xb4] if data[offset+0x180] & 1 else 0,
                                        raw_value=key['raw_words']['0xc4'])
            keys.append(key)
        layers.append(dict(decoded_offset=cursor, length=next_layer-cursor, raw_layer_flag=data[body],
                           raw_layer_flag_offset=body, raw_header_tail=data[body+2], key_stride=stride,
                           key_stride_status='verified', keys=keys))
        cursor = next_layer
    return layers if layers and cursor == end else None


def inspect_container(data, upstream, budget=None, chain=None, depth=0, include_extended_values=False):
    budget=budget or Budget();chain=chain or []
    result=dict(status='unsupported',container_sha256=digest(data),container_chain=chain,
        signature=data[:16].split(b'\0',1)[0].decode('ascii','replace'),members=[],tags=[],
        unknown_spans=[],resource_versions=[],errors=[],animation_semantics='not_tested')
    if depth>=MAX_DEPTH:
        result['errors'].append(dict(category='nesting_limit',depth=depth));return result
    if len(data)>(MAX_CONTAINER if depth == 0 else MAX_MEMBER):
        result['errors'].append(dict(category='container_size_limit'));return result
    base_reader,base_add,base_resource=upstream.AbmpReader,upstream._add_member,upstream._resource_name
    active=[];decoded_members=[]
    class Reader(base_reader):
        def __init__(self,raw):
            super().__init__(raw);active.append(self)
            self.image_index = -1
            self.image_slot = None
            self.image_offsets = None
        def tag(self):
            start=self.offset;value=super().tag()
            self.image_slot = None
            self.image_offsets = None
            if value.startswith('abimgdat'):
                self.image_index += 1
                self.image_slot = self.image_index
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
        start = reader.offset
        result_name = base_resource(reader,tag)
        _, type_code, has_payload = result_name
        if (reader.image_slot is not None and has_payload and reader.offset + 4 <= len(data)
                and struct.unpack_from('<I', data, reader.offset)[0] == 0):
            result.setdefault('empty_image_slots', []).append(dict(
                slot=reader.image_slot, type_code=type_code, size_field_offset=reader.offset))
        if include_extended_values and tag in {'abimgdat13', 'abimgdat14'}:
            second = start + 2 + struct.unpack_from('<H', data, start)[0]
            fields = second + 2 + struct.unpack_from('<H', data, second)[0]
            # The original 0x59800f–0x598057 reads one byte followed by three floats.
            if fields + 13 <= reader.offset:
                reader.image_offsets = dict(offset=fields + 1, original_type_code=data[fields], raw_words=list(
                    struct.unpack_from('<3I', data, fields + 1)))
        if include_extended_values and tag == 'abimgdat15' and version == 1:
            second = start + 6 + 2 * struct.unpack_from('<H', data, start + 4)[0]
            fields = second + 2 + struct.unpack_from('<H', data, second)[0]
            # 0x5983e8–0x598412 reads the three offsets before the one-byte
            # and four-byte fields that precede the payload length.
            if fields + 18 == reader.offset and data[fields] == type_code:
                reader.image_offsets = dict(offset=fields + 1, original_type_code=type_code, raw_words=list(
                    struct.unpack_from('<3I', data, fields + 1)))
                if type_code == 6:
                    # 0x598415 reads the byte stored at image-entry +0x104.
                    reader.image_offsets['nested_surface_flag'] = data[fields + 13]
        return result_name
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
        if include_extended_values and active[-1].image_slot is not None:
            item['image_slot'] = active[-1].image_slot
            if active[-1].image_offsets is not None:
                item['image_anchor_offset_inputs'] = active[-1].image_offsets
        item['signature_hex']=decoded[:16].hex()
        narrow_header = decoded.startswith(b'\x06\x00NoName')
        wide_header = decoded.startswith(b'\x06\x00' + 'NoName'.encode('utf-16le'))
        if (include_extended_values and inferred_name == 'data_000.bin' and narrow_header
                and result['tags'][-1]['tag'] == 'abdata13' and len(decoded) >= 34):
            # 0x594d8d reads the version, then 0x594d9c–0x594db7 reads the two dimensions.
            version, width, height = struct.unpack_from('<iii', decoded, 8)
            if version == 1:
                item['motion_canvas_inputs'] = dict(decoded_offset=12, width=width, height=height)
                # 0x594dba–0x594dd5 reads duration and loop-start fields.
                duration, loop_start = struct.unpack_from('<ii', decoded, 20)
                item['motion_duration_inputs'] = dict(decoded_offset=20, duration=duration, loop_start=loop_start)
                # 0x594dde reads the last header word into resource +0x38.
                raw_threshold, = struct.unpack_from('<i', decoded, 28)
                item['motion_update_threshold'] = dict(
                    decoded_offset=28, raw_value=raw_threshold, effective_value=max(1, raw_threshold))
        if inferred_name == 'data_000.bin' and (narrow_header or wide_header):
            prefixes = ('*rep[', '*value[')
            item['extended_key_markers_absent'] = not any(
                prefix.encode(encoding) in decoded.lower()
                for prefix in prefixes for encoding in ('ascii','utf-16le'))
            if include_extended_values and narrow_header and not item['extended_key_markers_absent']:
                markers = list(re.finditer(rb'\*(?:rep|value)\[', decoded, re.I))
                text_size = int.from_bytes(decoded[32:34], 'little')
                text = decoded[34:34+text_size] if 34+text_size <= len(decoded) else b''
                rows = list(re.finditer(rb'(?:^|\n)\*value\[(\d{1,2})\]=(-?\d{1,10})(?=\r?\n|\x00|$)', text, re.I))
                values = {int(row[1]): int(row[2]) for row in rows}
                if (len(rows) == len(markers) == len(values) and rows
                    and all(0 <= slot < 32 and -(2**31) <= value < 2**31 for slot,value in values.items())
                    and not any(prefix.encode('utf-16le') in decoded.lower() for prefix in prefixes)):
                    item['extended_scalar_values'] = values
            if include_extended_values and narrow_header and len(decoded) >= 34:
                start = 34 + int.from_bytes(decoded[32:34], 'little')
                tag = b'abmotion10' + bytes(6)
                if start < len(decoded) and decoded[start+1:start+17] == tag:
                    count = decoded[start]
                    names = []
                    motions = []
                    for match in re.compile(re.escape(tag)).finditer(decoded, start + 1):
                        motions.append(match)
                        offset = match.end()
                        size = int.from_bytes(decoded[offset:offset+2], 'little')
                        if size > 256 or offset+2+size >= len(decoded):
                            break
                        try:
                            names.append(decoded[offset+2:offset+2+size].decode('cp932'))
                        except UnicodeDecodeError:
                            break
                    if 0 < count <= 128 and len(names) == count:
                        item['motion_name_candidates'] = names
                        layer_tag = re.compile(rb'ablayer(?:18|21)\x00{7}')
                        layouts = []
                        for index, motion in enumerate(motions):
                            name_length = int.from_bytes(decoded[motion.end():motion.end()+2], 'little')
                            count_offset = motion.end() + 2 + name_length
                            end = motions[index + 1].start() if index + 1 < count else len(decoded)
                            expected_layers = decoded[count_offset]
                            layers = list(islice(layer_tag.finditer(decoded, count_offset + 1, end), expected_layers + 1))
                            if (not layers or len(layers) != expected_layers
                                or layers[0].start() != count_offset + 1):
                                continue
                            records = []
                            for j, layer in enumerate(layers):
                                layer_end = layers[j + 1].start() if j + 1 < len(layers) else end
                                version = layer.group()[:9].decode('ascii')
                                record = dict(offset=layer.start(), length=layer_end-layer.start(), tag=version)
                                if layer.end() + 2 <= layer_end:
                                    name_size = int.from_bytes(decoded[layer.end():layer.end()+2], 'little')
                                    body = layer.end() + 2 + name_size
                                    unit = 440 if version == 'ablayer21' else 162
                                    if body + 3 <= layer_end:
                                        record['raw_layer_flag'] = decoded[body]
                                        record['raw_layer_flag_offset'] = body
                                        block_count = decoded[body+1]
                                        if block_count and body + 3 + block_count*unit == layer_end:
                                            record.update(block_count_offset=body+1, block_count=block_count,
                                                block_start=body+3, block_stride=unit)
                                            ticks = [struct.unpack_from('<i', decoded, body+3+i*unit)[0]
                                                for i in range(block_count)]
                                            if len(ticks) > 1 and all(a < b for a, b in zip(ticks, ticks[1:])):
                                                record['key_time_values'] = ticks
                                            image_keys = []
                                            for key_index in range(block_count):
                                                key = body + 3 + key_index*unit
                                                if version == 'ablayer21':
                                                    mode_a, mode_b, number_a, number_b = struct.unpack_from('<4i', decoded, key+0x1c)
                                                else:
                                                    number_a, number_b = decoded[key+6:key+8]
                                                    mode_a, mode_b = decoded[key+0x3e:key+0x40]
                                                    # The original conversion expands legacy variable references.
                                                    number_a, number_b = [
                                                        0x10000000 + n - 0xc8 if 0xc8 <= n < 0xd8 else n
                                                        for n in (number_a, number_b)]
                                                image_fields = dict(offset=key, modes=[mode_a, mode_b],
                                                    numbers=[number_a, number_b])
                                                if version == 'ablayer21':
                                                    image_fields['type'], image_fields['blend'] = struct.unpack_from('<2i', decoded, key+4)
                                                    image_fields['sampling'] = decoded[key+12]
                                                    image_fields['source_areas'] = [
                                                        list(struct.unpack_from('<4i', decoded, key+offset))
                                                        for offset in (0x50, 0x60)]
                                                    image_fields['converted_transform_fields'] = {
                                                        hex(offset): struct.unpack_from('<i', decoded, key+offset)[0]
                                                        for offset in range(0x84, 0xac, 4)
                                                    }
                                                else:
                                                    # 0x591e17–0x591e22 widens both fields unchanged.
                                                    image_fields['type'], image_fields['blend'] = decoded[key+4:key+6]
                                                    image_fields['sampling'] = decoded[key+0x91]
                                                    # 0x591ec3–0x591f20 converts both legacy source rectangles.
                                                    image_fields['source_areas'] = [
                                                        [legacy_transform_value(value) for value in
                                                         struct.unpack_from('<4h', decoded, key+offset)]
                                                        for offset in (0x08, 0x40)
                                                    ]
                                                    # Raw inputs of the original 0x591f52–0x591fe4 conversion.
                                                    image_fields['legacy_transform_inputs'] = {
                                                        'signed16': {
                                                            hex(offset): struct.unpack_from('<h', decoded, key+offset)[0]
                                                            for offset in (0x18, 0x1a, 0x1c, 0x1e, 0x20, 0x22, 0x48, 0x4a, 0x96)
                                                        },
                                                        'signed32_at_0x4d': struct.unpack_from('<i', decoded, key+0x4d)[0],
                                                    }
                                                    raw = image_fields['legacy_transform_inputs']
                                                    values = dict(raw['signed16'], **{'0x4d': raw['signed32_at_0x4d']})
                                                    image_fields['converted_transform_fields'] = {
                                                        hex(new): legacy_transform_value(values[hex(old)])
                                                        for old, new in zip(
                                                            (0x18, 0x1a, 0x4d, 0x1c, 0x1e, 0x96, 0x48, 0x4a, 0x22, 0x20),
                                                            range(0x84, 0xac, 4),
                                                        )
                                                    }
                                                # 0x58c313 -> output 0x6b -> type-11 queue field 0x98.
                                                alpha = (struct.unpack_from('<i', decoded, key+0xc4)[0]
                                                         if version == 'ablayer21' else
                                                         struct.unpack_from('<h', decoded, key+0x35)[0])
                                                # 0x58d85e/0x58d88e/0x58d8a4 copy these
                                                # converted fields into the draw record; 0x58c358
                                                # evaluates +0xc8 and 0x58c370 copies +0xcc.
                                                # Preserve raw values on every key because the next
                                                # key may supply an interpolation endpoint.
                                                if version == 'ablayer21':
                                                    dual = [struct.unpack_from('<i', decoded, key+offset)[0]
                                                            for offset in (0x10, 0x14, 0x18, 0xc8, 0xcc)]
                                                else:
                                                    dual = [decoded[key+0x94], decoded[key+0x92], decoded[key+0x95],
                                                            struct.unpack_from('<h', decoded, key+0x37)[0], decoded[key+0x3a]]
                                                image_fields['dual_texture_raw_inputs'] = dict(layout=version,
                                                    output_b1=dual[0], output_ac=dual[1], output_b2=dual[2],
                                                    key_c8=dual[3], key_cc=dual[4])
                                                if image_fields['type'] == 1:
                                                    # 0x58c258/0x58c29d feed the two color evaluators.
                                                    offsets = (0xbc, 0xc0) if version == 'ablayer21' else (0x24, 0x28)
                                                    image_fields['type1_color_inputs'] = [
                                                        struct.unpack_from('<I', decoded, key + offset)[0]
                                                        for offset in offsets
                                                    ]
                                                if image_fields['type'] == 11:
                                                    # Inputs to the type-11 color evaluators, before interpolation.
                                                    if version == 'ablayer21':
                                                        offsets = (0xbc, 0xc0, 0xc8)
                                                        formats = ('<i', '<i', '<i')
                                                    else:
                                                        offsets = (0x24, 0x28, 0x37)
                                                        formats = ('<I', '<I', '<h')
                                                    image_fields['type11_color_inputs'] = [
                                                        struct.unpack_from(fmt, decoded, key + offset)[0]
                                                        for fmt, offset in zip(formats, offsets)
                                                    ]
                                                if 0 <= alpha <= 255:
                                                    image_fields['literal_opacity_input'] = alpha
                                                # 0x58c1f7 and 0x58c2c3 choose the opacity interpolation mode.
                                                mode_offset = 0xb4 if version == 'ablayer21' else 0x33
                                                alpha_enabled = version == 'ablayer18' or bool(decoded[key+0x180] & 1)
                                                image_fields['opacity_mode_input'] = decoded[key+mode_offset] if alpha_enabled else 0
                                                # 0x58ad83–0x58adba selects the first source rectangle's mode;
                                                # 0x591eb5–0x591ec0 widens these legacy bytes.
                                                image_fields['source_area_mode_input'] = decoded[
                                                    key+(0x48 if version == 'ablayer21' else 0x2d)]
                                                image_fields['source_area_interpolation_flag'] = (
                                                    version == 'ablayer18' or bool(decoded[key+0x178] & 2))
                                                image_fields['source_area_strength_input'] = (
                                                    struct.unpack_from('<i', decoded, key+0x4c)[0]
                                                    if version == 'ablayer21' else decoded[key+0x2e])
                                                # 0x58b3af selects the shared XY position interpolation mode.
                                                position_enabled = version == 'ablayer18' or bool(decoded[key+0x17c] & 2)
                                                image_fields['position_mode_input'] = (
                                                    decoded[key+(0x7c if version == 'ablayer21' else 0x30)] if position_enabled else 0)
                                                image_fields['position_strength_input'] = (
                                                    struct.unpack_from('<i', decoded, key+0x80)[0]
                                                    if version == 'ablayer21' else decoded[key+0x31])
                                                # 0x57f759 gates time control independently of the draw type.
                                                image_fields['time_control_inputs'] = (
                                                    [decoded[key+0xd0], *struct.unpack_from('<3i', decoded, key+0xd4)]
                                                    if version == 'ablayer21' else
                                                    [decoded[key+0x34], *struct.unpack_from('<3h', decoded, key+0x89)])
                                                # 0x58bd4a/0x58bd94 consume the normalized anchor pair.
                                                image_fields['anchor_ratio_inputs'] = list(struct.unpack_from(
                                                    '<2i' if version == 'ablayer21' else '<2h',
                                                    decoded, key + (0x70 if version == 'ablayer21' else 0x85)))
                                                image_keys.append(image_fields)
                                            record['key_image_fields'] = image_keys

                                records.append(record)
                            layouts.append(dict(motion_index=index, motion_offset=motion.start(),
                                layer_count_offset=count_offset, layers=records, status='inferred'))
                        if layouts:
                            item['motion_layer_layout_candidates'] = layouts




        if include_extended_values and inferred_name == 'data_000.bin' and wide_header:
            tag = b'abmotion11' + bytes(6)
            count_offset = 40
            if result['tags'][-1]['tag'] == 'abdata14' and len(decoded) >= 40:
                # Unlike abdata13, the wide loader reads loop start before duration.
                version, width, height, loop_start, duration = struct.unpack_from('<5i', decoded, 14)
                if version == 1:
                    item['wide_duration_inputs'] = dict(decoded_offset=26, duration=duration, loop_start=loop_start)
                    item['wide_canvas_inputs'] = dict(decoded_offset=18, width=width, height=height)
                # Wide metadata has a UTF-16 parameter block before the action count.
                count_offset += 2 * int.from_bytes(decoded[38:40], 'little')
            first_motion = count_offset + 1
            if decoded[first_motion:first_motion+16] == tag:
                count = decoded[count_offset]
                names = []
                boundaries = []
                for match in re.compile(re.escape(tag)).finditer(decoded, first_motion):
                    offset = match.end()
                    size = int.from_bytes(decoded[offset+4:offset+6], 'little') * 2
                    if decoded[offset:offset+4] != b'\x01\x00\x00\x00' or not 0 < size <= 512 or offset+6+size >= len(decoded):
                        break
                    try:
                        names.append(decoded[offset+6:offset+6+size].decode('utf-16le'))
                        boundaries.append((match.start(), offset+6+size))
                    except UnicodeDecodeError:
                        break
                if 0 < count <= 128 and len(names) == count:
                    item['motion_name_candidates'] = names
                    if result['tags'][-1]['tag'] == 'abdata14':
                        layouts = []
                        for index, (start, header_end) in enumerate(boundaries):
                            end = boundaries[index+1][0] if index+1 < count else len(decoded)
                            layers = wide_motion_layers(decoded, header_end, end)
                            layouts.append(dict(motion_index=index, decoded_offset=start,
                                status='inferred' if layers is not None else 'unsupported',
                                layers=layers))
                        item['wide_motion_layout_candidates'] = layouts

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
            # A direct embedded child can reuse the bounded wide-motion audit.
            direct_child = (include_extended_values and not item['compressed']
                            and item.get('image_anchor_offset_inputs', {}).get('nested_surface_flag') == 0)
            item['nested']=inspect_container(decoded,upstream,budget,chain+[dict(name=item['name'],
                decoded_parent_sha256=item['decoded_sha256'],parent_raw_reference=item['raw_bytes_reference'])],depth+1,
                include_extended_values=direct_child)
            if item['nested']['status']!='verified':result['status']='unsupported'
        elif decoded.startswith(b'IMOAVI'):
            item['imoavi_status']='not_tested'
            if include_extended_values:
                from qlie_unpacker.imoavi import extract_imoavi
                from PIL import Image
                try:
                    frames = [frame for frame in extract_imoavi(decoded) if frame.name.endswith('.jpg')]
                    if not 1 <= len(frames) <= 255:
                        raise ProbeError('imoavi_frame_count')
                    dimensions = set()
                    pixels = 0
                    frame_references = []
                    cursor = 64
                    for frame in frames:
                        offset = decoded.find(frame.data, cursor)
                        if offset < 0:
                            raise ProbeError('imoavi_frame_range_unavailable')
                        cursor = offset + len(frame.data)
                        frame_references.append(dict(offset=offset, length=len(frame.data),
                                                     sha256=digest(frame.data)))
                        with Image.open(io.BytesIO(frame.data)) as image:
                            width, height = image.size
                            pixels += width * height
                            if pixels > 128_000_000:
                                raise ProbeError('imoavi_pixel_budget')
                            image.load()
                            dimensions.add(image.size)
                    if len(dimensions) != 1:
                        raise ProbeError('imoavi_frame_dimensions')
                    width,height = dimensions.pop()
                    item.update(imoavi_status='verified',width=width,height=height,frame_count=len(frames),
                                imoavi_frame_references=frame_references)
                except (ValueError, OSError, ProbeError) as exc:
                    item.update(imoavi_status='unsupported',imoavi_issue=type(exc).__name__)
    result.update(total_budget_bytes=budget.total,total_budget_members=budget.members)
    return result


def sample_discrete_keys(result, time):
    """Select the last key at or before time, as in 0x58dc9c."""
    samples = []
    for member in result.get('members', []):
        for motion in member.get('motion_layer_layout_candidates', []):
            for layer in motion['layers']:
                times = layer.get('key_time_values', [])
                fields = layer.get('key_image_fields', [])
                sample = dict(motion_index=motion['motion_index'], layer_offset=layer['offset'])
                if not times or len(times) != len(fields) or time < times[0]:
                    samples.append(dict(sample, status='unsupported', reason='unverified_key_time_range'))
                    continue
                index = sum(t <= time for t in times) - 1
                key = fields[index]
                samples.append(dict(sample, status='verified', key_offset=key['offset'],
                                    key_time=times[index], type=key['type']))
    return samples


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,default=ROOT/'.research/upstream/qlie-unpack')
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--samples',type=Path,default=ROOT/'private/real-p0/sample-report.json')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p1/abmp-report.json')
    ap.add_argument('--input',type=Path,help=argparse.SUPPRESS)
    ap.add_argument('--private-extended-values',action='store_true',help=argparse.SUPPRESS)
    ap.add_argument('--sample-key-time', type=int, help=argparse.SUPPRESS)
    args=ap.parse_args()
    if args.sample_key_time is not None and (not args.input or not args.private_extended_values or args.sample_key_time < 0):
        ap.error('--sample-key-time requires --input, --private-extended-values and a nonnegative time')
    if args.input:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU,(20,20))
        commit=validate_source(args.source)
        sys.dont_write_bytecode=True;sys.path.insert(0,str(absolute(args.source)))
        from qlie_unpacker import abmp
        result=inspect_container(read_bounded(args.input,MAX_CONTAINER),abmp,include_extended_values=args.private_extended_values)
        result['upstream_commit']=commit
        if args.sample_key_time is not None:
            result['discrete_key_sample'] = dict(time=args.sample_key_time, layers=sample_discrete_keys(result, args.sample_key_time))
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
                if digest(read_bounded(path,MAX_CONTAINER))!=sample['sha256']:raise ProbeError('sample_sha256_mismatch')
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
