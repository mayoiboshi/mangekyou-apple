#!/usr/bin/env python3
"""Check a pinned PE32 event record and selected callback instructions, without execution."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .delphi_metadata import Image,parse_record
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from delphi_metadata import Image,parse_record


def event_layout(record):
    """Admit only the reviewed four-method PE32 record, not arbitrary Delphi RTTI."""
    fields=record['fields']
    expected=[('ObjectCreate',0),('ObjectDestroy',8),('ObjectSave',16),('ObjectLoad',24)]
    if record['declared_size']!=32 or record['managed_fields'] or len(fields)!=4:
        raise ProbeError('callback_record_shape')
    result=[]
    for field,(name,offset) in zip(fields,expected):
        if (field['name'],field['offset'])!=(name,offset) or field['type_info'].get('kind_u8')!=8:
            raise ProbeError('callback_method_field_layout')
        if field['attributes']['length']!=2:raise ProbeError('callback_uninterpreted_attributes')
        result.append(dict(name=name,code_offset=offset,data_offset=offset+4,
            declared_type=field['type_info']['name'],raw_bytes_reference=field['raw_bytes_reference']))
    return dict(status='inferred',declaration_bytes_status='verified',pointer_bytes=4,declared_bytes=32,
        fields=result,method_signature='not_tested',runtime_invocation='not_tested')


def relative_call(image,address,expected):
    image.code(address);image.code(expected);raw=image.read(address,5)
    if raw[0]!=0xe8 or (address+5+struct.unpack_from('<i',raw,1)[0])&0xffffffff!=expected:
        raise ProbeError('callback_direct_call_mismatch')
    return dict(status='verified',call_address=hex(address),target=hex(expected),
        raw_bytes_reference=image.reference(address,5),scope='Direct E8 instruction bytes only')


def initializer(image,address,layout):
    """Decode one exact admitted store sequence; no general x86 decoder or ABI model."""
    if len(layout['fields'])!=4:raise ProbeError('callback_initializer_field_count')
    raw=image.read(address,40);rows=[]
    for i,field in enumerate(layout['fields']):
        at=i*10;code_disp=(-32+8*i)&255;data_disp=(-28+8*i)&255
        if raw[at:at+3]!=bytes([0x89,0x75,data_disp]) or raw[at+3:at+6]!=bytes([0xc7,0x45,code_disp]):
            raise ProbeError('callback_initializer_store_shape')
        target=struct.unpack_from('<I',raw,at+6)[0];image.code(target)
        rows.append(dict(name=field['name'],target=hex(target),data_source='ESI',
            code_offset=field['code_offset'],data_offset=field['data_offset'],
            raw_bytes_reference=image.reference(address+at,10)))
    return dict(status='inferred',instruction_bytes_status='verified',events=rows,
        owner_identity='not_tested',scope='Four interleaved EBP-relative code/data stores; static binding only')


def literal(image,address,text):
    raw=(text+'\0').encode('utf-16le')
    if image.u32(address-4)!=len(text) or image.read(address,len(raw))!=raw:
        raise ProbeError('callback_parameter_symbol_mismatch')
    return dict(status='verified',symbol=text,raw_bytes_reference=image.reference(address,len(raw)))


def inspect(image,plan):
    record=plan['record'];layout=event_layout(parse_record(image,int(record['type_info'],16),
        int(record['fields_count_address'],16),'TValueArrayEventSet'))
    binding=initializer(image,int(plan['initializer'],16),layout)
    targets={r['name']:r['target'] for r in binding['events']}
    if len(plan['factory_calls'])!=2:raise ProbeError('callback_factory_call_count')
    calls=[]
    for row in plan['factory_calls']:
        if row['event'] not in {'ObjectCreate','ObjectLoad'} or targets[row['event']]!=row['bridge']:
            raise ProbeError('callback_bridge_binding_mismatch')
        a=int(row['call'],16);bridge=int(row['bridge'],16)
        if not bridge<=a<bridge+128:raise ProbeError('callback_bridge_span_limit')
        calls.append(dict(event=row['event'],**relative_call(image,a,int(plan['factory'],16))))
    if {c['event'] for c in calls}!={'ObjectCreate','ObjectLoad'}:raise ProbeError('callback_factory_events_not_distinct')
    if len(plan['parameter_symbols'])!=2 or [r[1] for r in plan['parameter_symbols']]!=['ParamInt','ParamStr']:
        raise ProbeError('callback_parameter_symbol_plan')
    enum=image.type_reference(int(plan['value_type_cell'],16))
    if enum['name']!='TScriptValueType':raise ProbeError('callback_value_enum_identity')
    return dict(status='inferred',scope='Pinned static declaration and callback byte checks only',
        event_layout=layout,initializer_binding=binding,factory_calls=calls,value_type_declaration=enum,
        parameter_symbols=[literal(image,int(a,16),s) for a,s in plan['parameter_symbols']],
        creation_callback_link='inferred',namespace_shadowing='not_tested',runtime_argument_conversion='not_tested',
        native_xref_completeness='unsupported',
        unknowns=['No callback execution observed', 'Full method ABI and dynamic callback reassignment unknown',
            'Selected growth-path guard reads word at descriptor+0x52; reason unknown',
            'Expression structure does not predict actual value tag',
            'Static chain does not prove startup reachability or namespace ownership'])


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',required=True,type=Path);p.add_argument('--exe',required=True)
    p.add_argument('--plan',type=Path,default=ROOT/'docs/object-callback-probe-plan.json')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/object-callback-report.json')
    args=p.parse_args();output=absolute(args.output);game=absolute(args.game_dir)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('callback_summary_must_be_public_P1')
    if game==output or game in output.parents or output in game.parents:raise ProbeError('callback_input_output_overlap')
    relative=safe_member_name(args.exe);data=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(data).hexdigest()
    plan=json.loads(read_bounded(args.plan));inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if plan.get('schema_version')!=1 or plan.get('source_sha256')!=sha or not any(
        f['path']==relative and f.get('sha256')==sha for f in inventory['files']):raise ProbeError('callback_source_identity')
    image=Image(data);errors=[]
    try:report=inspect(image,plan)
    except (ValueError,KeyError,struct.error) as exc:
        report=dict(status='unsupported',scope='Static callback probe failed');errors.append(dict(error=str(exc)))
    report.update(schema_version=1,dataset='real',source_file=relative,source_sha256=sha,
        bytes_read=image.bytes_read,errors=errors,original_files_written=False,target_execution='not_tested',
        external_game_data_uploads=False,source_sha256_after=hashlib.sha256(read_bounded(game/relative,64*1024*1024)).hexdigest())
    if report['source_sha256_after']!=sha:report['status']='unsupported';errors.append(dict(error='source_changed_during_probe'))
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],errors=len(errors),bytes_read=image.bytes_read)))
    return 2 if report['status']=='unsupported' else 0


if __name__=='__main__':raise SystemExit(main())
