#!/usr/bin/env python3
"""P1 static corpus facts. No game execution, expression evaluation or patch selection."""
import argparse
from collections import Counter, defaultdict
import difflib
import hashlib
import json
import os
from pathlib import Path, PureWindowsPath
import posixpath
import re
import unicodedata

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, inventory, read_bounded, safe_member_name, safe_open, write_json
    from .qlie_lex import codec_for, digest, lex, sanitized, split_fields
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, inventory, read_bounded, safe_member_name, safe_open, write_json
    from qlie_lex import codec_for, digest, lex, sanitized, split_fields

PUBLIC_EDGE_LIMIT=200
ASSET_EXT={'.png','.jpg','.jpeg','.bmp','.b','.ogg','.ogv','.wav','.mp3','.flac','.mp4','.avi'}


def norm(value):return unicodedata.normalize('NFC',value.replace('\\','/')).casefold()


def identifier(value):
    return value if re.fullmatch(r'[A-Za-z_!#@$?.][A-Za-z_0-9!#@$?.-]*',value or '') else 'sha256:'+digest((value or '').encode())


def evidence(doc, record):
    return dict(source_file=doc['source_file'],source_sha256=doc['sha256'],byte_offset=record['byte_offset'],
        byte_length=record['byte_length'],record_sha256=record['raw_bytes_reference']['sha256'],
        token=record.get('token'),semantic_status='not_tested')


def lexical_fingerprints(doc):
    fields=[];tokens=[]
    for r in doc['records']:
        if r['record_type'] not in {'command','line_tag','label','include','macro_assignment_candidate','setting_assignment_candidate'}:
            continue
        tokens.append([r['record_type'],r.get('token')])
        fields.append([r['record_type'],r.get('token'),r.get('identifier'),r.get('rhs'),
            [[f['key'],f['value'],f['quoted']] for f in r.get('operands',[])]])
    def checksum(value):return digest(json.dumps(value,ensure_ascii=False,separators=(',',':')).encode())
    return dict(token_sequence_sha256=checksum(tokens),lexical_fields_sha256=checksum(fields))


def path_options(source, value):
    """Symbolic hypotheses only; never touches filesystem or chooses a mount order."""
    if not value or '\x00' in value or PureWindowsPath(value).drive or value.startswith(('/','\\\\')):
        return []
    values=[value.replace('\\','/')]
    if value.startswith('!'):values.append(value[1:].replace('\\','/'))
    options=[]
    for spelling in values:
        for base in ['',posixpath.dirname(source)]:
            name=posixpath.normpath(posixpath.join(base,spelling))
            if name in {'.','..'} or name.startswith('../'):continue
            options.append(norm(name))
    return list(dict.fromkeys(options))


def overlay_report(documents, archive_items):
    groups=defaultdict(list);registry=defaultdict(list)
    for doc in documents:
        doc.update(lexical_fingerprints(doc));groups[norm(doc['logical_path'])].append(doc)
    for archive in archive_items:
        if not archive['path'].startswith('GameData/'):continue
        for entry in archive.get('index',{}).get('entries',[]):
            registry[norm(entry['name'])].append(dict(archive=archive['path'],index=entry['index'],
                name=entry['name'].replace('\\','/'),stored_size=entry['compressed_size'],
                decoded_size=entry['original_size'],content_equality='not_tested'))
    duplicate_groups=[];counts=Counter()
    for path,variants in sorted(groups.items()):
        if len(variants)<2:continue
        if len({d['sha256'] for d in variants})==1:relation='raw_equal'
        elif len({d['normalized_text_sha256'] for d in variants})==1:relation='line_ending_normalized_text_equal'
        else:relation='normalized_text_changed'
        counts[relation]+=1
        item=dict(logical_path=path,comparison_status='verified',relation=relation,load_precedence='not_tested',
            variants=[{k:d[k] for k in ['source_file','sha256','encoding','normalized_text_sha256',
                'nonblank_text_sha256','token_sequence_sha256','lexical_fields_sha256','origin']} for d in variants],
            same_token_sequence=len({d['token_sequence_sha256'] for d in variants})==1,
            same_lexical_fields=len({d['lexical_fields_sha256'] for d in variants})==1,
            fingerprint_scope='Ignores opaque text/layout; preserves parsed values. Equality is not behavioral equivalence')
        if relation=='normalized_text_changed':
            a=variants[0];item['normalized_line_diffs']=[]
            for b in variants[1:]:
                changes=difflib.SequenceMatcher(a=a['_normalized_lines'],b=b['_normalized_lines'],autojunk=True).get_opcodes()
                item['normalized_line_diffs'].append(dict(left_source=a['source_file'],right_source=b['source_file'],
                    reference_selection='comparison baseline only; not a load-precedence choice',
                    changes=[dict(operation=t,left_lines=[i+1,j+1],right_lines=[k+1,l+1],
                        ranges='one-based end-exclusive; source SHA identifies variant; no body emitted')
                        for t,i,j,k,l in changes if t!='equal']))
        duplicate_groups.append(item)
    all_duplicates=[dict(logical_path=k,variants=v,load_precedence='not_tested') for k,v in sorted(registry.items()) if len(v)>1]
    return dict(status='verified',scope='content comparisons only',text_duplicate_groups=len(duplicate_groups),
        comparison_counts=dict(counts),groups=duplicate_groups,all_archive_duplicate_paths=len(all_duplicates),
        archive_duplicates=all_duplicates,patch_precedence='not_tested',behavioral_equivalence='not_tested')


def symbol_report(documents):
    docs={d['source_file']:d for d in documents};files=defaultdict(list);labels=defaultdict(list)
    per_doc_labels=defaultdict(lambda:defaultdict(list));includes=[];adj=defaultdict(set)
    declarations=[];macros=[];macro_defs=defaultdict(list);control=[];dynamic_control=[]
    for d in documents:files[norm(d['logical_path'])].append(d['source_file'])
    for d in documents:
        for r in d['records']:
            if r['record_type']=='label':
                item=dict(name=identifier(r['identifier']),**evidence(d,r),confidence='inferred',scope='unresolved')
                labels[norm(r['identifier'])].append(item);per_doc_labels[d['source_file']][norm(r['identifier'])].append(item)
            elif r['record_type']=='macro_assignment_candidate':
                item=dict(name=identifier(r['identifier']),rhs_sha256=digest(r['rhs'].encode()),**evidence(d,r))
                macros.append(item);macro_defs[norm(r['identifier'])].append(item)
            elif r['record_type']=='command' and r['token'].lower() in {'var','gvar','svar'}:
                values=[f['value'] for f in r['operands']]
                declarations.append(dict(**evidence(d,r),declaration_token=r['token'],
                    type_spelling=identifier(values[0]) if values else None,
                    symbols=[identifier(v) for v in values[1:]],confidence='inferred',scope_semantics='not_tested'))
            if r['record_type']=='include':
                options=path_options(d['logical_path'],r['identifier'])
                candidates=list(dict.fromkeys(f for option in options for f in files.get(option,[])))
                item=dict(**evidence(d,r),spelling=r['identifier'],lookup_hypotheses=options,candidates=candidates,
                    status='inferred' if candidates else 'unsupported',bang_semantics='not_tested',
                    order_and_once_semantics='not_tested')
                includes.append(item);adj[d['source_file']].update(candidates)
    closures={}
    for source in docs:
        seen=set();todo=list(adj[source])
        while todo:
            name=todo.pop()
            if name in seen:continue
            seen.add(name);todo.extend(adj[name]-seen)
        closures[source]=seen
    for d in documents:
        for r in d['records']:
            if r['record_type'] not in {'command','line_tag'}:continue
            file_fields=[f['value'] for f in r['operands'] if f['value'].lower().endswith(('.s','.txt'))]
            file_candidates=list(dict.fromkeys(f for value in file_fields for option in path_options(d['logical_path'],value) for f in files.get(option,[])))
            targets=[f['value'][2:] for f in r['operands'] if f['value'].startswith('@@') and re.fullmatch(r'@@[^\s,"\\]+',f['value'])]
            if r['record_type']=='command' and r.get('token','').lower() in {'sub','jmp','go'} and not targets:
                dynamic_control.append(dict(**evidence(d,r),status='unsupported',
                    unknown_reason='No literal @@ target; computed/alternate target syntax not evaluated',
                    operands_sha256=[digest(f['value'].encode()) for f in r['operands']]))
            for target in targets:
                key=norm(target)
                if file_fields:
                    candidates=[x for f in file_candidates for x in per_doc_labels[f].get(key,[])]
                    basis='explicit_file_hypotheses'
                elif per_doc_labels[d['source_file']].get(key):
                    candidates=per_doc_labels[d['source_file']][key];basis='same_file_candidate'
                else:
                    candidates=[x for f in sorted(closures[d['source_file']]) for x in per_doc_labels[f].get(key,[])]
                    basis='include_closure_hypothesis'
                    if not candidates:candidates=labels.get(key,[]);basis='corpus_global_fallback_hypothesis'
                control.append(dict(**evidence(d,r),relationship='label_literal',target=identifier(target),
                    explicit_file_candidates=file_candidates,candidates=candidates,basis=basis,
                    status='inferred' if candidates else 'unsupported',execution_edge='not_tested'))
    macro_refs=[]
    for d in documents:
        for r in d['records']:
            texts=([r['rhs']] if 'rhs' in r else [])+[f['value'] for f in r.get('operands',[])]
            for text in texts:
                for name in sorted(set(re.findall(r'\$[A-Za-z_][A-Za-z_0-9]*',text))):
                    candidates=macro_defs.get(norm(name),[])
                    macro_refs.append(dict(**evidence(d,r),name=identifier(name),candidates=candidates,
                        status='inferred' if candidates else 'not_tested',
                        unknown_reason='Dollar token may be numeric, macro or other syntax; no expansion/evaluation'))
    return dict(status='inferred',label_definitions=sum(len(v) for v in labels.values()),
        labels=[x for v in labels.values() for x in v],includes=includes,include_count=len(includes),
        include_status_counts=dict(Counter(i['status'] for i in includes)),
        label_references=control,label_reference_count=len(control),
        label_reference_status_counts=dict(Counter(e['status'] for e in control)),
        dynamic_control_targets=dynamic_control,dynamic_control_target_count=len(dynamic_control),
        variable_declarations=declarations,variable_declaration_count=len(declarations),
        macro_definitions=macros,macro_definition_count=len(macros),macro_references=macro_refs,
        macro_reference_count=len(macro_refs),execution_semantics='unsupported',patch_precedence='not_tested')


def resource_report(documents, archive_items):
    exact=defaultdict(list);stem=defaultdict(list);base=defaultdict(list)
    for archive in archive_items:
        if not archive['path'].startswith('GameData/'):continue
        for entry in archive.get('index',{}).get('entries',[]):
            name=entry['name'].replace('\\','/');suffix=posixpath.splitext(name)[1].lower()
            if suffix not in ASSET_EXT:continue
            item=dict(archive=archive['path'],index=entry['index'],name=name,
                format_status='not_tested',format_hint_from_extension=suffix)
            exact[norm(name)].append(item);stem[norm(posixpath.splitext(name)[0])].append(item)
            base[norm(posixpath.splitext(posixpath.basename(name))[0])].append(item)
    edges=[];unresolved=[];dynamic=Counter();field_errors=[]
    for d in documents:
        for r in d['records']:
            fields=r.get('operands',[])
            if r['record_type']=='sound_identifier':fields=fields+[dict(value=r['identifier'],key=None)]
            if 'rhs' in r:
                try:fields=fields+split_fields(r['rhs'])
                except ProbeError as exc:
                    dynamic['unparsed_assignment_rhs']+=1
                    field_errors.append(dict(**evidence(d,r),status='unsupported',category=str(exc),rhs_sha256=digest(r['rhs'].encode())))
            for field in fields:
                value=field['value'].strip();key=field.get('key')
                if not value:continue
                if any(c in value for c in '#$%[]{}@+*<>|='):
                    dynamic['expression_or_template_fields']+=1;continue
                options=path_options(d['logical_path'],value)
                candidates=[];basis='root_or_relative_path_hypotheses'
                for option in options:candidates.extend(exact.get(option,[]))
                if not candidates:
                    for option in options:candidates.extend(stem.get(option,[]))
                    basis='extensionless_path_hypotheses'
                if not candidates and '/' not in value and '\\' not in value:
                    candidates.extend(base.get(norm(value),[]));basis='basename_stem_hypothesis'
                unique={(c['archive'],c['index']):c for c in candidates};candidates=list(unique.values())
                item=dict(**evidence(d,r),identifier=value,key=key,basis=basis,candidates=candidates,
                    relationship_type='Unknown',status='inferred',runtime_binding='not_tested')
                if candidates:edges.append(item)
                elif key in {'file','sound','voice','bgm'} or r['record_type']=='sound_identifier' or posixpath.splitext(value)[1].lower() in ASSET_EXT:
                    item['status']='unsupported';unresolved.append(item)
    return dict(status='inferred',matched_candidate_edges=len(edges),edges=edges,
        unique_candidate_edges=sum(len(e['candidates'])==1 for e in edges),
        ambiguous_candidate_edges=sum(len(e['candidates'])>1 for e in edges),
        unresolved_literal_count=len(unresolved),unresolved=unresolved,dynamic_fields=dict(dynamic),
        field_errors=field_errors,
        roles={k:'not_tested' for k in ['background','sprite','voice','bgm','sfx','animation']},runtime_binding='not_tested')


def public_projection(name, report):
    copy=dict(report)
    arrays={'overlay-report.json':['archive_duplicates'],
        'symbol-report.json':['labels','includes','label_references','dynamic_control_targets','variable_declarations','macro_definitions','macro_references'],
        'resource-report.json':['edges','unresolved']}
    for key in arrays.get(name,[]):
        values=copy.get(key,[])
        copy[key]=values[:PUBLIC_EDGE_LIMIT]
        copy[key+'_retained_total']=len(values)
        copy[key+'_public_sample_limit']=PUBLIC_EDGE_LIMIT
    copy['complete_metadata_report']='private/p1/'+name
    copy['complete_metadata_report_canonical_sha256']=digest((json.dumps(report,ensure_ascii=False,sort_keys=True,separators=(',',':'))+'\n').encode())
    return copy


def validate_outputs(assets,game_dir,private,output):
    if ROOT/'private' not in private.parents:raise ProbeError('full P1 reports must remain private')
    if output!=ROOT/'reports/p1' and ROOT/'private' not in output.parents:
        raise ProbeError('public P1 output must be reports/p1 or private/')
    inputs=[assets]+([absolute(game_dir)] if game_dir else [])
    for target in [private,output]:
        for source in inputs:
            if target==source or source in target.parents or target in source.parents:
                raise ProbeError('input/output overlap')


def run(args):
    assets=absolute(args.assets_dir);private=absolute(args.private_output);output=absolute(args.output)
    validate_outputs(assets,args.game_dir,private,output)
    manifest=json.loads(read_bounded(args.samples));archives=json.loads(read_bounded(args.archives))['items']
    current=inventory(assets)
    if current['errors']:raise ProbeError('unsafe_asset_tree:'+str(current['errors']))
    documents=[];errors=[];bytes_total=0
    for archive in manifest['archives']:
        for sample in archive.get('entries',[]):
            if sample.get('status')!='verified' or Path(sample['name']).suffix.lower() not in {'.s','.txt'}:continue
            rel=safe_member_name(sample['copy_path'])
            try:
                data=read_bounded(assets/rel,16*1024*1024);bytes_total+=len(data)
                if bytes_total>128*1024*1024 or len(documents)>=2000:raise ProbeError('corpus_limit')
                if digest(data)!=sample['sha256']:raise ProbeError('sample_sha256_mismatch')
                doc=lex(data,rel);codec,bom,_=codec_for(data)
                text=data[bom:].decode(codec).replace('\r\n','\n').replace('\r','\n')
                doc.update(logical_path=sample['name'].replace('\\','/'),
                    normalized_text_sha256=digest(text.encode()),nonblank_text_sha256=digest('\n'.join(l.rstrip() for l in text.split('\n') if l.strip()).encode()),
                    _normalized_lines=text.split('\n'),origin=dict(archive=archive['archive'],
                    archive_sha256=archive['source_archive_sha256'],index=sample['index'],
                    offset=sample['offset'],stored_size=sample['compressed_size'],decoded_sha256=sample['sha256']))
                errors.extend(dict(source_file=rel,**e) for e in doc['errors']);documents.append(doc)
            except (OSError,ValueError) as exc:
                errors.append(dict(source_file=rel,category=type(exc).__name__,detail=str(exc)))
    integrity=[]
    if args.game_dir:
        for archive in archives:
            path=absolute(args.game_dir)/safe_member_name(archive['path'])
            with os.fdopen(safe_open(path),'rb') as stream:
                hasher=hashlib.sha256()
                for block in iter(lambda:stream.read(1024*1024),b''):hasher.update(block)
            match=hasher.hexdigest()==archive['sha256']
            integrity.append(dict(path=archive['path'],sha256=hasher.hexdigest(),status='verified' if match else 'unsupported'))
    tokens=Counter((r['record_type'],r['token']) for d in documents for r in d['records'] if r.get('token'))
    inline_count=sum(sum(n>1 for n in Counter(r['line_number'] for r in d['records'] if r['record_type']=='command').values()) for d in documents)
    script_documents=[d for d in documents if Path(d['source_file']).suffix.lower()=='.s']
    script_tokens=Counter((r['record_type'],r['token']) for d in script_documents for r in d['records'] if r.get('token'))
    corpus=dict(status='unsupported' if errors else ('verified' if documents else 'not_tested'),files=len(documents),bytes=bytes_total,errors=errors,
        encoding_counts=dict(Counter(d['encoding'] for d in documents)),
        physical_lines=sum(d['physical_lines'] for d in documents),record_count=sum(len(d['records']) for d in documents),
        inline_command_lines=inline_count,distinct_command_tokens=len({t for k,t in tokens if k=='command'}),
        unknown_token_shape_count=sum(r.get('token_shape_status')=='unsupported' for d in documents for r in d['records']),
        distinct_line_tag_tokens=len({t for k,t in tokens if k=='line_tag'}),
        script_only_distinct_command_tokens=len({t for k,t in script_tokens if k=='command'}),
        script_only_distinct_line_tag_tokens=len({t for k,t in script_tokens if k=='line_tag'}),
        token_counts=[dict(record_type=k,token=identifier(t),count=v) for (k,t),v in tokens.most_common()],
        items=[dict(source_file=d['source_file'],logical_path=d['logical_path'],sha256=d['sha256'],encoding=d['encoding'],
            encoding_status=d['encoding_status'],physical_lines=d['physical_lines'],byte_coverage=d['byte_coverage'],
            record_types=dict(Counter(r['record_type'] for r in d['records'])),origin=d['origin']) for d in documents],
        representative_records=[sanitized(r) for d in documents for r in d['records'] if r['record_type']=='command'][:32],
        original_archive_integrity=integrity,original_archive_integrity_status='not_tested' if not integrity else ('verified' if all(i['status']=='verified' for i in integrity) else 'unsupported'),
        execution_semantics='unsupported')
    corpus['grammar_profile']=dict(status='inferred',rule='Backslash fragments outside quoted strings; exact source byte coverage verified, complete engine grammar not_tested')
    result={'corpus-report.json':corpus,'overlay-report.json':overlay_report(documents,archives),
        'symbol-report.json':symbol_report(documents),'resource-report.json':resource_report(documents,archives)}
    provenance=dict(schema_version=1,dataset='real',scope='P1 static facts and explicit hypotheses; no execution',
        source_sample_manifest_sha256=digest(read_bounded(args.samples)),original_files_written=False,
        external_game_data_uploads=False,commercial_text_in_public_reports=False)
    for name,body in result.items():
        full={**provenance,**body};write_json(private/name,full)
        write_json(output/name,public_projection(name,full))
    # Full IR is private; parameters may include commercial strings. No script body is published.
    for doc in documents:
        doc.pop('_normalized_lines',None)
        write_json(private/'ir'/Path(doc['source_file']+'.json'),doc)
    print(json.dumps(dict(files=len(documents),errors=len(errors),inline_command_lines=inline_count,
        overlay_counts=result['overlay-report.json']['comparison_counts'],
        include_count=result['symbol-report.json']['include_count'],label_references=result['symbol-report.json']['label_reference_count'],
        resource_candidate_edges=result['resource-report.json']['matched_candidate_edges'])))
    return 2 if errors or any(i['status']!='verified' for i in integrity) else 0


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--samples',type=Path,default=ROOT/'private/real-p0/sample-report.json')
    ap.add_argument('--archives',type=Path,default=ROOT/'private/real-p0/archive-report.json')
    ap.add_argument('--game-dir',type=Path)
    ap.add_argument('--private-output',type=Path,default=ROOT/'private/p1')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p1')
    args=ap.parse_args();return run(args)


if __name__=='__main__':raise SystemExit(main())
