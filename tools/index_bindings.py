#!/usr/bin/env python3
"""Bind reviewed array metadata and small code patterns; never execute the input."""
import argparse
import hashlib
import json
from pathlib import Path

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .delphi_metadata import Image, parse_class
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from delphi_metadata import Image, parse_class


def bind_class(image, vmt, name, size, fields, slots):
    row = parse_class(image, vmt, 4, name)
    actual_fields = {f['name']: f['offset'] for f in row['fields']}
    actual_slots = {s['byte_offset']: int(s['target'], 16) for s in row['slots']}
    if row['instance_size'] != size or any(actual_fields.get(k) != v for k, v in fields.items()):
        raise ProbeError('index_class_field_binding_mismatch')
    if any(actual_slots.get(k) != v for k, v in slots.items()):
        raise ProbeError('index_class_slot_binding_mismatch')
    return dict(status='verified', name=name, vmt=hex(vmt), instance_size=size,
        parent_vmt=row['parent_vmt'], header_reference=row['header_reference'],
        fields=[dict(name=f['name'], offset=f['offset'], raw_bytes_reference=f['raw_bytes_reference']) for f in row['fields']],
        slots=row['slots'], live_dispatch='not_tested')


def pattern(image, name, address, expected):
    data = bytes.fromhex(expected)
    if not data or len(data) > 64 or image.read(address, len(data)) != data:
        raise ProbeError('index_instruction_pattern_mismatch')
    return dict(id=name, status='verified', address=hex(address), raw_bytes_reference=image.reference(address, len(data)),
        scope='Exact selected machine bytes only; original execution not tested')


def bindings(data):
    image = Image(data)
    base = bind_class(image, 0x696d6c, 'TValueArrayCustom', 68,
        {'FCount':20, 'FArrayCount':32, 'FArrayPitch':48}, {8:0x69dddc,12:0x69df10})
    integer = bind_class(image, 0x697504, 'TValueArrayInteger', 72,
        {'FData':64}, {4:0x69e0c0,8:0x69dff4,12:0x69e104})
    string = bind_class(image, 0x6977f4, 'TValueArrayString', 72,
        {'FData':64}, {4:0x69e290,8:0x69e190,12:0x69e2dc})
    if integer['parent_vmt'] != base['vmt'] or string['parent_vmt'] != base['vmt']:
        raise ProbeError('index_array_parent_binding')
    cells = []
    for address, target in [(0x6974ac,0x697504),(0x69779c,0x6977f4)]:
        if image.u32(address) != target:
            raise ProbeError('index_factory_type_cell_mismatch')
        cells.append(dict(status='verified', address=hex(address), target=hex(target), raw_bytes_reference=image.reference(address,4)))
    patterns = [pattern(image,n,a,b) for n,a,b in [
        ('integer_element_read',0x69e013,'8b46408b04b8894504'),
        ('string_read_tag_one',0x69e1ab,'c6450001'),
        ('string_element_pointer_read',0x69e1b7,'8b56408b14ba'),
        ('string_element_pointer_write',0x69e2f7,'8b45408d04b08b5708'),
        ('new_integer_element_zero',0x69e0ec,'33ff893c91'),
        ('new_string_element_empty',0x69e2ba,'8b46408d04b833d2')]]
    return dict(classes=[base,integer,string], factory_type_cells=cells, selected_byte_patterns=patterns,
        bytes_read=image.bytes_read, field_and_slot_binding='verified', original_engine_equivalence='not_tested',
        inferred_contract=dict(status='inferred', meaning='Reviewed int/string storage accesses an element in FData; string read copies the element value, not a character',
            multiple_source_coordinate_order='not_tested', ownership_and_error_rollback='not_tested'))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir', required=True, type=Path); p.add_argument('--exe', required=True)
    args=p.parse_args(); game=absolute(args.game_dir); source=safe_member_name(args.exe)
    output=ROOT/'reports/p1/index-binding-report.json'
    if game==output or game in output.parents or output in game.parents:
        raise ProbeError('index_binding_input_output_overlap')
    data=read_bounded(game/source,64*1024*1024); sha=hashlib.sha256(data).hexdigest()
    inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    plan=json.loads(read_bounded(ROOT/'docs/native-index-plan.json'))
    if sha!=plan['source_sha256'] or not any(f['path']==source and f.get('sha256')==sha for f in inventory['files']):
        raise ProbeError('index_binding_source_identity')
    report=bindings(data)
    if hashlib.sha256(read_bounded(game/source,64*1024*1024)).hexdigest()!=sha:
        raise ProbeError('index_binding_source_changed')
    report.update(schema_version=1,status='inferred',dataset='real',source_file=source,source_sha256=sha,
        scope='Bounded declared array metadata and selected instruction bytes; no original execution',
        full_game_compatibility='not_tested',original_files_written=False,external_game_data_uploads=False)
    write_json(output,report); print(json.dumps(dict(status='inferred',classes=3,patterns=len(report['selected_byte_patterns']))))
    return 0


if __name__=='__main__': raise SystemExit(main())
