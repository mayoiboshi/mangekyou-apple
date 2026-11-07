#!/usr/bin/env python3
"""Bind list/path metadata and selected callback bytes; never run the original."""
import argparse
import hashlib
import json
from pathlib import Path
if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .delphi_metadata import Image, parse_class
    from .index_bindings import bind_class, pattern
    from .subp_analysis import dispatch_case
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from delphi_metadata import Image, parse_class
    from index_bindings import bind_class, pattern
    from subp_analysis import dispatch_case


def bindings(data):
    im=Image(data)
    obj=bind_class(im,0x688764,'TImoObjectDataStringList',32,{'obj':24},{})
    component=bind_class(im,0x432d50,'TStringList',76,
        {'FList':28,'FCount':32,'FSorted':40,'FCaseSensitive':42},{12:0x43eb54})
    path=parse_class(im,0x6a4ed8,0,'TImoPath')
    if path['instance_size']!=44 or {f['name']:f['offset'] for f in path['fields']}.get('FImoPathSelfFilePath')!=24:
        raise ProbeError('list_path_metadata_binding')
    selected=[]
    for slot,target in [(0x14,0x43eb88),(0x34,0x43ef14),(0x44,0x43e968),(0x58,0x43da78),(0x70,0x43dc60)]:
        if im.u32(0x432d50+slot)!=target:raise ProbeError('list_component_slot_binding')
        im.code(target);selected.append(dict(offset=slot,target=hex(target),raw_bytes_reference=im.reference(0x432d50+slot,4)))
    cells=[]
    for address,target in [(0x68870c,0x688764),(0x432cf8,0x432d50),(0x6a4e80,0x6a4ed8)]:
        if im.u32(address)!=target:raise ProbeError('list_factory_cell_binding')
        cells.append(dict(address=hex(address),target=hex(target),raw_bytes_reference=im.reference(address,4)))
    patterns=[pattern(im,n,a,b) for n,a,b in [
        ('factory_list_literal',0x6bf660,'6c006900730074000000'),
        ('extract_directory_delimiters',0x4163f0,'5c003a000000'),
        ('owner_stores_path_object',0x6be9f8,'899e3c010000'),
        ('owner_binds_self_path_callback',0x6bea12,'89731cc7431834156d00'),
        ('self_path_reads_current_key',0x6d1559,'8bbb20010000'),
        ('self_path_extracts_directory',0x6d1584,'8b45f88bd6e82e4ed4ff')]]
    return dict(field_and_slot_binding='verified',classes=[obj,component],
        path_class=dict(name=path['name'],instance_size=44,vmt=path['vmt'],header_reference=path['header_reference'],
            fields=[dict(name=f['name'],offset=f['offset'],raw_bytes_reference=f['raw_bytes_reference']) for f in path['fields']]),
        selected_component_slots=selected,factory_type_cells=cells,selected_byte_patterns=patterns,
        dispatch=dispatch_case(im,0x6aaeb1,0x6aaec5,40,23,0x6aafab,0x6aafb4,0x6cce64),
        bytes_read=im.bytes_read,original_engine_equivalence='not_tested',
        windows_locale_equivalence='not_tested',configured_search_prefixes='unsupported')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    a=p.parse_args();game=absolute(a.game_dir);source=safe_member_name(a.exe);output=ROOT/'reports/p1/list-binding-report.json'
    if game==output or game in output.parents or output in game.parents:raise ProbeError('list_binding_input_output_overlap')
    data=read_bounded(game/source,64*1024*1024);sha=hashlib.sha256(data).hexdigest()
    plan=json.loads(read_bounded(ROOT/'docs/native-list-plan.json'));inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if sha!=plan['source_sha256'] or not any(f['path']==source and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('list_binding_source_identity')
    r=bindings(data)
    if hashlib.sha256(read_bounded(game/source,64*1024*1024)).hexdigest()!=sha:raise ProbeError('list_binding_source_changed')
    r.update(schema_version=1,status='inferred',dataset='real',source_file=source,source_sha256=sha,
        scope='Bounded list/path declarations and selected callback bindings; no original execution',
        original_files_written=False,external_game_data_uploads=False,full_game_compatibility='not_tested')
    write_json(output,r);print(json.dumps(dict(status='inferred',classes=3,patterns=len(r['selected_byte_patterns']))));return 0


if __name__=='__main__':raise SystemExit(main())
