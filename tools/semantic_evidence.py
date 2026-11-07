#!/usr/bin/env python3
"""Second P1 round: structural constraints and evidence contracts, no interpreter."""
import argparse
from collections import Counter,defaultdict
import hashlib
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from .qlie_lex import codec_for,digest,line_records
    from .p1_static import identifier
else:
    from mangekyou_p0 import ROOT,ProbeError,absolute,read_bounded,safe_member_name,write_json
    from qlie_lex import codec_for,digest,line_records
    from p1_static import identifier

CORE={'if','then','else','end','for','case','sub','go','jmp','ret','var','gvar','svar','cal','brk','dbrk'}
OPENERS={'if','for','case'}
MAX_EXAMPLES=20


def proof(doc,r):
    return dict(source_file=doc['source_file'],source_sha256=doc['sha256'],byte_offset=r['byte_offset'],
        byte_length=r['byte_length'],record_sha256=r['raw_bytes_reference']['sha256'],
        label_region=identifier(r.get('_label','<file-prefix>')),
        confidence='inferred',execution_semantics='not_tested')


def mask_strings(text):
    """Keep positions, redact quoted content; no escape or evaluation semantics assumed."""
    out=[];quoted=False
    for c in text:
        if c=='"':quoted=not quoted;out.append(' ')
        else:out.append(' ' if quoted else c)
    return ''.join(out),quoted


def parameter_footprints(text):
    masked,unclosed=mask_strings(text)
    found=[]
    for m in re.finditer(r'\b(ParamInt|ParamStr|ResultInt|ResultStr|ResultBtnInt|ResultBtnStr)\s*\[\s*([^\]\r\n]+)\s*\]',masked):
        value=m.group(2).strip()
        found.append(dict(register=m.group(1),index=int(value) if value.isdecimal() else None,
            dynamic_index_sha256=None if value.isdecimal() else digest(value.encode()),
            char_offset=m.start(),observation='Unquoted lexical occurrence; read/write direction unknown'))
    return found,unclosed


def assignment_target(text):
    masked,_=mask_strings(text)
    m=re.match(r'\s*(#?[A-Za-z_][A-Za-z_0-9]*(?:\[[^\]\r\n]+\])?)\s*(?:[+*/%-]?=(?!=)|\+\+|--)',masked)
    return identifier(m.group(1)) if m else None


def blocks(doc):
    stack=[];completed=[];issues=[];max_depth=0;label_crossings=[]
    for r in doc['records']:
        if r['record_type']=='label' and stack:
            label_crossings.append(dict(**proof(doc,r),openers=[b['kind'] for b in stack]))
        if r['record_type']!='command':continue
        token=r['token'].lower()
        if token in OPENERS:
            frame=dict(kind=token,opener=proof(doc,r),arity=len(r['operands']),then_markers=[],else_markers=[],
                break_spelling_records=[],parent_opener_offset=stack[-1]['opener']['byte_offset'] if stack else None,
                depth=len(stack)+1,grammar='Hypothesis: if/for/case are paired by end',status='inferred')
            stack.append(frame);max_depth=max(max_depth,len(stack))
        elif token=='end':
            if not stack:issues.append(dict(category='unpaired_end',**proof(doc,r)))
            else:
                frame=stack.pop();frame['closer']=proof(doc,r);completed.append(frame)
        elif token=='then':
            if not stack or stack[-1]['kind']!='if':issues.append(dict(category='then_without_top_if',**proof(doc,r)))
            else:stack[-1]['then_markers'].append(proof(doc,r))
        elif token=='else':
            if not stack:issues.append(dict(category='else_without_open',**proof(doc,r)))
            else:stack[-1]['else_markers'].append(proof(doc,r))
        elif token in {'brk','dbrk'}:
            if stack:stack[-1]['break_spelling_records'].append(dict(token=token,**proof(doc,r)))
    for b in stack:issues.append(dict(category='unclosed_candidate_block',kind=b['kind'],**b['opener']))
    return dict(source_file=doc['source_file'],status='verified' if not issues else 'unsupported',
        scope='Conformance to an explicit candidate grammar, not engine grammar verification',
        maximum_depth=max_depth,blocks=completed,issues=issues,label_crossings=label_crossings)


def annotate_regions(doc):
    current='<file-prefix>';selector=None;line=None
    for r in doc['records']:
        if r.get('line_number')!=line:selector=None;line=r.get('line_number')
        if r['record_type']=='label':current=r.get('identifier','<empty-label>')
        r['_label']=current
        if r['record_type']=='command':
            if r['token'].lower()=='scp':selector=r['operands'][0]['value'] if r['operands'] else None
            r['_same_line_selector']=selector


def core_contracts(documents):
    arities=defaultdict(Counter);examples=defaultdict(list);types=Counter();decls=[];assignments=[];footprints=[]
    typed_regions=defaultdict(lambda:defaultdict(set));calls=[];quoted_errors=[];lengths=Counter();token_kinds=set()
    models=[]
    for d in documents:
        annotate_regions(d);models.append(blocks(d))
        for r in d['records']:
            if r['record_type']!='command':continue
            token=r['token'].lower();lengths[len(token)]+=1;token_kinds.add(token)
            if token in CORE:
                arities[token][len(r['operands'])]+=1
                if len(examples[token])<MAX_EXAMPLES:
                    examples[token].append(dict(**proof(d,r),arity=len(r['operands']),
                        operand_sha256=[digest(f['raw'].encode()) for f in r['operands']]))
            if token in {'var','gvar','svar'}:
                vals=[f['value'] for f in r['operands']];typ=identifier(vals[0]) if vals else None
                types[(token,typ)]+=1
                for val in vals[1:]:decls.append(dict(token=token,type_spelling=typ,name=identifier(val),**proof(d,r),
                    scope_semantics='not_tested',persistence='not_tested'))
            for field in r['operands']:
                found,unclosed=parameter_footprints(field['raw'])
                if unclosed:quoted_errors.append(dict(**proof(d,r),field_offset=field['byte_offset'],category='unclosed_field_quote'))
                for found_ref in found:
                    item=dict(**proof(d,r),**found_ref,field_offset=field['byte_offset'],field_length=field['byte_length'])
                    footprints.append(item)
                    if found_ref['register'].startswith('Param') and found_ref['index'] is not None:
                        typed_regions[(d['source_file'],r['_label'])][found_ref['register']].add(found_ref['index'])
                if token=='cal':
                    target=assignment_target(field['raw'])
                    assignments.append(dict(**proof(d,r),target=target,status='inferred' if target else 'unsupported',
                        expression_sha256=digest(field['raw'].encode()),evaluated=False))
            if token in {'sub','go','jmp','ret'}:
                vals=[f['value'] for f in r['operands']]
                calls.append(dict(token=token,**proof(d,r),arity=len(vals),
                    literal_label=identifier(vals[0][2:]) if vals and vals[0].startswith('@@') else None,
                    filename_like_operand_positions=[i for i,v in enumerate(vals) if v.lower().endswith('.s')],
                    empty_operand_positions=[i for i,v in enumerate(vals) if v==''],
                    operand_shape=[('quoted_string' if f['quoted'] else ('array_expression' if '[' in f['raw'] else 'bare_expression')) for f in r['operands']],
                    parameter_mapping='not_tested',return_convention='not_tested'))
    all_blocks=[b for m in models for b in m['blocks']]
    contracts=[]
    for token in sorted(arities):
        unknown={
            'if':['Condition coercion','Comparison operators','Case-context behavior'],
            'for':['Zero-argument behavior','Evaluation order','Overflow','brk/dbrk behavior'],
            'case':['Implicit comparison context','Fall-through behavior'],
            'ret':['Zero/one operand distinction','Return register/type','Unwind behavior'],
            'sub':['File argument position','Param typed-view mapping','Stack/context lifetime'],
            'var':['Type representation','Scope lifetime','Shadowing'],
            'gvar':['Scope category meaning','Persistence'],
            'svar':['Scope category meaning','Persistence'],
            'cal':['Assignment evaluation order','Coercion','Arithmetic width/overflow','Operator precedence']
        }.get(token,['Execution behavior and context effects'])
        contracts.append(dict(token=token,observed_arity_counts=dict(sorted(arities[token].items())),
            syntax_observation='verified',semantic_contract='inferred',runtime_implemented=False,
            unknown=unknown,evidence=examples[token],evidence_retained_limit=MAX_EXAMPLES))
    return dict(schema_version=1,dataset='real',status='verified' if all(m['status']=='verified' for m in models) and not quoted_errors else 'unsupported',
        scope='Measured script constraints and hypotheses only',contracts=contracts,
        block_hypothesis=dict(status='inferred',openers=sorted(OPENERS),closer='end',files=len(models),
            conforming_files=sum(m['status']=='verified' for m in models),
            opener_counts=dict(Counter(b['kind'] for b in all_blocks)),paired_blocks=len(all_blocks),
            maximum_depth=max((m['maximum_depth'] for m in models),default=0),
            issues=[i for m in models for i in m['issues']],
            label_crossings=[i for m in models for i in m['label_crossings']],
            if_without_then=sum(b['kind']=='if' and not b['then_markers'] for b in all_blocks),
            zero_operand_for=sum(b['kind']=='for' and b['arity']==0 for b in all_blocks)),
        command_token_max_length=max(lengths,default=0),command_token_kinds=len(token_kinds),
        declaration_type_counts=[dict(token=t,type_spelling=y,count=n) for (t,y),n in sorted(types.items())],
        declarations=decls,assignment_candidates=assignments,register_occurrences=footprints,
        parameter_regions=[dict(source_file=f,label=identifier(l),register_indices={k:sorted(v) for k,v in rs.items()},
            signature_status='not_tested',note='Observed register footprint, not accepted argument arity') for (f,l),rs in sorted(typed_regions.items())],
        transfer_spelling_records=calls,field_quote_issues=quoted_errors,models=models,
        execution_semantics='unsupported')


def range_evidence(doc,start_line,end_line):
    lines=list(line_records(doc['_bytes'],doc['source_file']))
    a=start_line-1;b=end_line-1
    if a<0 or b<a or b>len(lines)+1:raise ProbeError('diff_line_range_outside_source')
    start=lines[a]['byte_offset'] if a<len(lines) else len(doc['_bytes'])
    end=lines[b]['byte_offset'] if b<len(lines) else len(doc['_bytes'])
    selected=[r for r in doc['records'] if r.get('line_number') is not None and start_line<=r['line_number']<end_line]
    nearest=[r for r in doc['records'] if r['record_type']=='label' and r['byte_offset']<=start]
    label=nearest[-1].get('identifier') if nearest else '<file-prefix>'
    decls=[];targets=[]
    for r in selected:
        if r['record_type']=='command' and r['token'].lower() in {'var','svar','gvar'}:
            decls.append(dict(token=r['token'],type_spelling=identifier(r['operands'][0]['value']) if r['operands'] else None,
                names=[identifier(f['value']) for f in r['operands'][1:]],**proof(doc,r)))
        if r['record_type']=='command' and r['token'].lower()=='cal':
            targets.extend(assignment_target(f['raw']) for f in r['operands'])
    return dict(source_file=doc['source_file'],source_sha256=doc['sha256'],lines=[start_line,end_line],
        byte_offset=start,byte_length=end-start,span_sha256=digest(doc['_bytes'][start:end]),
        nearest_label=identifier(label),record_type_counts=dict(Counter(r['record_type'] for r in selected)),
        token_counts=dict(Counter(r['token'] for r in selected if r.get('token'))),
        declarations=decls,assignment_targets=[t for t in targets if t is not None])


def patch_impacts(documents,overlay):
    index={d['source_file']:d for d in documents};groups=[]
    for group in overlay['groups']:
        if group['relation']!='normalized_text_changed':continue
        item=dict(logical_path=group['logical_path'],same_token_sequence=group['same_token_sequence'],
            same_lexical_fields=group['same_lexical_fields'],comparisons=[],
            load_precedence='not_tested',semantic_effect='not_tested')
        for comparison in group['normalized_line_diffs']:
            a=index[comparison['left_source']];b=index[comparison['right_source']]
            regions=[]
            for change in comparison['changes']:
                regions.append(dict(operation=change['operation'],
                    left=range_evidence(a,*change['left_lines']),right=range_evidence(b,*change['right_lines'])))
            item['comparisons'].append(dict(left_source=a['source_file'],right_source=b['source_file'],regions=regions))
        groups.append(item)
    return dict(schema_version=1,dataset='real',status='verified',scope='Changed spans and enclosing lexical labels; no inferred patch winner',
        changed_groups=len(groups),items=groups,load_precedence='not_tested')


def save_boundaries(documents,inventory,game_dir=None):
    candidates=[];selector_counts=Counter();value_sources=[]
    for d in documents:
        relevant=any(k in d['logical_path'].casefold() for k in ['saveload','value.s','sysstartup.s','startup.s'])
        if not relevant:continue
        for r in d['records']:
            if r['record_type']!='command':continue
            token=r['token'].lower();selector=r.get('_same_line_selector')
            if selector is not None and token!='scp':selector_counts[(identifier(selector),token)]+=1
            if token in {'s','l','gsf','stf','lff','?sfs','garr','sarr'}:
                candidates.append(dict(**proof(d,r),token=token,same_line_selector=identifier(selector) if selector else None,
                    selector_persistence='not_tested',arity=len(r['operands']),
                    operand_shape=[dict(quoted=f['quoted'],value_sha256=digest(f['raw'].encode())) for f in r['operands']],
                    operation_meaning='Hypothesis from surrounding script names and labels, not executed'))
            if token=='svar':value_sources.append(dict(**proof(d,r),symbols=[identifier(f['value']) for f in r['operands'][1:]],
                persistence='not_tested'))
    headers=[];excluded=[]
    for f in inventory['files']:
        if f.get('extension')!='.dat':continue
        if Path(f['path']).name.casefold()!='systemdata.dat':
            excluded.append(dict(path=f['path'],status='not_tested',reason='Extension alone does not identify a save file'));continue
        item=dict(path=f['path'],size=f['size'],source_kind='bundled patch save candidate, not a clean runtime-generated slot',
            schema='not_tested',status='not_tested')
        if game_dir:
            data=read_bounded(absolute(game_dir)/safe_member_name(f['path']),16*1024*1024)
            item.update(status='verified',scope='Header only; no decryption or restoration',sha256=digest(data),
                header_magic_hex=data[:4].hex(),tag_locations=[])
            for tag in [b'IMOSYSDATA12',b'IMO_SYSDATA',b'IMOSAVEDATA']:
                pos=data[:256].find(tag)
                if pos>=0:item['tag_locations'].append(dict(tag=tag.decode(),offset=pos,length=len(tag)))
        headers.append(item)
    return dict(schema_version=1,dataset='real',status='inferred',scope='Read-only script boundary candidates and bounded header facts',
        operations=candidates,operation_count=len(candidates),
        selector_token_counts=[dict(selector=s,token=t,count=n) for (s,t),n in selector_counts.most_common()],
        svar_declaration_sources=value_sources,save_header_candidates=headers,excluded_dat_files=excluded,
        slot_save_schema='not_tested',restore_equivalence='not_tested',save_files_written=False)


def load_documents(corpus,assets,ir):
    documents=[];total=0
    for item in corpus['items']:
        rel=safe_member_name(item['source_file']);data=read_bounded(assets/rel,16*1024*1024);total+=len(data)
        if total>128*1024*1024 or len(documents)>=2000:raise ProbeError('corpus_limit')
        if digest(data)!=item['sha256']:raise ProbeError('source_sha256_mismatch:'+rel)
        doc=json.loads(read_bounded(ir/(rel+'.json')))
        if doc['source_file']!=rel or doc['sha256']!=item['sha256']:raise ProbeError('IR_source_identity_mismatch')
        cursor=0
        if len(doc['records'])>400000:raise ProbeError('record_limit')
        for r in doc['records']:
            a=r['byte_offset'];n=r['byte_length']
            if a!=cursor or n<0 or a+n>len(data):raise ProbeError('IR_byte_coverage_mismatch')
            if digest(data[a:a+n])!=r['raw_bytes_reference']['sha256']:raise ProbeError('IR_record_sha256_mismatch')
            cursor=a+n
        if cursor!=len(data):raise ProbeError('IR_missing_bytes')
        doc['records']=[r for r in doc['records'] if r['record_type'] not in {'layout_span','empty_span','bom'}]
        doc['_bytes']=data;doc['logical_path']=item['logical_path'];documents.append(doc)
    return documents


def public_contract(report):
    out=dict(report)
    for name in ['declarations','assignment_candidates','register_occurrences','parameter_regions','transfer_spelling_records']:
        out[name+'_count']=len(out[name]);out[name]=out[name][:100];out[name+'_retained_limit']=100
    out['block_hypothesis']=dict(out['block_hypothesis'])
    out['block_examples']=[b for m in report['models'] for b in m['blocks']][:100]
    out['models']=[dict(source_file=m['source_file'],status=m['status'],maximum_depth=m['maximum_depth'],
        block_count=len(m['blocks']),issues=m['issues']) for m in report['models']]
    out['complete_metadata_report']='private/p1-round2/contract-report.json'
    return out


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--assets-dir',type=Path,default=ROOT/'private/real-assets')
    ap.add_argument('--ir-dir',type=Path,default=ROOT/'private/p1/ir')
    ap.add_argument('--game-dir',type=Path)
    ap.add_argument('--output',type=Path,default=ROOT/'reports/p1')
    args=ap.parse_args();output=absolute(args.output);assets=absolute(args.assets_dir)
    if output!=ROOT/'reports/p1' and ROOT/'private' not in output.parents:raise ProbeError('unsafe_report_output')
    for source in [assets]+([absolute(args.game_dir)] if args.game_dir else []):
        if output==source or source in output.parents or output in source.parents:raise ProbeError('input/output overlap')
    corpus=json.loads(read_bounded(ROOT/'reports/p1/corpus-report.json'))
    overlay=json.loads(read_bounded(ROOT/'reports/p1/overlay-report.json'))
    inv=json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
    documents=load_documents(corpus,assets,absolute(args.ir_dir))
    contracts=core_contracts(documents)
    patches=patch_impacts(documents,overlay);saves=save_boundaries(documents,inv,args.game_dir)
    private=ROOT/'private/p1-round2'
    for name,value in [('contract-report.json',contracts),('patch-impact-report.json',patches),('save-boundary-report.json',saves)]:
        value.update(original_files_written=False,external_game_data_uploads=False)
        write_json(private/name,value)
        write_json(output/name,public_contract(value) if name=='contract-report.json' else value)
    print(json.dumps(dict(status=contracts['status'],files=len(documents),blocks=contracts['block_hypothesis']['paired_blocks'],
        block_issues=len(contracts['block_hypothesis']['issues']),patch_groups=patches['changed_groups'],save_operation_candidates=saves['operation_count'])))
    return 0 if contracts['status']=='verified' else 2


if __name__=='__main__':raise SystemExit(main())
