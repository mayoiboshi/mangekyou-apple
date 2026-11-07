#!/usr/bin/env python3
"""Bounded PE32 metadata probe for reviewed VMTs; never instantiate classes."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .pe_probe import pe32
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from pe_probe import pe32


class Image:
    def __init__(self,data,budget=1024*1024):self.data=data;self.pe=pe32(data);self.budget=budget;self.bytes_read=0
    def mapping(self,va,n):
        if not 0<=va<va+n<=0x100000000 or n>8192:raise ProbeError('metadata_address_or_size_limit')
        rows=[s for s in self.pe['sections'] if self.pe['image_base']+s['rva']<=va and va+n<=self.pe['image_base']+s['rva']+s['raw_size']]
        if len(rows)!=1:raise ProbeError('metadata_not_uniquely_file_backed')
        s=rows[0];offset=s['raw_offset']+va-self.pe['image_base']-s['rva']
        return s,offset
    def read(self,va,n):
        _,offset=self.mapping(va,n);self.bytes_read+=n
        if self.bytes_read>self.budget:raise ProbeError('metadata_read_budget')
        raw=self.data[offset:offset+n]
        if len(raw)!=n:raise ProbeError('metadata_truncated_input')
        return raw
    def number(self,va,fmt):return struct.unpack('<'+fmt,self.read(va,struct.calcsize('<'+fmt)))[0]
    def u32(self,va):return self.number(va,'I')
    def short(self,va):
        length=self.number(va,'B')
        if not 1<=length<=128:raise ProbeError('metadata_symbol_length')
        return self.read(va+1,length).decode('ascii'),length+1
    def reference(self,va,n):
        _,offset=self.mapping(va,n)
        return dict(offset=offset,length=n,sha256=hashlib.sha256(self.read(va,n)).hexdigest())
    def code(self,va):
        section,_=self.mapping(va,1)
        if not section['executable']:raise ProbeError('metadata_method_target_not_executable_section')
    def attributes(self,va):
        length=self.number(va,'H')
        if not 2<=length<=4096:raise ProbeError('metadata_attribute_length')
        return dict(status='verified' if length==2 else 'unsupported',length=length,
            raw_bytes_reference=self.reference(va,length),
            unknown_reason=None if length==2 else 'Attribute payload is preserved but not interpreted')
    def type_reference(self,cell,depth=0):
        if cell==0:return dict(status='not_tested',reason='No type reference emitted')
        va=self.u32(cell);kind=self.number(va,'B');name,size=self.short(va+1)
        result=dict(status='verified',kind_u8=kind,name=name,reference_cell=hex(cell),type_info_address=hex(va),
            raw_bytes_reference=self.reference(va,size+1),type_semantics='not_tested')
        if kind==13:
            start=va+size+1;total=self.u32(start);count=self.u32(start+4);element=self.u32(start+8)
            if not 0<total<=1024*1024 or not 0<count<=65536 or total%count:raise ProbeError('metadata_array_shape')
            result['array_header']=dict(status='inferred',declared_bytes=total,element_count=count,
                element_type_cell=hex(element),raw_bytes_reference=self.reference(start,12),
                dimensions_and_execution='not_tested')
            result['array_header']['element_type']=(self.type_reference(element,depth+1) if depth<1 else
                dict(status='not_tested',reason='Nested array element types exceed probe depth'))
        elif kind==3:
            start=va+size+1;ordinal=self.number(start,'B');minimum=self.number(start+1,'i');maximum=self.number(start+5,'i')
            base=self.u32(start+9);count=maximum-minimum+1
            if not 1<=count<=256:raise ProbeError('metadata_enum_count_limit')
            if base==0 or self.u32(base)!=va:raise ProbeError('metadata_non_self_enum_base_outside_scope')
            cursor=start+13;members=[];names=set()
            for value in range(minimum,maximum+1):
                label,n=self.short(cursor)
                if label in names:raise ProbeError('metadata_duplicate_enum_symbol')
                names.add(label);members.append(dict(value=value,name=label,raw_bytes_reference=self.reference(cursor,n)));cursor+=n
            result['enum_header']=dict(status='inferred',ordinal_type_u8=ordinal,minimum_i32=minimum,maximum_i32=maximum,
                base_type_cell=hex(base),header_reference=self.reference(start,13),members=members,
                declaration_bytes_status='verified',execution_semantics='not_tested',
                scope='Only bounded self-base enum declarations; no state-machine behavior inferred from names')
        return result


def bounded_count(value):
    if not 0<=value<=64:raise ProbeError('metadata_member_count_limit')
    return value


def validate_type_plan(plan):
    classes=plan.get('classes',[]);records=plan.get('records',[])
    if not isinstance(classes,list) or not isinstance(records,list) or not (
        0<=len(classes)<=16 and 0<=len(records)<=16 and classes+records):
        raise ProbeError('metadata_plan_count_limit')
    if len({r['vmt'] for r in classes})!=len(classes):raise ProbeError('metadata_duplicate_class_seed')
    if len({r['type_info'] for r in records})!=len(records):raise ProbeError('metadata_duplicate_record_seed')


def parse_class(image,vmt,slot_count,expected_name=None):
    if not 0<=slot_count<=16:raise ProbeError('metadata_slot_count_limit')
    if image.u32(vmt-88)!=vmt:raise ProbeError('metadata_vmt_self_pointer')
    name,_=image.short(image.u32(vmt-56));size=image.u32(vmt-52)
    if expected_name is not None and name!=expected_name:raise ProbeError('metadata_class_name_mismatch')
    if not 4<=size<=1024*1024:raise ProbeError('metadata_instance_size')
    type_info=image.u32(vmt-72)
    if image.number(type_info,'B')!=7:raise ProbeError('metadata_class_type_kind')
    type_name,n=image.short(type_info+1)
    if type_name!=name or image.u32(type_info+1+n)!=vmt:raise ProbeError('metadata_class_type_identity')
    slots=[]
    for offset in [-4]+list(range(0,slot_count*4,4)):
        target=image.u32(vmt+offset);image.code(target)
        slots.append(dict(byte_offset=offset,target=hex(target),raw_bytes_reference=image.reference(vmt+offset,4)))
    lookup={s['byte_offset']:s['target'] for s in slots};methods=[];fields=[]
    table=image.u32(vmt-64)
    if image.number(table,'H')!=0:raise ProbeError('metadata_legacy_methods_outside_probe_scope')
    count=bounded_count(image.number(table+2,'H'))
    for i in range(count):
        descriptor=table+4+i*8;entry=image.u32(descriptor);flags=image.number(descriptor+4,'H');index=image.number(descriptor+6,'h')
        length=image.number(entry,'H');target=image.u32(entry+2);method,n=image.short(entry+6)
        if not 6+n<=length<=4096:raise ProbeError('metadata_method_entry_length')
        image.code(target);slot=index*4;observed=lookup.get(slot)
        binding='not_tested' if observed is None else 'verified' if observed==hex(target) else 'unsupported'
        tail_length=length-(6+n)
        methods.append(dict(name=method,entry_address=hex(entry),code_address=hex(target),flags_u16=flags,
            virtual_index_i16=index,virtual_slot_match=binding,slot_target=observed,
            raw_bytes_reference=image.reference(entry,length),descriptor_reference=image.reference(descriptor,8),
            signature_tail=dict(status='not_tested',length=tail_length,
                raw_bytes_reference=image.reference(entry+6+n,tail_length) if tail_length else None,
                reason='Method signature tail is outside this minimal probe'),
            unknown_reason='Entry and slot may differ through a thunk; not resolved by this probe' if binding=='unsupported' else None))
    table=image.u32(vmt-68)
    if image.number(table,'H')!=0 or image.u32(table+2)!=0:raise ProbeError('metadata_legacy_fields_outside_probe_scope')
    count=bounded_count(image.number(table+6,'H'));cursor=table+8
    for i in range(count):
        start=cursor;flags=image.number(cursor,'B');cell=image.u32(cursor+1);offset=image.u32(cursor+5);field,n=image.short(cursor+9)
        if not 4<=offset<size:raise ProbeError('metadata_class_field_offset')
        cursor+=9+n;attributes=image.attributes(cursor);cursor+=attributes['length']
        fields.append(dict(name=field,offset=offset,flags_u8=flags,type_info=image.type_reference(cell),
            attributes=attributes,raw_bytes_reference=image.reference(start,cursor-start)))
    parent_cell=image.u32(vmt-48);parent=image.u32(parent_cell) if parent_cell else 0
    return dict(status='inferred',name=name,vmt=hex(vmt),instance_size=size,parent_vmt=hex(parent) if parent else None,
        header_reference=image.reference(vmt-88,88),slots=slots,methods=methods,fields=fields,
        declaration_bytes_status='verified',live_dispatch='not_tested',complete_object_layout='not_tested')


def parse_record(image,va,fields_va,expected_name=None):
    if image.number(va,'B')!=14:raise ProbeError('metadata_record_type_kind')
    name,n=image.short(va+1);header=va+1+n
    if expected_name is not None and name!=expected_name:raise ProbeError('metadata_record_name_mismatch')
    size=image.u32(header);managed_count=bounded_count(image.u32(header+4))
    if not 1<=size<=1024*1024:raise ProbeError('metadata_record_size')
    managed=[]
    for i in range(managed_count):
        entry=header+8+i*8;cell=image.u32(entry);offset=image.u32(entry+4)
        if offset>=size:raise ProbeError('metadata_managed_field_offset')
        managed.append(dict(offset=offset,type_info=image.type_reference(cell),raw_bytes_reference=image.reference(entry,8)))
    prefix=header+8+managed_count*8
    if fields_va!=prefix+1 or image.number(prefix,'B')!=0:raise ProbeError('metadata_record_extended_prefix_outside_scope')
    count=bounded_count(image.u32(fields_va));cursor=fields_va+4;fields=[]
    for i in range(count):
        start=cursor;cell=image.u32(cursor);offset=image.u32(cursor+4);flags=image.number(cursor+8,'B');field,n=image.short(cursor+9)
        if offset>=size:raise ProbeError('metadata_record_field_offset')
        cursor+=9+n;attributes=image.attributes(cursor);cursor+=attributes['length']
        fields.append(dict(name=field,offset=offset,flags_u8=flags,type_info=image.type_reference(cell),attributes=attributes,
            raw_bytes_reference=image.reference(start,cursor-start)))
    declared={(f['offset'],f['type_info'].get('type_info_address')) for f in fields}
    if any((f['offset'],f['type_info'].get('type_info_address')) not in declared for f in managed):
        raise ProbeError('metadata_managed_fields_disagree_with_extended_fields')
    return dict(status='inferred',name=name,type_info_address=hex(va),declared_size=size,managed_fields=managed,fields=fields,
        header_reference=image.reference(va,header+8-va),extended_prefix=dict(value_u8=0,meaning='not_tested',
            raw_bytes_reference=image.reference(prefix,5)),declaration_bytes_status='verified',
        initialization_and_serialization='not_tested',extended_layout_scope='Only the reviewed zero-prefix record variant')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir',type=Path,required=True);p.add_argument('--exe',required=True)
    p.add_argument('--plan',type=Path,default=ROOT/'docs/delphi-metadata-plan.json')
    p.add_argument('--output',type=Path,default=ROOT/'reports/p1/delphi-metadata-report.json')
    args=p.parse_args();game=absolute(args.game_dir);output=absolute(args.output)
    if ROOT/'reports/p1' not in output.parents:raise ProbeError('metadata_summary_must_be_public_P1')
    if game==output or game in output.parents or output in game.parents:raise ProbeError('metadata_input_output_overlap')
    relative=safe_member_name(args.exe);data=read_bounded(game/relative,64*1024*1024);sha=hashlib.sha256(data).hexdigest()
    plan=json.loads(read_bounded(args.plan));inventory=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    if plan.get('schema_version')!=1 or plan.get('source_sha256')!=sha or not any(f['path']==relative and f.get('sha256')==sha for f in inventory['files']):
        raise ProbeError('metadata_source_identity')
    validate_type_plan(plan)
    image=Image(data);classes=[];records=[];errors=[];negative=[]
    for entries,result,kind in [(plan.get('classes',[]),classes,'class'),(plan.get('records',[]),records,'record')]:
        for entry in entries:
            try:
                result.append(parse_class(image,int(entry['vmt'],16),entry['slots'],entry['name']) if kind=='class' else
                    parse_record(image,int(entry['type_info'],16),int(entry['fields_count_address'],16),entry['name']))
            except (ValueError,KeyError,struct.error) as exc:
                failure=dict(status='unsupported',name=entry.get('name'),error=str(exc));result.append(failure);errors.append(dict(kind=kind,**failure))
    if len(plan.get('negative_class_seeds',[]))>16:raise ProbeError('metadata_negative_probe_limit')
    for seed in plan.get('negative_class_seeds',[]):
        try:
            parse_class(image,int(seed,16),1);negative.append(dict(seed=seed,status='unsupported',reason='Unexpectedly accepted negative seed'))
        except (ValueError,struct.error) as exc:negative.append(dict(seed=seed,status='verified',scope='Rejected seed only',reason=str(exc)))
    if any(row['status']=='unsupported' for row in negative):errors.append(dict(kind='negative_probe',reason='negative seed accepted'))
    mismatches=sum(m.get('virtual_slot_match')=='unsupported' for c in classes for m in c.get('methods',[]))
    uncompared=sum(m.get('virtual_slot_match')=='not_tested' for c in classes for m in c.get('methods',[]))
    field_rows=[f for c in classes+records for f in c.get('fields',[])]
    report=dict(schema_version=1,dataset='real',status='unsupported' if errors else 'inferred',
        scope='Bounded PE32 metadata declarations, not live types, invocation or game compatibility',
        source_file=relative,source_sha256=sha,classes=classes,records=records,errors=errors,negative_probes=negative,
        bytes_examined=image.bytes_read,read_budget=image.budget,source_file_bytes=len(data),
        byte_count_scope='Cumulative metadata reads including repeated hashing; source is read separately for its full digest',
        compiler_version='not_tested',
        virtual_slot_mismatch_count=mismatches,uncompared_method_slot_count=uncompared,
        metadata_binding_coverage_status='unsupported' if mismatches else 'not_tested' if uncompared or not classes else 'verified',
        method_slot_comparison_scope='Only the explicit plan slots; entries without a comparison are not promoted to verified',
        omitted_field_type_count=sum(f['type_info']['status']=='not_tested' for f in field_rows),
        unsupported_attribute_count=sum(f['attributes']['status']=='unsupported' for f in field_rows),
        uninterpreted_method_signatures=sum(len(c.get('methods',[])) for c in classes),
        signature_semantics='not_tested',runtime_development_ready=False,
        original_files_written=False,target_execution='not_tested',external_game_data_uploads=False)
    write_json(output,report)
    print(json.dumps(dict(status=report['status'],classes=len(classes),records=len(records),errors=len(errors),bytes_read=image.bytes_read)))
    return 2 if errors else 0


if __name__=='__main__':raise SystemExit(main())
