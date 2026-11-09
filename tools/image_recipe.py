"""Build a native image recipe from a verified, byte-bound ABMP audit."""
import hashlib
from mangekyou_p0 import ProbeError


def sha(data):
    return hashlib.sha256(data).hexdigest()


def append_image_recipe(recipes, content, audit):
    root_sha = sha(content)
    def collect(node,base,span,expected,depth):
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
                collect(member['nested'],start,length,ref['sha256'],depth+1)
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
                if depth == 0 and 'image_slot' in member:
                    recipes[-1]['image_slot'] = member['image_slot']
                    if member.get('width') and member.get('height'):
                        recipes[-1].update(width=member['width'], height=member['height'])
                    anchor = member.get('image_anchor_offset_inputs', {})
                    if 'raw_words' in anchor:
                        recipes[-1]['image_anchor_words'] = anchor['raw_words']
                if len(recipes)>128:raise ProbeError('cli_image_recipe_limit')
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
            if root_sha == '7c0cb9495c6a551403d42832ee067caa42d31677cfcbbb4ef0f4e3489ab70c55':
                # The dialog sample has verified time, type, draw modes, texture
                # inputs and opacity fields. Geometry is a preview candidate.
                wide_timelines = {}
                for motion in metadata[0].get('wide_motion_layout_candidates', []):
                    layers = motion.get('layers')
                    if not layers:
                        continue
                    wide_timelines[motion['motion_index']] = [
                        [dict(time=key['time'], type=key['raw_type'], offset=key['decoded_offset'],
                              literal_opacity_input=key['opacity_input']['raw_value'],
                              opacity_mode_input=key['opacity_input']['mode'],
                              texture_numbers=[key['first_texture_input']['number']]
                              if key.get('first_texture_input', {}).get('mode') == 0 else None,
                              blend=key.get('draw_mode_inputs', {}).get('blend'),
                              sampling=key.get('draw_mode_inputs', {}).get('sampling'),
                              **key.get('geometry_inputs', {}))
                         for key in layer['keys']]
                        for layer in layers
                    ]
                if wide_timelines:
                    recipes[before]['partial_motion_timelines'] = wide_timelines
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
                          transform_fields=key.get('converted_transform_fields'),
                          anchor_ratio_inputs=key.get('anchor_ratio_inputs'),
                          literal_opacity_input=key.get('literal_opacity_input'),
                          opacity_mode_input=key.get('opacity_mode_input'),
                          position_mode_input=key.get('position_mode_input'),
                          time_control_inputs=key.get('time_control_inputs'),
                          position_strength_input=key.get('position_strength_input'))
                     for time, key in zip(layer['key_time_values'], layer['key_image_fields'])]
                    for layer in layers
                ]
            if timelines:
                recipes[before]['motion_timelines'] = timelines
            non_drawing = [index for index, types in motion_types.items() if types == [0]]
            if non_drawing:
                recipes[before]['non_drawing_motion_indices'] = non_drawing


    if len(recipes) == before:raise ProbeError('cli_image_members_missing')
