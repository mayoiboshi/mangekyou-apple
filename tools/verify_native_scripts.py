#!/usr/bin/env python3
"""Crosscheck native lexical fingerprints and report bounded experimental execution."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .qlie_lex import lex,codec_for,decode_spans
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from qlie_lex import lex,codec_for,decode_spans
    from control_state_analysis import processing_deadline


def sha(data):return hashlib.sha256(data).hexdigest()


def fingerprints(data,relative):
    document=lex(data,relative,field_model='native_grouping')
    if document['status']!='verified':raise ProbeError('python_reference_lexical_failure')
    result=hashlib.sha256()
    def u32(value):result.update(struct.pack('<I',value))
    def text(value):
        if value is None:u32(0xffffffff)
        else:
            encoded=value.encode('utf-8');u32(len(encoded));result.update(encoded)
    for record in document['records']:
        text(record['record_type']);u32(record['byte_offset']);u32(record['byte_length']);text(record.get('token'))
        u32(record.get('line_count',1));u32(len(record['operands']))
        text(record.get('identifier') if record['record_type'] in {'include','label','sound_identifier'} else None)
        for field in record['operands']:
            text(field['raw']);text(field['key']);text(field['value']);u32(field['byte_offset']);u32(field['byte_length'])
    codec,bom,_=codec_for(data);decoded,spans=decode_spans(data[bom:],codec,bom);scalars=hashlib.sha256()
    for char,(a,b) in zip(decoded,spans):scalars.update(struct.pack('<III',ord(char),a,b-a))
    return dict(decodedUTF8SHA256=sha(decoded.encode('utf-8')),scalarFingerprint=scalars.hexdigest(),
        lexicalFingerprint=result.hexdigest(),recordCount=len(document['records'])),document


def compare_document(native,data,relative):
    expected,document=fingerprints(data,relative)
    if native.get('sourceFile')!=relative or native.get('sourceSHA256')!=sha(data):raise ProbeError('native_script_source_identity')
    lexical=native.get('lexical')
    if not lexical or native.get('issue'):raise ProbeError('native_script_lexical_failure')
    mismatches=[key for key,value in expected.items() if lexical.get(key)!=value]
    return dict(source_file=relative,source_sha256=sha(data),status='unsupported' if mismatches else 'verified',
        mismatched_fields=mismatches,records=expected['recordCount'],
        scope='Agreement with independent project lexical model only; original grammar/execution not_tested'),document


def validate_trace(machine,data,relative,document,source_lookup=None, allow_trace_suffix=False):
    allowed={'status','phase','profile','evidenceStatus','originalEngineEquivalence','scope','errorPolicy',
        'scalarInitialization','steps','currentLocation','stopReason','callDepth','variableCounts','trace',
        'moduleSnapshotCount','moduleSnapshotBytes','inputSnapshotPolicy','sourceSnapshotCount','tableObjectCount',
        'tableEntryCount','tableSnapshots','tableAuxiliaryResultFlags','objectLifetime',
        'listObjectCount','listLineCount','listSnapshots'}
    if set(machine)-allowed:raise ProbeError('native_machine_unapproved_public_fields')
    new_fields={'sourceSnapshotCount','tableObjectCount','tableEntryCount','tableSnapshots','tableAuxiliaryResultFlags','objectLifetime'}
    table_profiles={'experimental_static_contracts_v3','experimental_static_contracts_v4','experimental_static_contracts_v5','experimental_static_contracts_v6','experimental_static_contracts_v7','experimental_static_contracts_v8','experimental_static_contracts_v9','experimental_static_contracts_v10','experimental_static_contracts_v11','experimental_static_contracts_v12','experimental_static_contracts_v13','experimental_static_contracts_v14','experimental_static_contracts_v15','experimental_static_contracts_v16','experimental_static_contracts_v17','experimental_static_contracts_v18','experimental_static_contracts_v19','experimental_static_contracts_v20','experimental_static_contracts_v21','experimental_static_contracts_v22','experimental_static_contracts_v23','experimental_static_contracts_v24','experimental_static_contracts_v25','experimental_static_contracts_v26','experimental_static_contracts_v27','experimental_static_contracts_v28','experimental_static_contracts_v29','experimental_static_contracts_v30','experimental_static_contracts_v31','experimental_static_contracts_v32','experimental_static_contracts_v33','experimental_static_contracts_v34','experimental_static_contracts_v35','experimental_static_contracts_v36','experimental_static_contracts_v37','experimental_static_contracts_v38','experimental_static_contracts_v39','experimental_static_contracts_v40','experimental_static_contracts_v41'}
    if machine.get('profile') not in table_profiles and set(machine)&new_fields:
        raise ProbeError('native_table_fields_require_v3')
    if set(machine.get('variableCounts',{}))-{'system','global','all_local_frames'}:raise ProbeError('native_variable_names_in_summary')
    if machine.get('profile') not in {'experimental_static_contracts_v1','experimental_static_contracts_v2'}|table_profiles or machine.get('originalEngineEquivalence')!='not_tested':
        raise ProbeError('native_script_profile_or_equivalence')
    trace=machine['trace']
    steps=machine.get('steps')
    if type(steps) is not int or not 0<=len(trace)<=steps<=650_000 or (steps != len(trace) and (not allow_trace_suffix or not 1024<=len(trace)<2048)):
        raise ProbeError('native_trace_count')
    references=[machine['currentLocation']] if machine.get('currentLocation') else []
    sources={relative:(data,document,{(r['byte_offset'],r['byte_length']):r for r in document['records']},sha(data))}
    def context(name):
        if name not in sources:
            if source_lookup is None:raise ProbeError('native_cross_file_trace_without_pinned_lookup')
            if len(sources)>=512:raise ProbeError('native_trace_source_count_limit')
            content,doc=source_lookup(name)
            if len(content)+sum(len(v[0]) for v in sources.values())>128*1024*1024:raise ProbeError('native_trace_source_byte_limit')
            sources[name]=(content,doc,{(r['byte_offset'],r['byte_length']):r for r in doc['records']},sha(content))
        return sources[name]
    skipped_locations=set()
    for i,row in enumerate(trace, start=steps-len(trace)):
        if set(row)-{'sequence','location','recordType','command','commandSHA256','status','action','reason','target','callDepth','skipped','resultType','resource'}:
            raise ProbeError('native_trace_unapproved_public_fields')
        if row.get('sequence')!=i+1:raise ProbeError('native_trace_sequence')
        if row.get('status') not in {'inferred','unsupported'}:raise ProbeError('native_trace_overclaims_execution')
        ref=row['location'];_,_,originals,_=context(ref['sourceFile']);original=originals.get((ref['byteOffset'],ref['byteLength']))
        if not original or row.get('recordType')!=original['record_type']:raise ProbeError('native_trace_record_identity')
        token=original.get('token');safe=token if token and re.fullmatch(r'[A-Za-z?][A-Za-z_0-9?]{0,15}',token) else None
        if row.get('command')!=safe or row.get('commandSHA256')!=(sha(token.encode()) if token is not None else None):
            raise ProbeError('native_trace_command_identity')
        if row.get('reason') and not re.fullmatch(r'[A-Za-z_0-9]+',row['reason']):raise ProbeError('native_trace_unapproved_reason')
        if row.get('resultType') not in {None,'integer','string','object'}:raise ProbeError('native_trace_unapproved_result_type')
        if machine.get('profile') not in table_profiles and (row.get('resource') is not None or row.get('resultType')=='object'):
            raise ProbeError('native_object_trace_requires_v3')
        references.append(row['location'])
        for key in ['target','skipped','resource']:
            value=row.get(key)
            if value:references.append(value['location'] if key=='skipped' else value)
        skipped=row.get('skipped')
        if skipped:
            if set(skipped)-{'status','reason','location','recordCount','recordTypes'}:raise ProbeError('native_skipped_unapproved_fields')
            ref=skipped['location'];a=ref['byteOffset'];b=a+ref['byteLength']
            _,skipped_document,_,_=context(ref['sourceFile'])
            records=[r for r in skipped_document['records'] if a<=r['byte_offset'] and r['byte_offset']+r['byte_length']<=b]
            if len(records)!=skipped['recordCount'] or dict(Counter(r['record_type'] for r in records))!=skipped['recordTypes']:
                raise ProbeError('native_skipped_span_accounting')
            # Layout records inherit the following semantic record's line in Swift.
            anchor=next((r for r in skipped_document['records']
                         if r['byte_offset']>=a and 'line_number' in r),None)
            if not records or records[0]['byte_offset']!=a or not anchor or anchor['line_number']!=ref['lineNumber']:
                raise ProbeError('native_skipped_span_start')
            skipped_locations.add((ref['sourceFile'],a,ref['byteLength'],ref['lineNumber']))
    snapshots=machine.get('tableSnapshots',[])
    if machine.get('profile') in table_profiles:
        if machine.get('tableAuxiliaryResultFlags')!='not_tested':raise ProbeError('native_table_auxiliary_overclaim')
        for key,maximum in [('sourceSnapshotCount',512),('tableObjectCount',512),('tableEntryCount',100000)]:
            if type(machine.get(key)) is not int or not 0<=machine[key]<=maximum:raise ProbeError('native_table_counter_limit')
        if not isinstance(snapshots,list) or len(snapshots)>machine['tableObjectCount']:raise ProbeError('native_table_snapshot_count')
    total_lines=0
    for table in snapshots:
        if set(table)!={'status','scope','source','entryCount','emptyValueCount','lines'} or table['status']!='inferred':
            raise ProbeError('native_table_unapproved_summary')
        if not (type(table['entryCount']) is int and type(table['emptyValueCount']) is int and 0<=table['emptyValueCount']<=table['entryCount']<=10000):
            raise ProbeError('native_table_entry_count')
        references.append(table['source']);total_lines+=len(table['lines'])
        if total_lines>50000:raise ProbeError('native_table_line_limit')
        if __package__:
            from .table_analysis import table_text
        else:
            from table_analysis import table_text
        content,_,_,_=context(table['source']['sourceFile'])
        expected=table_text(content,table['source']['sourceFile'],wide_keys=table['scope']==
            'Candidate wide-key ordinal load with ASCII case folding; Windows NLS not emulated')
        if expected['status']=='unsupported' or len(expected['lines'])!=len(table['lines']):raise ProbeError('native_table_model_coverage')
        admitted={r['ascii_name_sha256']:r for r in expected['lines'] if r['candidate_disposition'] in {'value_candidate','empty_value_candidate','empty_marker_candidate'}}
        if table['entryCount']!=len(admitted) or table['emptyValueCount']!=sum(r['candidate_disposition'] in {'empty_value_candidate','empty_marker_candidate'} for r in admitted.values()):
            raise ProbeError('native_table_model_counts')
        for observed,wanted in zip(table['lines'],expected['lines']):
            disposition=wanted['candidate_disposition']
            action=('no_name_separator' if disposition in {'blank','no_separator'} else 'empty_name' if disposition=='empty_name' else
                'filtered_double_slash' if disposition=='rejected_slash_candidate' else 'first_name_value_reused' if wanted.get('duplicate_ascii_name') else
                'stored_empty' if disposition in {'empty_value_candidate','empty_marker_candidate'} else 'stored')
            if (observed.get('action')!=action or observed.get('keySHA256')!=wanted.get('name_sha256')
                or observed.get('selectedValueSHA256')!=wanted.get('selected_value_sha256') or observed['location']['byteOffset']!=wanted['byte_offset']
                or observed['location']['byteLength']!=wanted['byte_length'] or observed['location']['lineNumber']!=wanted['line_number']):
                raise ProbeError('native_table_model_line_mismatch')
        for line in table['lines']:
            if set(line)-{'location','action','keySHA256','selectedValueSHA256','status'} or line.get('status')!='inferred':
                raise ProbeError('native_table_unapproved_line')
            if line.get('action') not in {'no_name_separator','empty_name','filtered_double_slash','first_name_value_reused','stored_empty','stored'}:
                raise ProbeError('native_table_unknown_line_action')
            for key in ['keySHA256','selectedValueSHA256']:
                if line.get(key) is not None and not re.fullmatch(r'[a-f0-9]{64}',line[key]):raise ProbeError('native_table_unapproved_value')
            if line['location']['sourceFile']!=table['source']['sourceFile']:raise ProbeError('native_table_line_source')
            references.append(line['location'])
    loaded_entries = sum(t['entryCount'] for t in snapshots)
    current_entries = machine.get('tableEntryCount')
    overlaid = machine.get('profile') in {'experimental_static_contracts_v8','experimental_static_contracts_v9','experimental_static_contracts_v10','experimental_static_contracts_v11','experimental_static_contracts_v12','experimental_static_contracts_v13','experimental_static_contracts_v14','experimental_static_contracts_v15','experimental_static_contracts_v16','experimental_static_contracts_v17','experimental_static_contracts_v18','experimental_static_contracts_v19','experimental_static_contracts_v20','experimental_static_contracts_v21','experimental_static_contracts_v22','experimental_static_contracts_v23','experimental_static_contracts_v24','experimental_static_contracts_v25','experimental_static_contracts_v26','experimental_static_contracts_v27','experimental_static_contracts_v28','experimental_static_contracts_v29','experimental_static_contracts_v30','experimental_static_contracts_v31','experimental_static_contracts_v32','experimental_static_contracts_v33','experimental_static_contracts_v34','experimental_static_contracts_v35','experimental_static_contracts_v36','experimental_static_contracts_v37','experimental_static_contracts_v38','experimental_static_contracts_v39','experimental_static_contracts_v40','experimental_static_contracts_v41'} and any(
        row.get('action') == 'table_overlay_nonempty_candidate' for row in machine['trace'])
    if snapshots:
        valid_total = (type(current_entries) is int and loaded_entries <= current_entries <= 100_000
                       if overlaid else current_entries == loaded_entries)
        if not valid_total:
            raise ProbeError('native_table_entry_total')
    list_fields={'listObjectCount','listLineCount','listSnapshots'}
    list_line_locations=set()
    list_profiles={'experimental_static_contracts_v5','experimental_static_contracts_v6','experimental_static_contracts_v7','experimental_static_contracts_v8','experimental_static_contracts_v9','experimental_static_contracts_v10','experimental_static_contracts_v11','experimental_static_contracts_v12','experimental_static_contracts_v13','experimental_static_contracts_v14','experimental_static_contracts_v15','experimental_static_contracts_v16','experimental_static_contracts_v17','experimental_static_contracts_v18','experimental_static_contracts_v19','experimental_static_contracts_v20','experimental_static_contracts_v21','experimental_static_contracts_v22','experimental_static_contracts_v23','experimental_static_contracts_v24','experimental_static_contracts_v25','experimental_static_contracts_v26','experimental_static_contracts_v27','experimental_static_contracts_v28','experimental_static_contracts_v29','experimental_static_contracts_v30','experimental_static_contracts_v31','experimental_static_contracts_v32','experimental_static_contracts_v33','experimental_static_contracts_v34','experimental_static_contracts_v35','experimental_static_contracts_v36','experimental_static_contracts_v37','experimental_static_contracts_v38','experimental_static_contracts_v39','experimental_static_contracts_v40','experimental_static_contracts_v41'}
    if machine.get('profile') not in list_profiles and set(machine)&list_fields:
        raise ProbeError('native_list_fields_require_v5')
    if machine.get('profile') in list_profiles:
        if __package__:
            from .list_text import string_list_text
        else:
            from list_text import string_list_text
        for key,maximum in [('listObjectCount',512),('listLineCount',50000)]:
            if type(machine.get(key)) is not int or not 0<=machine[key]<=maximum:raise ProbeError('native_list_counter_limit')
        lists=machine.get('listSnapshots')
        if not isinstance(lists,list) or len(lists)>machine['listObjectCount'] or machine['listObjectCount']+machine['tableObjectCount']>512:
            raise ProbeError('native_list_snapshot_count')
        if sum(r.get('lineCount',-1) for r in lists)!=machine['listLineCount']:raise ProbeError('native_list_line_total')
        for observed in lists:
            if set(observed)!={'status','source','lineCount','nameCount','unresolvedNameCount','lines','scope'} or observed['status']!='inferred':
                raise ProbeError('native_list_unapproved_summary')
            content,_,_,_=context(observed['source']['sourceFile'])
            expected=string_list_text(content,observed['source']['sourceFile'])
            if {k:v for k,v in observed.items() if k!='scope'}!=expected:raise ProbeError('native_list_model_mismatch')
            references.append(observed['source']);references.extend(r['location'] for r in observed['lines'])
            list_line_locations.update((r['location']['sourceFile'],r['location']['byteOffset'],r['location']['byteLength'],r['location']['lineNumber']) for r in expected['lines'])
    binary_members = {
        (ref['sourceFile'], ref['byteOffset'], ref['byteLength'], ref['rangeSHA256'])
        for row in trace if row['action'] == 'button_container_image_bind_candidate'
        for ref in [row['resource']] if ref
    }
    for ref in references:
        if set(ref)!={'sourceFile','sourceSHA256','byteOffset','byteLength','rangeSHA256','lineNumber'}:raise ProbeError('native_location_unapproved_fields')
        a=ref['byteOffset'];length=ref['byteLength']
        source,_,originals,identity=context(ref['sourceFile'])
        if ref['sourceSHA256']!=identity or type(a) is not int or type(length) is not int or (
            a<0 or length<0 or a+length>len(source)) or sha(source[a:a+length])!=ref['rangeSHA256']:
            raise ProbeError('native_trace_byte_reference')
        if (ref['sourceFile'],a,length,ref['rangeSHA256']) in binary_members:
            if ref['lineNumber'] != 1 or not source.startswith(b'abmp12') or not source[a:a+length].startswith(b'\x89PNG\r\n\x1a\n'):
                raise ProbeError('native_trace_binary_image_reference')
            continue
        original=originals.get((a,length))
        list_line=(ref['sourceFile'],a,length,ref['lineNumber']) in list_line_locations
        if original and not list_line and 'line_number' in original and ref['lineNumber']!=original['line_number']:
            raise ProbeError('native_trace_line_number')
        whole_source = a == 0 and length == len(source) and ref['lineNumber'] == 1
        if not original and not whole_source and (ref['sourceFile'],a,length,ref['lineNumber']) not in skipped_locations:
            codec,bom,_=codec_for(source)
            try:prefix=source[bom:a].decode(codec) if a>=bom else ''
            except UnicodeError:raise ProbeError('native_trace_partial_scalar_reference')
            if ref['lineNumber']!=len(re.findall(r'\r\n|\r|\n',prefix))+1:raise ProbeError('native_trace_resource_line_number')
    if machine.get('phase')=='stopped' and trace and trace[-1]['action']=='stop' and (
        trace[-1]['location']!=machine.get('currentLocation') or trace[-1].get('reason')!=machine.get('stopReason')):
        raise ProbeError('native_stop_was_advanced_past')
    return len(references)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',required=True,type=Path);p.add_argument('--script-file',required=True)
    args=p.parse_args();assets=absolute(args.assets_dir);relative=safe_member_name(args.script_file)
    private=ROOT/'private/p1-round21';private.mkdir(parents=True,exist_ok=True)
    if assets==private or assets in private.parents or private in assets.parents:raise ProbeError('native_script_input_output_overlap')
    def source_hashes():
        return {path.relative_to(ROOT).as_posix():sha(read_bounded(path)) for path in sorted((ROOT/'native').rglob('*.swift')) if '.build' not in path.parts}
    source_identity=source_hashes()
    compiled=subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'--product','mangekyou-script'],
        capture_output=True,timeout=120,cwd=ROOT)
    (private/'script-build.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode or source_identity!=source_hashes():raise ProbeError('native_script_build_failed_or_sources_changed')
    binary=(ROOT/'native/.build/debug/mangekyou-script').resolve()
    if ROOT/'native/.build' not in binary.parents or binary.name!='mangekyou-script':raise ProbeError('native_script_binary_outside_build_tree')
    executable=read_bounded(binary)
    if executable[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',executable,4)[0]!=0x0100000c:
        raise ProbeError('native_script_binary_not_ARM64_MachO')
    manifest=ROOT/'reports/p1/corpus-report.json';corpus=json.loads(read_bounded(manifest));items=corpus['items']
    if not 1<=len(items)<=2000:raise ProbeError('native_script_corpus_count')
    jobs=[];documents={}
    for label,options in [('corpus',['--manifest',str(manifest)]),('startup',['--script',relative,'--experimental-run'])]:
        process=subprocess.run([str(binary),'--assets-dir',str(assets)]+options,capture_output=True,timeout=150,cwd=ROOT)
        (private/(label+'-stderr.log')).write_bytes(process.stderr)
        if process.returncode not in {0,2} or len(process.stdout)>32*1024*1024:raise ProbeError('native_script_process_failed_or_output_limit')
        value=json.loads(process.stdout);write_json(private/('native-'+label+'.json'),value);documents[label]=value
        jobs.append(dict(name=label,exit_code=process.returncode,reported_status=value['status']))
    rows=documents['corpus']['reports'];by_name={r['sourceFile']:r for r in rows}
    if len(rows)!=len(items) or len(by_name)!=len(rows) or set(by_name)!={r['source_file'] for r in items}:
        raise ProbeError('native_script_corpus_coverage')
    comparisons=[];total=0
    with processing_deadline(120):
        for item in items:
            name=safe_member_name(item['source_file']);data=read_bounded(assets/name,16*1024*1024);total+=len(data)
            if total>128*1024*1024 or sha(data)!=item['sha256']:raise ProbeError('native_script_corpus_identity_or_size')
            checked,_=compare_document(by_name[name],data,name);comparisons.append(checked)
        selected=documents['startup']['reports']
        if len(selected)!=1 or relative not in by_name:raise ProbeError('native_script_selected_source_missing')
        data=read_bounded(assets/relative,16*1024*1024);checked,document=compare_document(selected[0],data,relative)
        if checked['status']!='verified':raise ProbeError('native_selected_lexical_mismatch')
        machine=selected[0].get('machine')
        if not machine:raise ProbeError('native_script_execution_not_observed')
        references=validate_trace(machine,data,relative,document)
    write_json(private/'crosscheck.json',dict(items=comparisons,jobs=jobs))
    report=dict(schema_version=1,status='inferred' if all(r['status']=='verified' for r in comparisons) else 'unsupported',dataset='real',
        scope='Native lexical agreement and one explicit experimental prefix; not a game startup or native-engine equivalence test',
        native_binary_sha256=sha(executable),native_source_sha256=source_identity,physical_corpus_files=len(items),all_versions_preserved=True,
        lexical_crosscheck=dict(status='verified' if all(r['status']=='verified' for r in comparisons) else 'unsupported',
            decoded_text_mismatches=sum('decodedUTF8SHA256' in r['mismatched_fields'] for r in comparisons),
            scalar_span_mismatches=sum('scalarFingerprint' in r['mismatched_fields'] for r in comparisons),
            lexical_record_mismatches=sum('lexicalFingerprint' in r['mismatched_fields'] for r in comparisons),
            record_count=sum(r['records'] for r in comparisons),scope='Two project parsers may share an incomplete grammar hypothesis'),
        jobs=jobs,selected_source=dict(source_file=relative,source_sha256=sha(data),byte_reference_count=references,
            byte_reference_status='verified',machine=machine),
        original_engine_equivalence='not_tested',full_game_compatibility='not_tested',actual_game_bootstrap='not_tested',
        original_files_written=False,external_game_data_uploads=False,commercial_text_in_public_report=False)
    write_json(ROOT/'reports/p1/native-script-report.json',report)
    print(json.dumps(dict(status=report['status'],files=len(items),lexical=report['lexical_crosscheck']['status'],
        experimental_phase=machine['phase'],experimental_stop=machine.get('stopReason'),steps=machine['steps'])))
    return 2 if report['status']=='unsupported' else 0


if __name__=='__main__':raise SystemExit(main())
