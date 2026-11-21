"""Build a native image recipe from a verified, byte-bound ABMP audit."""
import hashlib
from mangekyou_p0 import ProbeError


def sha(data):
    return hashlib.sha256(data).hexdigest()


def wide_timelines(metadata, *, action_zero_only=False, clock_inputs=False, nested_inputs=False):
    timelines = {}
    for motion in metadata.get('wide_motion_layout_candidates', []):
        index = motion['motion_index']
        if (action_zero_only and index != 0) or not motion.get('layers'):
            continue
        layers = []
        for layer in motion['layers']:
            keys = []
            for key in layer['keys']:
                texture = key.get('first_texture_input', {})
                entry = dict(time=key['time'], type=key['raw_type'], offset=key['decoded_offset'],
                             literal_opacity_input=key['opacity_input']['raw_value'],
                             opacity_mode_input=key['opacity_input']['mode'],
                             texture_numbers=[texture['number']] if texture.get('mode') == 0 else None,
                             blend=key.get('draw_mode_inputs', {}).get('blend'),
                             sampling=key.get('draw_mode_inputs', {}).get('sampling'),
                             **key.get('geometry_inputs', {}))
                if clock_inputs:
                    entry['time_control_inputs'] = key['time_control_inputs']
                if nested_inputs and texture.get('mode') == 0:
                    if 'action' in texture:
                        clock = key['child_time_input']
                        entry['nested_motion_input'] = dict(action=texture['action'], mode=clock['mode'],
                                                            value=clock['value'])
                        entry['nested_literal_draw_state'] = key.get('literal_draw_state', False)
                    if key.get('literal_draw_state_at_key'):
                        entry['nested_literal_draw_state_at_key'] = True
                    if 'nested_color_curve' in key:
                        entry['nested_color_curve'] = key['nested_color_curve']
                    if 'nested_mask_mode' in key:
                        entry['texture_numbers'].append(key['second_texture_number'])
                        entry['nested_mask_mode'] = key['nested_mask_mode']
                    if 'type20_input' in key:
                        entry['type20_input'] = key['type20_input']
                    if 'particle_raster_mode' in key:
                        entry['particle_raster_mode'] = key['particle_raster_mode']
                keys.append(entry)
            layers.append(keys)
        timelines[index] = layers
    return timelines


def append_image_recipe(recipes, content, audit):
    root_sha = sha(content)
    scoped_rasters = {}
    def collect(node,base,span,expected,depth,direct_scope=False):
        if depth>4 or node.get('status')!='verified' or node.get('container_sha256')!=expected:
            raise ProbeError('cli_image_audit_identity')
        for member in node['members']:
            if member.get('compressed'):continue
            ref=member['raw_bytes_reference'];offset=ref['offset'];length=ref['length']
            if ref['container_sha256']!=expected or not 0<=offset<offset+length<=span:
                raise ProbeError('cli_image_member_bounds')
            start=base+offset
            if sha(content[start:start+length])!=ref['sha256']:raise ProbeError('cli_image_member_identity')
            if member.get('nested'):
                direct_child = ((depth == 0 or direct_scope) and
                                member.get('image_anchor_offset_inputs', {}).get('nested_surface_flag') == 0)
                collect(member['nested'],start,length,ref['sha256'],depth+1,direct_child)
            elif member.get('imoavi_status') == 'verified':
                recipes.append(dict(container_sha256=root_sha,offset=start,length=length,sha256=ref['sha256'],
                                    format='IMOAVI',name=member['name'],width=member['width'],height=member['height']))
                if depth == 0 and 'image_slot' in member:
                    recipes[-1]['image_slot'] = member['image_slot']
                    anchor = member.get('image_anchor_offset_inputs', {})
                    if 'raw_words' in anchor:
                        recipes[-1]['image_anchor_words'] = anchor['raw_words']
                frames = member.get('imoavi_frame_references')
                if frames is not None:
                    if not 1 <= len(frames) <= 255 or len(frames) != member.get('frame_count'):
                        raise ProbeError('cli_imoavi_frame_count')
                    cursor = 0
                    for frame in frames:
                        off, size = frame['offset'], frame['length']
                        if not cursor <= off < off + size <= length or sha(content[start+off:start+off+size]) != frame['sha256']:
                            raise ProbeError('cli_imoavi_frame_identity')
                        cursor = off + size
                    recipes[-1]['imoavi_frame_references'] = frames
            elif (member.get('format') in {'PNG','JPEG','BMP'} and member.get('content_decode_status')=='verified'
                  or member.get('format')=='DPNG' and member.get('dpng', {}).get('metadata_status')=='verified'
                  or member.get('format')=='Ogg' and member['name'].lower().endswith('.ogv')):
                recipes.append(dict(container_sha256=root_sha,offset=start,length=length,sha256=ref['sha256'],name=member['name'],format=member['format']))
                if (depth == 0 or direct_scope) and 'image_slot' in member:
                    raster = recipes[-1]
                    if direct_scope:
                        raster = dict(raster, container_sha256=expected, offset=offset)
                        scoped_rasters.setdefault(expected, {})[offset, member['image_slot']] = raster
                    raster['image_slot'] = member['image_slot']
                    if member.get('width') and member.get('height'):
                        raster.update(width=member['width'], height=member['height'])
                    anchor = member.get('image_anchor_offset_inputs', {})
                    if 'raw_words' in anchor:
                        raster['image_anchor_words'] = anchor['raw_words']
                if len(recipes)>128:raise ProbeError('cli_image_recipe_limit')
    scoped_digests = set()

    def read_nested_slots(node):
        slots = {}
        for member in node['members']:
            if (member.get('compressed') or not member.get('nested') or 'image_slot' not in member
                or member.get('image_anchor_offset_inputs', {}).get('nested_surface_flag') != 0):
                continue
            child = member['nested']
            child_meta = next((item for item in child['members'] if item.get('name') == 'data_000.bin'), {})
            duration = child_meta.get('wide_duration_inputs')
            timelines = wide_timelines(child_meta, clock_inputs=True, nested_inputs=True)
            if duration and timelines:
                slot = dict(**member['raw_bytes_reference'], duration=duration['duration'],
                            loop_start=duration['loop_start'], timelines=timelines,
                            canvas=child_meta.get('wide_canvas_inputs'),
                            image_anchor_words=member['image_anchor_offset_inputs']['raw_words'])
                children = read_nested_slots(child)
                if children:
                    slot['nested_slots'] = children
                slots[member['image_slot']] = slot
                scoped_digests.add(slot['sha256'])
        return slots

    before=len(recipes);collect(audit,0,len(content),root_sha,0)
    metadata=[m for m in audit['members'] if m.get('name')=='data_000.bin']
    if len(metadata)==1 and (metadata[0].get('extended_key_markers_absent') is True
        or 'extended_scalar_values' in metadata[0] or 'motion_name_candidates' in metadata[0]):
        ref=metadata[0]['raw_bytes_reference'];start=ref['offset'];length=ref['length']
        if (ref['container_sha256']!=root_sha or not 0<=start<start+length<=len(content)
            or sha(content[start:start+length])!=ref['sha256']):
            raise ProbeError('cli_image_metadata_identity')
        if len(recipes) == before and len(audit['members']) == 1 and metadata[0].get('motion_name_candidates'):
            recipes.append(dict(container_sha256=root_sha, offset=start, length=length,
                                sha256=ref['sha256'], format='MotionOnly'))
        if len(recipes) > before and (metadata[0].get('extended_key_markers_absent') is True or 'extended_scalar_values' in metadata[0]):
            recipes[before]['extended_scalar_values']=metadata[0].get('extended_scalar_values',{})
        if len(recipes) > before and 'motion_name_candidates' in metadata[0]:
            recipes[before]['motion_name_candidates']=metadata[0]['motion_name_candidates']
            if 'motion_canvas_inputs' in metadata[0]:
                recipes[before]['motion_canvas_inputs'] = metadata[0]['motion_canvas_inputs']
            if 'motion_duration_inputs' in metadata[0]:
                recipes[before]['motion_duration_inputs'] = metadata[0]['motion_duration_inputs']
            if 'motion_update_threshold' in metadata[0]:
                recipes[before]['motion_update_threshold'] = metadata[0]['motion_update_threshold']
            motion_types = {
                motion['motion_index']: sorted({
                    key['type'] for layer in motion['layers'] for key in layer['key_image_fields']
                })
                for motion in metadata[0].get('motion_layer_layout_candidates', [])
                if motion['layers'] and all(layer.get('key_image_fields') for layer in motion['layers'])
            }
            if motion_types:
                recipes[before]['motion_key_types'] = motion_types
            timelines = {}
            wide_dialog = root_sha == '7c0cb9495c6a551403d42832ee067caa42d31677cfcbbb4ef0f4e3489ab70c55'
            wide_title_control = root_sha in {
                '0f49b2d5f24def184da0c66b5facc9c4ee743e284fb4ef616d2fee6083ebdc77',
                'f27fe5e672a0e94c68bf0f43c33e60657570e89795e251b310706f11db7c8bc6',
            }
            nested_slots = read_nested_slots(audit)
            if wide_dialog or wide_title_control or nested_slots:
                partial = wide_timelines(metadata[0], action_zero_only=wide_title_control,
                                         clock_inputs=wide_title_control or bool(nested_slots),
                                         nested_inputs=bool(nested_slots))
                if partial:
                    recipes[before]['partial_motion_timelines'] = partial
                    if nested_slots:
                        recipes[before]['direct_nested_motion_slots'] = nested_slots
                        if 'wide_canvas_inputs' in metadata[0]:
                            recipes[before]['motion_canvas_inputs'] = metadata[0]['wide_canvas_inputs']
                        for digest in sorted(scoped_digests):
                            recipes.extend(scoped_rasters.get(digest, {}).values())
                        if len(recipes) > 128:
                            raise ProbeError('cli_image_recipe_limit')
            for motion in metadata[0].get('motion_layer_layout_candidates', []):
                layers = motion['layers']
                if not layers or not all(layer.get('key_time_values') and
                        len(layer['key_time_values']) == len(layer.get('key_image_fields', [])) for layer in layers):
                    continue
                timelines[motion['motion_index']] = [
                    [dict(time=time, type=key['type'], offset=key['offset'],
                          texture_numbers=key['numbers'], source_areas=key.get('source_areas'),
                          blend=key.get('blend'), sampling=key.get('sampling'),
                          type11_color_inputs=key.get('type11_color_inputs'),
                          type1_color_inputs=key.get('type1_color_inputs'),
                          dual_texture_raw_inputs=key.get('dual_texture_raw_inputs'),
                          transform_fields=key.get('converted_transform_fields'),
                          anchor_ratio_inputs=key.get('anchor_ratio_inputs'),
                          literal_opacity_input=key.get('literal_opacity_input'),
                          opacity_mode_input=key.get('opacity_mode_input'),
                          source_area_mode_input=key.get('source_area_mode_input'),
                          source_area_interpolation_flag=key.get('source_area_interpolation_flag'),
                          source_area_strength_input=key.get('source_area_strength_input'),
                          position_mode_input=key.get('position_mode_input'),
                          time_control_inputs=key.get('time_control_inputs'),
                          position_strength_input=key.get('position_strength_input'))
                     for time, key in zip(layer['key_time_values'], layer['key_image_fields'])]
                    for layer in layers
                ]
            if timelines:
                recipes[before]['motion_timelines'] = timelines
            layer_flags = {}
            for layout_key in ('motion_layer_layout_candidates', 'wide_motion_layout_candidates'):
                for motion in metadata[0].get(layout_key, []):
                    layers = motion.get('layers') or []
                    if layers and all('raw_layer_flag' in layer for layer in layers):
                        values = [layer['raw_layer_flag'] for layer in layers]
                        if all(isinstance(value, int) and 0 <= value <= 0xff for value in values):
                            layer_flags[motion['motion_index']] = values
            if layer_flags:
                # 0x592998 reads this byte into each native layer row at +0x21;
                # 0x57e840 copies it into the image save block's 256-byte flag area.
                recipes[before]['motion_layer_flags'] = layer_flags
            clock_timelines = {}
            for layout_key in ('motion_layer_layout_candidates', 'wide_motion_layout_candidates'):
                for motion in metadata[0].get(layout_key, []):
                    layers = motion.get('layers') or []
                    clock_layers = []
                    valid = bool(layers)
                    for layer in layers:
                        if layout_key == 'motion_layer_layout_candidates':
                            times = layer.get('key_time_values') or []
                            fields = layer.get('key_image_fields') or []
                            if len(times) != len(fields) or not fields:
                                valid = False
                                break
                            keys = [dict(time=int(time), time_control_inputs=field.get('time_control_inputs'))
                                    for time, field in zip(times, fields)]
                        else:
                            keys = [dict(time=int(key['time']), time_control_inputs=key.get('time_control_inputs'))
                                    for key in layer.get('keys', [])]
                        if not keys or any(not isinstance(key.get('time_control_inputs'), list) or
                                len(key['time_control_inputs']) != 4 for key in keys):
                            valid = False
                            break
                        clock_layers.append(keys)
                    if valid:
                        clock_timelines[int(motion['motion_index'])] = clock_layers
            if clock_timelines:
                # Keep clock inputs separate from renderer recipes; unsupported draw fields remain untouched.
                recipes[before]['motion_clock_timelines'] = clock_timelines
            non_drawing = [index for index, types in motion_types.items() if types == [0]]
            if non_drawing:
                recipes[before]['non_drawing_motion_indices'] = non_drawing


    if len(recipes) == before:raise ProbeError('cli_image_members_missing')
