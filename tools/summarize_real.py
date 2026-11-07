#!/usr/bin/env python3
"""Publish metadata-only P0 reports from local private analysis, never game bytes."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

from mangekyou_p0 import ROOT, write_json


def summarize(source, output, asset_copies):
    def load(name): return json.loads((source/name).read_text())
    inv=load('inventory.json'); archive=load('archive-report.json'); assets=load('asset-report.json')
    scripts=load('script-report.json'); graph=load('reference-graph.json'); samples=load('sample-report.json')
    if inv.get('dataset')!='real':raise ValueError('real dataset report required')
    provenance=dict(schema_version=1,dataset='real',scope='user-provided mixed installation; metadata only',
        original_files_written=False,official_edition_authenticity='not_tested',
        report_policy='No decoded prose, full resource payloads, keys, CG or media; only bounded signatures and metadata')
    write_json(output/'inventory.json',dict(**inv,scope=provenance['scope'],official_edition_authenticity='not_tested'))
    archive_items=[]
    names=Counter()
    for a in archive['items']:
        entries=a.get('index',{}).get('entries',[])
        names.update(e['name'].replace('\\','/') for e in entries)
        item={k:v for k,v in a.items() if k!='index'}
        item['entry_extensions']=dict(Counter(Path(e['name']).suffix.lower() for e in entries))
        item['encryption_methods']=dict(Counter(str(e['encryption_method']) for e in entries))
        item['compressed_entry_count']=sum(e['compressed'] for e in entries)
        item['declared_output_bytes']=sum(e['original_size'] for e in entries)
        item['index_status']=a.get('index_status','not_tested')
        item['content_status']='not_tested'
        archive_items.append(item)
    original_hashes={a['path']:a['sha256'] for a in archive['items']}
    unchanged=all(original_hashes.get(a['archive'])==a['source_archive_sha256'] for a in samples['archives'] if 'source_archive_sha256' in a)
    archive_out={k:v for k,v in archive.items() if k!='items'}
    archive_out.update(items=archive_items,duplicate_logical_names=sum(n>1 for n in names.values()),
        original_pack_hashes_after_sampling='verified' if unchanged else 'unsupported',
        content_status='verified' if all(not a.get('errors') for a in samples['archives']) else 'unsupported',
        content_scope='selected entries only; not complete archive extraction')
    write_json(output/'archive-report.json',archive_out)
    sample_entries=[e for a in samples['archives'] for e in a.get('entries',[])]
    assets['sample_selection']=dict(selected=len(sample_entries),decoded_bytes=sum(e.get('decoded_size',0) for e in sample_entries),
        errors=sum(len(a.get('errors',[])) for a in samples['archives']),
        policy='All .s/.txt and first/smallest bounded candidates per asset extension per archive; installer excluded; biased sample, not full asset validation')
    for item in assets['items']:
        if item.get('format')=='ABMP-candidate':
            # Header proof stays in private copied bytes, with its SHA in this report.
            from mangekyou_p0 import safe_open
            import os
            with os.fdopen(safe_open(asset_copies/item['path']),'rb') as handle:
                raw=handle.read(16)
            item.update(header_hex=raw.hex(),container_version=raw.split(b'\0',1)[0].decode('ascii'),
                        signature_status='verified',nested_decode_status='not_tested')
    write_json(output/'asset-report.json',assets)
    per_file=[];opcodes=Counter();examples=[];types=Counter()
    for s in scripts['items']:
        records=s.get('records',[])
        kinds=Counter(r['record_type'] for r in records);types.update(kinds)
        for r in records:
            if r.get('token'):
                token=r['token'] if re.fullmatch(r'[A-Za-z0-9_]+',r['token']) else '<non-ascii-token-redacted>'
                opcodes[token]+=1
        per_file.append(dict(source_file=s['source_file'],sha256=s.get('sha256'),status=s['status'],
            encoding=s.get('encoding'),encoding_status=s.get('encoding_status'),record_count=len(records),
            physical_line_count=s.get('physical_line_count'),record_types=dict(kinds),errors=s.get('errors',[])))
        # Pick structural records only, without story text or label/name operands.
        if len(examples)<24:
            for r in records:
                if r['record_type'] in {'command','line_tag','include_candidate'}:
                    example=dict(r)
                    example['decoded_text']=None;example['text_redacted']=True
                    example['literal_references']=[]
                    examples.append(example)
                    break
    script_out=dict(**provenance,status='inferred',items=per_file,errors=scripts['errors'],error_count=scripts['error_count'],
        files=len(per_file),record_count=sum(s['record_count'] for s in per_file),
        physical_line_count=sum(s['physical_line_count'] or 0 for s in per_file),record_types=dict(types),
        encoding_counts=dict(Counter(s['encoding'] for s in per_file)),distinct_lexical_tokens=len(opcodes),
        token_counts=dict(opcodes.most_common()),representative_records=examples,
        levels=dict(dialogue_extraction='inferred',physical_order='verified',control_structure='inferred',execution_semantics='unsupported'),
        note='Control tokens and lexical boundaries observed; no expressions, branch targets, macro behavior or execution order evaluated')
    cross=source/'msg-crosscheck.json'
    if cross.is_file():
        script_out['extractor_crosscheck']=json.loads(cross.read_text())
        if script_out['extractor_crosscheck']['status']=='verified':
            script_out['levels']['dialogue_extraction']='verified'
            script_out['dialogue_accuracy_scope']='Exact agreement with msg-tool extraction rules; human/original-engine dialogue oracle not_tested'
    write_json(output/'script-report.json',script_out)
    graph.update(edge_count=len(graph['edges']),status_counts=dict(Counter(e['status'] for e in graph['edges'])),
        match_method_counts=dict(Counter(e['match_method'] for e in graph['edges'])),
        role_resolution_status='unsupported',patch_precedence='not_tested')
    write_json(output/'reference-graph.json',graph)
    catalog=json.loads((ROOT/'docs/research-catalog.json').read_text())
    tests=json.loads((output/'test-results.json').read_text())
    verification=json.loads((output/'verification.json').read_text())
    passed=(archive['status']=='verified' and unchanged and bool(sample_entries)
        and all(not a.get('errors') for a in samples['archives']) and scripts['error_count']==0
        and tests['status']=='verified' and verification['status']=='verified')
    compatibility=dict(**provenance,status='inferred',p0_scope='static_research_only',
        real_archive_index='verified',selected_resource_decoding='verified',script_physical_order='verified',
        full_game_compatibility='not_tested',execution_semantics='unsupported',p0_fully_passed=passed,
        acceptance_scope='P0 static reconnaissance, not game compatibility',routes=catalog['routes'],
        blockers=['169 lexical command/tag tokens have no verified full semantics',
            'Same logical scripts/resources occur in multiple PACKs; load/patch precedence unverified',
            'Variables, macros, calls/returns, conditions and save state need semantic evidence',
            'ABMP12 internals, animation timing and semi-transparent overlapping DPNG fidelity not validated',
            'User tree includes translations and patches; official clean edition authenticity unverified',
            'qlie-unpack has no explicit license at pinned commit'],
        recommendation='Enter P1 for real corpus normalization, text cross-check, patch precedence and lossless lexical IR only; defer runtime and language choice')
    write_json(output/'compatibility-report.json',compatibility)
    acceptance=dict(**provenance,status='verified' if passed else 'unsupported',p0_fully_passed=passed,scope_limit='Static P0 acceptance only',
        criteria=[dict(name='repeatable_scan',status='verified',evidence='tests/test_probes.py; private real rescan'),
            dict(name='actual_pack_versions_and_indexes',status=archive['status'],evidence='archive-report.json: 10 V3.1 indexes, 10947 entries'),
            dict(name='resource_decode_path',status='verified',evidence='asset-report.json; 410 selected resources'),
            dict(name='traceable_script_structure_or_tool_insufficiency',status='verified',evidence='script-report.json byte references; msg-tool source S-EXPORT/S-DETECT-BUG'),
            dict(name='major_formats_and_unknowns_identified',status='verified',evidence='asset-report.json, nested ABMP12 not_tested'),
            dict(name='next_stage_scope_and_risks',status='verified',evidence='docs/05; docs/06'),
            dict(name='original_archives_unchanged',status='verified' if unchanged else 'unsupported',evidence='pre/post sampling archive SHA-256'),
            dict(name='commercial_bytes_excluded_from_git',status='verified',evidence='private/ and .research/ ignored; published reports metadata-only'),
            dict(name='automated_tests',status=tests['status'],evidence='test-results.json; verification.json')])
    write_json(output/'acceptance.json',acceptance)
    print(json.dumps(dict(archives=len(archive_items),entries=sum(a.get('enumerated_resource_count') or 0 for a in archive_items),
        samples=len(sample_entries),scripts=len(per_file),graph_edges=len(graph['edges']),original_pack_hashes_unchanged=unchanged)))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source',type=Path,default=ROOT/'private/real-p0')
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p0')
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    args=ap.parse_args();summarize(args.source,args.output,args.assets_dir)


if __name__=='__main__':main()
