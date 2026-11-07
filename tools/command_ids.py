#!/usr/bin/env python3
"""Read-only command identifier candidates, not dispatch or execution semantics."""
import argparse
from collections import Counter,defaultdict
import json
from pathlib import Path

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .qlie_lex import digest,lex
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from qlie_lex import digest,lex


def identifier_candidate(token):
    if not token or any(ord(c)>127 for c in token):
        return dict(status='unsupported',reason='Empty or non-ASCII identifier; Unicode behavior is not modeled')
    lower=''.join(chr(ord(c)+32) if 'A'<=c<='Z' else c for c in token)
    head=lower[:4];value=sum(ord(c)<<(8*i) for i,c in enumerate(head))
    return dict(status='inferred',identifier_hex='0x'+format(value,'08x'),ascii_lowered=lower,
        truncated=len(lower)>4,truncated_character_count=max(0,len(lower)-4),
        dispatch_meaning='not_tested',scope='ASCII normal-flow arithmetic candidate only; retains truncation explicitly')


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    args=p.parse_args();assets=absolute(args.assets_dir)
    if assets==ROOT/'reports/p1' or assets in (ROOT/'reports/p1').parents or ROOT/'reports/p1' in assets.parents:
        raise ProbeError('input_output_overlap')
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    if not 1<=len(corpus['items'])<=2000:raise ProbeError('corpus_count_limit')
    tokens=Counter();examples=defaultdict(list);total=0
    for item in corpus['items']:
        relative=safe_member_name(item['source_file']);data=read_bounded(assets/relative,16*1024*1024);total+=len(data)
        if total>128*1024*1024:raise ProbeError('corpus_byte_limit')
        if digest(data)!=item['sha256']:raise ProbeError('corpus_source_digest_mismatch')
        doc=lex(data,relative)
        if doc['status']!='verified':raise ProbeError('source_lexical_failure')
        for record in doc['records']:
            if record['record_type']!='command':continue
            token=record['token'];tokens[token]+=1
            if len(examples[token])<3:
                examples[token].append(dict(source_file=relative,source_sha256=item['sha256'],
                    byte_offset=record['byte_offset'],byte_length=record['byte_length'],
                    record_sha256=record['raw_bytes_reference']['sha256']))
    rows=[];groups=defaultdict(list)
    for token,count in sorted(tokens.items()):
        row=identifier_candidate(token);row.update(token=token,occurrences=count,evidence=examples[token]);rows.append(row)
        if row.get('identifier_hex'):groups[row['identifier_hex']].append(token)
    collisions=[dict(identifier_hex=k,tokens=v,status='inferred',scope='Arithmetic collision; resolution and behavior unknown')
                for k,v in sorted(groups.items()) if len(v)>1]
    report=dict(schema_version=1,dataset='real',status='inferred',
        scope='Reconstructed ASCII command ID candidates for all lexical backslash commands; no instruction execution',
        files=len(corpus['items']),command_records=sum(tokens.values()),distinct_tokens=len(rows),
        unsupported_tokens=sum(r['status']=='unsupported' for r in rows),truncated_tokens=sum(r.get('truncated',False) for r in rows),
        candidates=rows,collisions=collisions,evidence_limit_per_token=3,
        original_function='0x6aa43c',original_assembly_evidence='reports/p1/native-report.json',
        derived_normal_flow_evidence='reports/p1/tail-probe-report.json',
        full_execution_semantics='not_tested',original_files_written=False,external_game_data_uploads=False)
    write_json(ROOT/'reports/p1/command-id-report.json',report)
    print(json.dumps({k:report[k] for k in ['status','files','command_records','distinct_tokens','unsupported_tokens','truncated_tokens']}))
    return 0 if not report['unsupported_tokens'] else 2


if __name__=='__main__':raise SystemExit(main())
