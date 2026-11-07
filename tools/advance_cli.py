#!/usr/bin/env python3
"""Run the native CLI to its next real stop, with an explicit experimental source cohort."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
from verify_native_scripts import fingerprints, validate_trace
from control_state_analysis import processing_deadline


def sha(data):return hashlib.sha256(data).hexdigest()


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',required=True,type=Path);p.add_argument('--script',default='data0.pack/startup.s')
    p.add_argument('--source-cohort',required=True,help='Explicit experiment, e.g. data8; not original package precedence')
    p.add_argument('--game-dir',type=Path)
    p.add_argument('--maximum-steps',type=int,default=10_000)
    p.add_argument('--click-ticks',type=int)
    p.add_argument('--dispatch-stop-callback',action='store_true')
    p.add_argument('--message-click',action='store_true')
    p.add_argument('--message-clicks',type=int,choices=range(1,97))
    p.add_argument('--button-index',type=int)
    p.add_argument('--pointer',help='Explicit input sample X,Y for the stop callback')
    p.add_argument('--movie-source')
    p.add_argument('--audio-source',action='append',default=[])
    p.add_argument('--wave-source',action='append',default=[])
    p.add_argument('--headless-movie-tools',type=Path)
    p.add_argument('--image-source',action='append',default=[])
    p.add_argument('--image-audit',type=Path,action='append',default=[])
    p.add_argument('--plain-image-source',action='append',default=[])
    p.add_argument('--resource-index',type=Path)
    p.add_argument('--selection-seed',type=Path,help='Reuse pinned choices from a previous same-cohort report')
    report_mode=p.add_mutually_exclusive_group()
    report_mode.add_argument('--private-report',action='store_true',help='Keep the summary alongside the private trace (default)')
    report_mode.add_argument('--publish-summary',action='store_true',help='Write a reviewed milestone summary under reports/p1')
    p.add_argument('--full-trace',action='store_true',help='Retain and validate every execution record')
    p.add_argument('--stage',default='round29');a=p.parse_args()
    if not re.fullmatch(r'data(?:[0-9]|[12][0-9]|3[01])',a.source_cohort) or not re.fullmatch(r'round[1-9][0-9]*',a.stage):raise ProbeError('cli_progress_invalid_cohort_or_stage')
    assets=absolute(a.assets_dir);script=safe_member_name(a.script);private=ROOT/'private'/('p1-'+a.stage)/('cli-progress-'+a.source_cohort)
    if assets==private or assets in private.parents or private in assets.parents:raise ProbeError('cli_progress_input_output_overlap')
    private.mkdir(parents=True,exist_ok=True)
    compiled_sources=[ROOT/'native/Package.swift',*sorted((ROOT/'native/Sources').rglob('*.swift'))]
    sources={s.relative_to(ROOT).as_posix():sha(read_bounded(s)) for s in compiled_sources}
    compiled=subprocess.run(['swift','build','--package-path',str(ROOT/'native'),'-c','release','--product','mangekyou-script'],capture_output=True,timeout=120,cwd=ROOT)
    (private/'build.log').write_bytes(compiled.stdout+compiled.stderr)
    if compiled.returncode:raise ProbeError('cli_progress_build_failed')
    binary=(ROOT/'native/.build/release/mangekyou-script').resolve();raw=read_bounded(binary)
    if ROOT/'native/.build' not in binary.parents or raw[:4]!=b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I',raw,4)[0]!=0x0100000c:raise ProbeError('cli_progress_binary_not_owned_arm64')
    binary_sha=sha(raw);manifest=ROOT/'reports/p1/corpus-report.json';manifest_bytes=read_bounded(manifest)
    items=json.loads(manifest_bytes)['items'];index={i['source_file']:i for i in items}
    if not 1<=len(items)<=2000 or len(index)!=len(items) or script not in index:raise ProbeError('cli_progress_catalog_identity')
    image_sources=set();movie_source=None;recipe_path=None
    extra_entries=[];recipes=[]
    def add_image(name,suffix):
        name=safe_member_name(name)
        if not re.fullmatch(r'data[0-9]+\.pack/.+',name) or not name.endswith(suffix) or name in index:
            raise ProbeError('cli_image_source_identity')
        content=read_bounded(assets/name,16*1024*1024)
        entry=dict(source_file=name,logical_path=name.split('/',1)[1],sha256=sha(content))
        index[name]=entry;extra_entries.append(entry);image_sources.add(name)
        return content
    if len(a.image_source)!=len(a.image_audit) or len(a.image_source)+len(a.plain_image_source)>128:
        raise ProbeError('cli_image_source_and_audit_required')
    for name in a.plain_image_source:
        add_image(name,'.png')
    for name,audit_path in zip(a.image_source,a.image_audit):
        content=add_image(name,'.b');root_sha=sha(content)
        audit=json.loads(read_bounded(absolute(audit_path),1024*1024))
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
                elif member.get('format') in {'PNG','JPEG'} and member.get('content_decode_status')=='verified':
                    recipes.append(dict(container_sha256=root_sha,offset=start,length=length,sha256=ref['sha256'],name=member['name']))
                    if len(recipes)>128:raise ProbeError('cli_image_recipe_limit')
        before=len(recipes);collect(audit,0,len(content),root_sha,0)
        if len(recipes)==before:raise ProbeError('cli_image_members_missing')
        metadata=[m for m in audit['members'] if m.get('name')=='data_000.bin']
        if len(metadata)==1 and (metadata[0].get('extended_key_markers_absent') is True
            or 'extended_scalar_values' in metadata[0] or 'motion_name_candidates' in metadata[0]):
            ref=metadata[0]['raw_bytes_reference'];start=ref['offset'];length=ref['length']
            if (ref['container_sha256']!=root_sha or not 0<=start<start+length<=len(content)
                or sha(content[start:start+length])!=ref['sha256']):
                raise ProbeError('cli_image_metadata_identity')
            if metadata[0].get('extended_key_markers_absent') is True or 'extended_scalar_values' in metadata[0]:
                recipes[before]['extended_scalar_values']=metadata[0].get('extended_scalar_values',{})
            if 'motion_name_candidates' in metadata[0]:
                recipes[before]['motion_name_candidates']=metadata[0]['motion_name_candidates']

    if recipes:
        recipe_path=private/'image-recipe.json'
        write_json(recipe_path,recipes)
    if a.movie_source:
        movie_source=safe_member_name(a.movie_source)
        if not re.fullmatch(r'data[0-9]+\.pack/.+\.ogv',movie_source) or movie_source in index:
            raise ProbeError('cli_movie_source_identity')
        content=read_bounded(assets/movie_source,16*1024*1024)
        entry=dict(source_file=movie_source,logical_path=movie_source.split('/',1)[1],sha256=sha(content))
        index[movie_source]=entry
        extra_entries.append(entry)
    if len(a.audio_source)>128:raise ProbeError('cli_audio_source_limit')
    audio_sources=[]
    for raw_source in a.audio_source:
        audio_source=safe_member_name(raw_source)
        if not re.fullmatch(r'data[0-9]+\.pack/.+\.ogg',audio_source) or audio_source in index:
            raise ProbeError('cli_audio_source_identity')
        content=read_bounded(assets/audio_source,16*1024*1024)
        entry=dict(source_file=audio_source,logical_path=audio_source.split('/',1)[1],sha256=sha(content))
        audio_sources.append(audio_source)
        index[audio_source]=entry
        extra_entries.append(entry)
    if len(a.wave_source)>16:raise ProbeError('cli_wave_source_limit')
    for name in a.wave_source:
        add_image(name,'.wav')
    index_sha=None
    resource_names=None
    if a.resource_index:
        raw_index=read_bounded(absolute(a.resource_index),8*1024*1024)
        index_sha=sha(raw_index);archive_report=json.loads(raw_index)
        archives={r['path']:r for r in archive_report['items']}
        resource_names=[]
        for number in range(9):
            archive=archives[f'GameData/data{number}.pack']
            rows=archive['index']['entries']
            if archive['index_status']!='verified' or len(rows)!=archive['declared_entry_count']:
                raise ProbeError('cli_resource_index_incomplete')
            resource_names.extend(safe_member_name(r['name'].replace(chr(92),'/')) for r in rows)
    if extra_entries or resource_names is not None:
        manifest=private/'combined-catalog.json'
        write_json(manifest,dict(items=[*items,*extra_entries],indexedResourceNames=resource_names))
        manifest_bytes=read_bounded(manifest)
    cache={};total=0
    def lookup(name):
        nonlocal total
        name=safe_member_name(name)
        if name not in index:raise ProbeError('cli_progress_source_not_in_catalog')
        if name not in cache:
            data=read_bounded(assets/name,16*1024*1024);total+=len(data)
            if total>128*1024*1024 or sha(data)!=index[name]['sha256']:raise ProbeError('cli_progress_source_identity_or_budget')
            if name in image_sources or name == movie_source or name in audio_sources:document={'records':[]}
            else:_,document=fingerprints(data,name)
            cache[name]=(data,document)
        return cache[name]
    config_path=absolute(a.game_dir)/"GameData/System/config.txt" if a.game_dir else None
    config_sha=sha(read_bounded(config_path,1024*1024)) if config_path else None
    root,root_doc=lookup(script);selected=[];attempts=[];final=None
    seed_sha=None
    if a.selection_seed:
        seed_bytes=read_bounded(absolute(a.selection_seed),4*1024*1024)
        seed_sha=sha(seed_bytes);seed=json.loads(seed_bytes)
        if seed.get('source_cohort')!=a.source_cohort:
            raise ProbeError('cli_progress_seed_cohort_mismatch')
        for choice in seed.get('selected_sources',[]):
            source=choice['source_file']
            if (len(selected)>=128 or source in selected or not source.startswith(a.source_cohort+'.pack/')
                or source not in index or choice['sha256']!=index[source]['sha256']):
                raise ProbeError('cli_progress_seed_identity_or_budget')
            lookup(source);selected.append(source)
    for attempt in range(129-len(selected)):
        command=[str(binary),'--assets-dir',str(assets),'--script',script,'--experimental-run','--maximum-steps',str(a.maximum_steps),'--catalog',str(manifest)]
        if not (a.full_trace or a.publish_summary):command.append("--compact-trace")
        if a.game_dir:command+=['--game-dir',str(absolute(a.game_dir))]
        if a.headless_movie_tools:command+=['--headless-movie-tools',str(absolute(a.headless_movie_tools))]
        if a.button_index is not None:command+=['--button-index',str(a.button_index)]
        if a.pointer is not None:command+=['--pointer',a.pointer]
        if a.dispatch_stop_callback:command+=['--dispatch-stop-callback']
        if a.message_click:command+=['--message-click']
        if a.message_clicks:command+=['--message-clicks',str(a.message_clicks)]
        if a.click_ticks is not None:command+=['--click-ticks',str(a.click_ticks)]
        if recipe_path:command+=['--image-recipe',str(recipe_path)]
        for source in selected:command+=['--select-source',source]
        run=subprocess.run(command,capture_output=True,timeout=150,cwd=ROOT)
        (private/f'attempt-{attempt:02}-stderr.log').write_bytes(run.stderr)
        if run.returncode not in {0,2} or len(run.stdout)>512*1024*1024:raise ProbeError(f'cli_progress_process_failure: exit={run.returncode}, output_bytes={len(run.stdout)}')
        document=json.loads(run.stdout);write_json(private/f'attempt-{attempt:02}.json',document)
        record=document['reports'][0];machine=record.get('machine')
        if not machine:raise ProbeError('cli_progress_program_preparation_failed')
        with processing_deadline(120):references=validate_trace(machine,root,script,root_doc,source_lookup=lookup,allow_trace_suffix=not (a.full_trace or a.publish_summary))
        row=dict(attempt=attempt,steps=machine['steps'],phase=machine['phase'],stop_reason=machine.get('stopReason'),
            location=machine.get('currentLocation'),source_byte_references=references)
        attempts.append(row);final=machine
        if machine.get('stopReason')!='ambiguous_module_variants':break
        candidates=record.get('moduleCandidates') or []
        choices=[r for r in candidates if r['source_file'].startswith(a.source_cohort+'.pack/')]
        if len(choices)!=1:raise ProbeError('cli_progress_cohort_does_not_select_one_candidate')
        choice=choices[0];source=choice['source_file']
        if source in selected or source not in index or choice['sha256']!=index[source]['sha256']:raise ProbeError('cli_progress_candidate_identity_or_cycle')
        lookup(source)
        selected.append(source);row['explicit_selection']=dict(source_file=source,sha256=choice['sha256'])
    else:raise ProbeError('cli_progress_selection_limit')
    if sha(read_bounded(binary))!=binary_sha or any(sha(read_bounded(ROOT/n))!=h for n,h in sources.items()):raise ProbeError('cli_progress_sources_changed')
    if config_path and sha(read_bounded(config_path,1024*1024))!=config_sha:raise ProbeError('cli_progress_config_changed')
    report=dict(message_click=a.message_click,message_clicks=a.message_clicks,audio_resource=index.get(audio_sources[-1]) if audio_sources else None,audio_resources=[index[name] for name in audio_sources],headless_movie_decode=bool(a.headless_movie_tools),movie_resource=index.get(movie_source),supplied_click_tick_budget=a.click_ticks,maximum_steps=a.maximum_steps,dispatch_stop_callback=a.dispatch_stop_callback,pointer_sample=a.pointer,button_index=a.button_index,wave_resources=[index[name] for name in sorted(image_sources) if name.endswith(".wav")],image_resources=[index[name] for name in sorted(image_sources) if not name.endswith(".wav")],configuration_source=dict(source_file='GameData/System/config.txt',sha256=config_sha) if config_sha else None,schema_version=1,status='inferred',dataset='real',scope='One explicit source-cohort CLI path; no original package winner or complete-game claim',
        profile=final['profile'],source_cohort=a.source_cohort,source_choice_is_original_precedence='not_tested',
        native_binary_sha256=binary_sha,native_source_sha256=sources,corpus_report_sha256=sha(manifest_bytes),
        selection_seed_sha256=seed_sha,resource_index_sha256=index_sha,attempts=attempts,selected_sources=[dict(source_file=s,sha256=index[s]['sha256']) for s in selected],
        phase=final['phase'],steps=final['steps'],stop_reason=final.get('stopReason'),location=final.get('currentLocation'),
        terminal_command=final['trace'][-1].get('command') if final['trace'] else None,
        source_snapshot_count=final.get('sourceSnapshotCount'),loaded_programs=final.get('moduleSnapshotCount'),
        action_counts=dict(Counter(r['action'] for r in final['trace'])),trace_sha256=sha(json.dumps(final,sort_keys=True).encode()),
        source_byte_reference_status='verified',checked_sources=len(cache),checked_source_bytes=total,
        full_corpus_retested=False,original_engine_equivalence='not_tested',full_game_compatibility='not_tested',
        original_files_written=False,external_game_data_uploads=False,private_trace_directory=private.relative_to(ROOT).as_posix())
    report_path = ROOT/'reports/p1'/('cli-progress-'+a.stage+'-'+a.source_cohort+'.json') if a.publish_summary else private/'summary.json'
    if len(final['trace']) != final['steps']:
        report['trace_scope']='suffix'
        report['trace_first_step']=final['trace'][0]['sequence']
        report['trace_action_counts']=report.pop('action_counts')
    write_json(report_path,report)
    print(json.dumps(dict(steps=final['steps'],stop=final.get('stopReason'),selected_sources=len(selected),checked_sources=len(cache))))
    return 0


if __name__=='__main__':raise SystemExit(main())
