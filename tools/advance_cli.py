#!/usr/bin/env python3
"""Run the native CLI to its next real stop, with an explicit experimental source cohort."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
from verify_native_scripts import fingerprints, validate_trace
from control_state_analysis import processing_deadline
from image_recipe import append_image_recipe


def sha(data):return hashlib.sha256(data).hexdigest()


def append_explicit_sources(requested, selected, cohort, index, lookup, allow_cross_cohort=False):
    for raw in requested:
        source = safe_member_name(raw)
        cohort_match = source.startswith(cohort + '.pack/')
        package_match = re.match(r'data[0-8]\.pack/', source) is not None
        if (len(selected) >= 128 or source in selected or not (cohort_match or (allow_cross_cohort and package_match))
            or not source.lower().endswith(('.s', '.txt')) or source not in index):
            raise ProbeError('cli_progress_selection_identity_or_budget')
        lookup(source)
        selected.append(source)


def resource_index_preflight(archive_report):
    archives = {row['path']: row for row in archive_report['items']}
    names = []
    candidates = defaultdict(list)
    extensions = Counter()
    ascii_lower = str.maketrans('ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz')
    for number in range(9):
        path = f'GameData/data{number}.pack'
        archive = archives.get(path)
        if not archive or archive.get('index_status') != 'verified':
            raise ProbeError('cli_resource_index_unverified:' + path)
        rows = archive['index']['entries']
        if len(rows) != archive['declared_entry_count']:
            raise ProbeError('cli_resource_index_incomplete:' + path)
        for row in rows:
            name = safe_member_name(row['name'].replace(chr(92), '/'))
            key = name.translate(ascii_lower)
            names.append(name)
            candidates[key].append(dict(archive=path, name=name))
            extensions[Path(key).suffix or '(none)'] += 1
    if not 1 <= len(names) <= 50_000:
        raise ProbeError('cli_resource_index_count_limit')
    return names, dict(
        status='verified', scope='Archive index metadata only',
        member_count=len(names), logical_name_count=len(candidates),
        extension_counts=dict(extensions),
        ambiguous_names={key: rows for key, rows in candidates.items() if len(rows) > 1},
        payload_read_status='not_tested', decode_status='not_tested',
        archive_precedence_status='not_tested',
    )


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',required=True,type=Path);p.add_argument('--script',default='data0.pack/startup.s')
    p.add_argument('--source-cohort',required=True,help='Explicit experiment, e.g. data8; not original package precedence')
    p.add_argument('--game-dir',type=Path)
    p.add_argument('--maximum-steps',type=int,default=10_000)
    p.add_argument('--click-ticks',type=int)
    p.add_argument('--dispatch-stop-callback',action='store_true')
    p.add_argument('--message-click',action='store_true')
    p.add_argument('--message-clicks',type=int,choices=range(1,48001))
    p.add_argument('--button-index',type=int)
    p.add_argument('--story-choice',type=int,choices=range(6),action='append',default=[])
    p.add_argument('--verify-route-return',action='store_true',
                   help='Open and cancel the title load menu, then require every supplied choice and a return to title')
    p.add_argument('--verify-story-route',action='store_true',
                   help='Start from the title and require every supplied story choice and a return to title')
    p.add_argument('--research-label-read-status',action='store_true',
                   help='Use the explicitly inferred label-read candidate in a fresh read-only replay')
    p.add_argument('--title-menu-target',choices=('album','memory','sound'),
                   help='After the verified route returns to title, try the named extra menu')
    p.add_argument('--load-task-capture',type=Path)
    p.add_argument('--save-dir',type=Path,help='Read-only save directory for load-menu or private system-data research')
    p.add_argument('--research-system-file',help='Private system-data filename inside --save-dir')
    p.add_argument('--research-system-exe',help='Executable filename relative to --game-dir for the verified system header template')
    p.add_argument('--research-system-output',help='New private system-data output filename in this report directory')
    p.add_argument('--load-task-page',type=int,action='append',default=[])
    p.add_argument('--scene-preview-background',help='Local resource path for strict final-frame compositing')
    p.add_argument('--replay-dir',type=Path,help='Reuse a private combined catalog, image recipe and resource receipts')
    p.add_argument('--pointer',help='Explicit input sample X,Y for the stop callback')
    p.add_argument('--movie-source')
    p.add_argument('--large-movie-source', help='One pinned local Ogg movie up to 192 MiB')
    p.add_argument('--audio-source',action='append',default=[])
    p.add_argument('--wave-source',action='append',default=[])
    p.add_argument('--headless-movie-tools',type=Path)
    p.add_argument('--image-source',action='append',default=[])
    p.add_argument('--image-audit',type=Path,action='append',default=[])
    p.add_argument('--plain-image-source',action='append',default=[])
    p.add_argument('--resource-provider',type=Path,help='Explicit local single-resource supplier')
    p.add_argument('--resource-index',type=Path)
    p.add_argument('--resource-cache',type=Path,help='Reuse local provider receipts with runtime digest checks')
    p.add_argument('--selection-seed',type=Path,help='Reuse pinned choices from a previous same-cohort report')
    p.add_argument('--select-source',action='append',default=[],
                   help='Explicitly pin a catalogued source in the selected cohort; may be repeated')
    p.add_argument('--source-override',action='append',default=[],
                   help='Explicitly pin a catalogued data0-data8 script/table outside the cohort for a private hypothesis run')
    report_mode=p.add_mutually_exclusive_group()
    report_mode.add_argument('--private-report',action='store_true',help='Keep the summary alongside the private trace (default)')
    report_mode.add_argument('--publish-summary',action='store_true',help='Write a reviewed milestone summary under reports/p1')
    p.add_argument('--full-trace',action='store_true',help='Retain and validate every execution record')
    p.add_argument('--source-visits',action='store_true',help='Record bounded source-entry metadata in private output')
    p.add_argument('--source-coverage',help='Record executed command and label locations for one pinned source in private output')
    p.add_argument('--stage',default='round29');a=p.parse_args()
    if a.scene_preview_background and a.publish_summary:
        p.error('--scene-preview-background requires private output')
    if a.source_visits and a.publish_summary:
        p.error('--source-visits requires private output')
    if a.source_coverage and a.publish_summary:
        p.error('--source-coverage requires private output')
    coverage_source = safe_member_name(a.source_coverage) if a.source_coverage else None
    scene_background = safe_member_name(a.scene_preview_background) if a.scene_preview_background else None
    research_system_file = safe_member_name(a.research_system_file) if a.research_system_file else None
    research_system_exe = safe_member_name(a.research_system_exe) if a.research_system_exe else None
    research_system_output = safe_member_name(a.research_system_output) if a.research_system_output else None
    if bool(research_system_file) != bool(research_system_exe):
        p.error('--research-system-file and --research-system-exe must be supplied together')
    if research_system_file and (len(research_system_file.split('/')) != 1 or not a.save_dir or not a.game_dir or
                                 not (a.verify_route_return or a.verify_story_route) or a.publish_summary):
        p.error('--research-system-file requires a private strict route replay, --save-dir and --game-dir')
    if research_system_output and (not research_system_file or len(research_system_output.split('/')) != 1 or a.publish_summary):
        p.error('--research-system-output requires a private system-data input and a leaf filename')
    if a.verify_route_return:
        if not a.load_task_capture or not a.story_choice or a.publish_summary:
            p.error('--verify-route-return requires a local capture, story choices and private output')
    elif a.load_task_capture or a.load_task_page or (a.save_dir and not research_system_file):
        p.error('title load-task options require --verify-route-return')
    if a.verify_story_route and (not a.story_choice or a.verify_route_return or a.publish_summary):
        p.error('--verify-story-route requires story choices, private output and no load-task verification')
    if a.source_override and (not (a.verify_story_route or a.verify_route_return) or a.publish_summary):
        p.error('--source-override requires a private strict route replay')
    if a.title_menu_target and not a.verify_route_return:
        p.error('--title-menu-target requires --verify-route-return')
    if a.research_label_read_status and (not (a.verify_route_return or a.verify_story_route) or
                                         (a.save_dir and not research_system_file) or a.publish_summary):
        p.error('--research-label-read-status requires a fresh private read-only route replay')
    if a.replay_dir and any((a.resource_index, a.image_source, a.image_audit,
                             a.plain_image_source, a.audio_source, a.wave_source, a.movie_source,
                             a.large_movie_source, a.resource_provider, a.resource_cache)):
        p.error('--replay-dir cannot be combined with options that build or supply resources')
    if not re.fullmatch(r'data(?:[0-9]|[12][0-9]|3[01])',a.source_cohort) or not re.fullmatch(r'round[1-9][0-9]*',a.stage):raise ProbeError('cli_progress_invalid_cohort_or_stage')
    assets=absolute(a.assets_dir);script=safe_member_name(a.script);private=ROOT/'private'/('p1-'+a.stage)/('cli-progress-'+a.source_cohort)
    if assets==private or assets in private.parents or private in assets.parents:raise ProbeError('cli_progress_input_output_overlap')
    save_directory = absolute(a.save_dir) if a.save_dir else None
    if save_directory and (save_directory == private or save_directory in private.parents or private in save_directory.parents):
        raise ProbeError('cli_progress_save_output_overlap')
    research_system_input_path = save_directory / research_system_file if research_system_file and save_directory else None
    research_system_exe_path = absolute(a.game_dir) / research_system_exe if research_system_exe and a.game_dir else None
    if research_system_input_path:
        if research_system_input_path.is_symlink():
            raise ProbeError('cli_research_system_input_symlink')
        system_input_sha = sha(read_bounded(research_system_input_path,16*1024*1024))
    else:
        system_input_sha = None
    if research_system_exe_path:
        if research_system_exe_path.is_symlink():
            raise ProbeError('cli_research_system_exe_symlink')
        system_exe_sha = sha(read_bounded(research_system_exe_path,64*1024*1024))
    else:
        system_exe_sha = None
    try:
        private.mkdir(parents=True, exist_ok=not (a.verify_route_return or a.verify_story_route))
    except FileExistsError:
        p.error('route_replay_stage_already_exists: choose a new --stage')
    research_system_output_path = private / research_system_output if research_system_output else None
    if research_system_output_path and (research_system_output_path.exists() or research_system_output_path.is_symlink()):
        raise ProbeError('cli_research_system_output_exists')
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
        content=read_bounded(assets/name,(32 if name.endswith(".b") else 16)*1024*1024)
        entry=dict(source_file=name,logical_path=name.split('/',1)[1],sha256=sha(content))
        index[name]=entry;extra_entries.append(entry);image_sources.add(name)
        return content
    if len(a.image_source)!=len(a.image_audit) or len(a.image_source)+len(a.plain_image_source)>128:
        raise ProbeError('cli_image_source_and_audit_required')
    for name in a.plain_image_source:
        add_image(name,'.png')
    for name,audit_path in zip(a.image_source,a.image_audit):
        content=add_image(name,'.b')
        audit=json.loads(read_bounded(absolute(audit_path),1024*1024))
        append_image_recipe(recipes, content, audit)

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
    large_movie_source = safe_member_name(a.large_movie_source) if a.large_movie_source else None
    if large_movie_source:
        if not re.fullmatch(r'data[0-8]\.pack/.+\.ogv', large_movie_source) or large_movie_source in index:
            raise ProbeError('cli_large_movie_source_identity')
        content = read_bounded(assets/large_movie_source, 192*1024*1024)
        if not content.startswith(b'OggS'):
            raise ProbeError('cli_large_movie_source_signature')
        entry = dict(source_file=large_movie_source, logical_path=large_movie_source.split('/',1)[1], sha256=sha(content))
        index[large_movie_source] = entry
        extra_entries.append(entry)
        del content
    trace_byte_limit = (128 + (192 if large_movie_source else 0))*1024*1024
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
        index_sha=sha(raw_index)
        resource_names, preflight = resource_index_preflight(json.loads(raw_index))
        write_json(private/'resource-preflight.json', dict(index_sha256=index_sha, **preflight))
    if extra_entries or resource_names is not None:
        manifest=private/'combined-catalog.json'
        write_json(manifest,dict(items=[*items,*extra_entries],indexedResourceNames=resource_names))
        manifest_bytes=read_bounded(manifest)
    receipts = None
    if a.replay_dir:
        replay = absolute(a.replay_dir)
        manifest = replay / 'combined-catalog.json'
        manifest_bytes = read_bounded(manifest, 32*1024*1024)
        recipe_path = replay / 'image-recipe.json'
        receipts = replay / 'summary.json'
        pinned = json.loads(read_bounded(receipts, 8*1024*1024))
        if pinned.get('source_cohort') != a.source_cohort:
            raise ProbeError('cli_progress_seed_cohort_mismatch')
        items = json.loads(manifest_bytes)['items']
        index = {entry['source_file']: entry for entry in items}
        if len(index) != len(items) or not 1 <= len(items) <= 2000 or script not in index:
            raise ProbeError('cli_progress_catalog_identity')
        for field, destination in (('image_resources', image_sources), ('audio_resources', audio_sources), ('wave_resources', image_sources)):
            for entry in pinned.get(field, []):
                name = safe_member_name(entry['source_file'])
                if name in index and index[name]['sha256'] != entry['sha256']:
                    raise ProbeError('cli_resource_receipt_identity')
                index[name] = entry
                if field != 'audio_resources':
                    destination.add(name)
                else:
                    destination.append(name)
        # A replay receipt may pin standalone movies separately from image
        # resources. Reattach those same source files when reusing its catalog.
        for field, target in (('movie_resource', 'movie'), ('large_movie_resource', 'large_movie')):
            entry = pinned.get(field)
            if not entry:
                continue
            name = safe_member_name(entry['source_file'])
            if (not re.fullmatch(r'data[0-9]+\.pack/.+\.ogv', name)
                or entry.get('logical_path') != name.split('/', 1)[1]
                or not re.fullmatch(r'[a-f0-9]{64}', entry.get('sha256', ''))):
                raise ProbeError('cli_movie_receipt_identity')
            if name in index and index[name]['sha256'] != entry['sha256']:
                raise ProbeError('cli_resource_receipt_identity')
            index[name] = entry
            if target == 'movie':
                movie_source = name
            else:
                large_movie_source = name
        if large_movie_source:
            trace_byte_limit = max(trace_byte_limit, (128 + 192) * 1024 * 1024)
    cache={};total=0
    if coverage_source and coverage_source not in index:
        raise ProbeError('cli_source_coverage_not_in_catalog')
    def lookup(name):
        nonlocal total
        name=safe_member_name(name)
        if name not in index:raise ProbeError('cli_progress_source_not_in_catalog')
        if name not in cache:
            limit = 192 if name == large_movie_source else (32 if name.endswith(".b") else 16)
            data=read_bounded(assets/name,limit*1024*1024);total+=len(data)
            if total>trace_byte_limit:raise ProbeError('cli_progress_trace_cache_byte_limit')
            if sha(data)!=index[name]['sha256']:raise ProbeError('cli_progress_trace_copy_identity')
            is_wave = name.lower().endswith('.wav') and data[:4] == b'RIFF' and data[8:12] == b'WAVE'
            if name in image_sources or name in (movie_source,large_movie_source) or name in audio_sources or is_wave:document={'records':[]}
            else:_,document=fingerprints(data,name)
            cache[name]=(data,document)
        return cache[name]
    config_path=absolute(a.game_dir)/"GameData/System/config.txt" if a.game_dir else None
    config_sha=sha(read_bounded(config_path,1024*1024)) if config_path else None
    root,root_doc=lookup(script);selected=[];attempts=[];final=None
    seed_sha=None
    if a.selection_seed or receipts:
        seed_bytes=read_bounded(absolute(a.selection_seed) if a.selection_seed else receipts,8*1024*1024)
        seed_sha=sha(seed_bytes);seed=json.loads(seed_bytes)
        if seed.get('source_cohort')!=a.source_cohort:
            raise ProbeError('cli_progress_seed_cohort_mismatch')
        for choice in seed.get('selected_sources',[]):
            source=choice['source_file']
            if (len(selected)>=128 or source in selected or not source.startswith(a.source_cohort+'.pack/')
                or source not in index or choice['sha256']!=index[source]['sha256']):
                raise ProbeError('cli_progress_seed_identity_or_budget')
            lookup(source);selected.append(source)
    append_explicit_sources(a.select_source,selected,a.source_cohort,index,lookup)
    explicit_source_overrides = list(a.source_override)
    append_explicit_sources(a.source_override,selected,a.source_cohort,index,lookup,allow_cross_cohort=True)
    for attempt in range(129-len(selected)):
        command=[str(binary),'--assets-dir',str(assets),'--script',script,'--experimental-run','--maximum-steps',str(a.maximum_steps),'--catalog',str(manifest)]
        if not (a.full_trace or a.publish_summary):command.append("--compact-trace")
        if a.source_visits:command.append('--source-visits')
        if a.research_label_read_status:command.append('--research-label-read-status')
        if coverage_source:command += ['--source-coverage',coverage_source]
        if a.resource_cache:command += ["--resource-cache",str(absolute(a.resource_cache))]
        if a.resource_provider:command += ["--resource-provider",str(absolute(a.resource_provider))]
        if a.game_dir:command+=['--game-dir',str(absolute(a.game_dir))]
        if a.headless_movie_tools:command+=['--headless-movie-tools',str(absolute(a.headless_movie_tools))]
        for choice in a.story_choice:command+=['--story-choice',str(choice)]
        if scene_background:
            command += ['--scene-preview-background', scene_background, '--require-complete-scene-preview']
        if a.verify_route_return:
            command += ['--inspect-load-task','--open-title-load','--load-task-escape',
                        '--start-after-load-escape','--require-route-return','--load-task-ticks','3000',
                        '--load-task-capture',str(absolute(a.load_task_capture))]
            for page in a.load_task_page:
                command += ['--load-task-page',str(page)]
            if a.title_menu_target:
                command += ['--title-menu-target', a.title_menu_target]
        elif a.verify_story_route:
            command += ['--start-from-title','--require-route-return']
        if save_directory:
            command += ['--save-dir', str(save_directory)]
        if research_system_file:
            command += ['--research-system-file',research_system_file,
                        '--research-system-exe',research_system_exe]
        if research_system_output:
            output_relative = f"{private.relative_to(ROOT/'private').as_posix()}/{research_system_output}"
            command += ['--research-system-output',output_relative]
        if a.button_index is not None:command+=['--button-index',str(a.button_index)]
        if a.pointer is not None:command+=['--pointer',a.pointer]
        if a.dispatch_stop_callback:command+=['--dispatch-stop-callback']
        if a.message_click:command+=['--message-click']
        if a.message_clicks:command+=['--message-clicks',str(a.message_clicks)]
        if a.click_ticks is not None:command+=['--click-ticks',str(a.click_ticks)]
        if recipe_path:command+=['--image-recipe',str(recipe_path)]
        if receipts:command+=['--resource-receipts',str(receipts)]
        for source in selected:command+=['--select-source',source]
        stderr_path = private/f'attempt-{attempt:02}-stderr.log'
        with stderr_path.open('wb') as stderr:
            run=subprocess.run(command,stdout=subprocess.PIPE,stderr=stderr,
                               timeout=3600 if a.resource_provider or a.verify_route_return or a.verify_story_route else 150,cwd=ROOT)
        if run.returncode not in {0,2} or len(run.stdout)>512*1024*1024:raise ProbeError(f'cli_progress_process_failure: exit={run.returncode}, output_bytes={len(run.stdout)}')
        if not run.stdout:
            raise ProbeError(f'cli_progress_missing_json: exit={run.returncode}, see {stderr_path}')
        document=json.loads(run.stdout);write_json(private/f'attempt-{attempt:02}.json',document)
        receipt_bytes = 0
        decoded_movies = []
        for line in read_bounded(stderr_path, 32*1024*1024).splitlines():
            if a.verify_route_return or a.verify_story_route:
                movie = re.fullmatch(rb'decoded_movie=([0-9a-f]{64}) ticks=([0-9]{1,6})', line)
                if movie:
                    decoded_movies.append(dict(sha256=movie[1].decode('ascii'), duration_ticks=int(movie[2])))
            if not line.startswith(b'supplied_resource='):continue
            if not a.resource_provider or len(line)>16*1024:raise ProbeError('cli_resource_receipt_invalid')
            entry=json.loads(line.split(b'=',1)[1])
            name=safe_member_name(entry['source_file'])
            if (not re.fullmatch(r'data[0-8]\.pack/.+\.(png|ogg|ogv)',name)
                or entry['logical_path']!=name.split('/',1)[1] or name in index and index[name]!=entry):
                raise ProbeError('cli_resource_receipt_identity')
            index[name]=entry
            if name.endswith('.ogg'):
                if name not in audio_sources:audio_sources.append(name)
            else:image_sources.add(name)
            content = read_bounded(assets/name, 16*1024*1024)
            receipt_bytes += len(content)
            if receipt_bytes > 4*1024*1024*1024:
                raise ProbeError('cli_resource_receipt_byte_limit')
            if sha(content) != entry['sha256']:
                raise ProbeError('cli_resource_receipt_copy_identity')
        record=document['reports'][0];machine=record.get('machine')
        if not machine:raise ProbeError('cli_progress_program_preparation_failed')
        with processing_deadline(120):references=validate_trace(machine,root,script,root_doc,source_lookup=lookup,allow_trace_suffix=not (a.full_trace or a.publish_summary),source_byte_limit=trace_byte_limit)
        row=dict(attempt=attempt,steps=machine['steps'],phase=machine['phase'],stop_reason=machine.get('stopReason'),
            location=machine.get('currentLocation'),replay_budget=record.get('replayBudget'),source_byte_references=references)
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
    if research_system_input_path and sha(read_bounded(research_system_input_path,16*1024*1024))!=system_input_sha:
        raise ProbeError('cli_research_system_input_changed')
    if research_system_exe_path and sha(read_bounded(research_system_exe_path,64*1024*1024))!=system_exe_sha:
        raise ProbeError('cli_research_system_exe_changed')
    system_output_receipt = None
    if research_system_output_path:
        if research_system_output_path.is_file() and not research_system_output_path.is_symlink():
            system_output_bytes = read_bounded(research_system_output_path,16*1024*1024)
            system_output_receipt = dict(status='inferred',path=research_system_output_path.relative_to(ROOT).as_posix(),
                sha256=sha(system_output_bytes),byte_length=len(system_output_bytes),values='not_published')
        else:
            system_output_receipt = dict(status='unsupported',path=research_system_output_path.relative_to(ROOT).as_posix(),
                issue='research_system_output_not_written')
    report=dict(large_movie_resource=index.get(large_movie_source),story_choices=a.story_choice,message_click=a.message_click,message_clicks=a.message_clicks,audio_resource=index.get(audio_sources[-1]) if audio_sources else None,audio_resources=[index[name] for name in audio_sources],headless_movie_decode=bool(a.headless_movie_tools),movie_resource=index.get(movie_source),supplied_click_tick_budget=a.click_ticks,maximum_steps=a.maximum_steps,dispatch_stop_callback=a.dispatch_stop_callback,pointer_sample=a.pointer,button_index=a.button_index,wave_resources=[index[name] for name in sorted(image_sources) if name.endswith(".wav")],image_resources=[index[name] for name in sorted(image_sources) if not name.endswith(".wav")],configuration_source=dict(source_file='GameData/System/config.txt',sha256=config_sha) if config_sha else None,schema_version=1,status='inferred',dataset='real',scope='One explicit source-cohort CLI path; no original package winner or complete-game claim',
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
    if research_system_input_path:
        report['research_system_input'] = dict(source_file=research_system_file,sha256=system_input_sha,
            executable=research_system_exe,executable_sha256=system_exe_sha,values='not_published')
    if system_output_receipt:
        report['research_system_output'] = system_output_receipt
    if a.research_label_read_status:
        report['label_read_status_candidate']='inferred'
    if explicit_source_overrides:
        report['explicit_source_overrides'] = [dict(source_file=s,sha256=index[s]['sha256']) for s in explicit_source_overrides]
    report_path = ROOT/'reports/p1'/('cli-progress-'+a.stage+'-'+a.source_cohort+'.json') if a.publish_summary else private/'summary.json'
    if len(final['trace']) != final['steps']:
        report['trace_scope']='suffix'
        report['trace_first_step']=final['trace'][0]['sequence']
        report['trace_action_counts']=report.pop('action_counts')
    if a.verify_route_return or a.verify_story_route:
        budget = record.get('replayBudget') or {}
        returned = (budget.get('routeTitleReachedBeforeMenu') is True and
                    budget.get('remainingStoryChoices') == 0) if a.title_menu_target else run.returncode == 0
        report['route_return_status']='verified' if returned else 'unsupported'
        report['route_return_issue']=None if returned else record.get('issue')
        report['route_return_replay_budget']=record.get('replayBudget')
        report['route_decoded_movies']=decoded_movies
        if a.title_menu_target:
            report['title_menu_target'] = a.title_menu_target
            report['title_menu_status'] = 'inferred' if run.returncode == 0 and len(budget.get('titleMenuActions', [])) == 2 else 'unsupported'
            report['title_menu_issue'] = record.get('issue')
    if scene_background:
        preview = record.get('scenePreview')
        report['scene_preview_status'] = (
            'inferred' if preview and not preview['omittedLayers'] and not preview['textPreviewIssues']
            else 'unsupported'
        )
        if report['scene_preview_status'] == 'unsupported':
            report['scene_preview_issue'] = record.get('scenePreviewIssue') or 'scene_preview_incomplete'
    write_json(report_path,report)
    print(json.dumps(dict(steps=final['steps'],stop=final.get('stopReason'),selected_sources=len(selected),checked_sources=len(cache))))
    return run.returncode if a.verify_route_return or a.verify_story_route or scene_background else 0


if __name__=='__main__':raise SystemExit(main())
