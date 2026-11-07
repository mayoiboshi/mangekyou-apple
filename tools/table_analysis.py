#!/usr/bin/env python3
"""Read-only table text morphology and lexical links; never execute a script."""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .qlie_lex import digest, lex, line_records
    from .subp_analysis import proof, dispatch_case
    from .object_callback_probe import relative_call
    from .delphi_metadata import Image, parse_class
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from qlie_lex import digest, lex, line_records
    from subp_analysis import proof, dispatch_case
    from object_callback_probe import relative_call
    from delphi_metadata import Image, parse_class
    from control_state_analysis import processing_deadline

MAX_TABLE_BYTES = 1024 * 1024
MAX_TABLE_LINES = 10000
MAX_LINE_CHARS = 8192
MAX_CORPUS_BYTES = 128 * 1024 * 1024


def ascii_key(value):
    if not value.isascii():
        raise ProbeError('table_non_ascii_lookup_outside_candidate')
    return value.lower()


def table_text(data, relative):
    """Describe bytes and an explicitly inferred first-name lookup projection.

    No table object is created and no query is run. The projection restricts
    comparison to ASCII; locale-dependent Delphi comparison is not reproduced.
    All admitted/rejected/unknown lines retain their original byte reference.
    """
    relative = safe_member_name(relative)
    if len(data) > MAX_TABLE_BYTES:
        raise ProbeError('table_text_size_limit')
    source_sha = digest(data)
    parsed = []
    first = {}
    for line in line_records(data, relative):
        if len(parsed) >= MAX_TABLE_LINES:
            raise ProbeError('table_text_line_limit')
        body = line['text']
        body = body[:-2] if body.endswith('\r\n') else body[:-1] if body.endswith('\n') else body
        if len(body) > MAX_LINE_CHARS:
            raise ProbeError('table_line_character_limit')
        name, sep, value = body.partition('=')
        unsupported = '\r' in body or any(ord(c) < 32 and c != '\t' for c in body)
        key = ascii_key(name) if sep and name and name.isascii() and not unsupported else None
        entry = (line, body, name, sep, value, key, unsupported)
        parsed.append(entry)
        if key is not None:
            first.setdefault(key, entry)
    rows = []
    counts = Counter()
    for line, body, name, sep, value, key, unsupported in parsed:
        ref = dict(line['raw_bytes_reference'], source_file=relative)
        row = dict(source_file=relative, source_sha256=source_sha,
            byte_offset=line['byte_offset'], byte_length=line['byte_length'],
            line_number=line['line_number'], raw_bytes_reference=ref,
            status='verified', scope='Source text morphology only; runtime admission not_tested')
        if unsupported:
            row.update(status='unsupported', candidate_disposition='unsupported_line_shape',
                unknown_reason='Bare CR or control character outside LF/CRLF morphology profile')
        elif not body.strip():
            row['candidate_disposition'] = 'blank'
        elif not sep:
            row['candidate_disposition'] = 'no_separator'
        elif not name:
            row['candidate_disposition'] = 'empty_name'
        elif key is None:
            row.update(status='unsupported', candidate_disposition='unresolved_non_ascii_name',
                unknown_reason='Native temporary-list locale/case comparison not recovered')
        else:
            selected = first[key]
            selected_line, _, _, _, selected_value, _, _ = selected
            row.update(status='inferred', name_sha256=digest(name.encode('utf-8')),
                ascii_name_sha256=digest(key.encode('ascii')),
                source_value_sha256=digest(value.encode('utf-8')),
                selected_value_sha256=digest(selected_value.encode('utf-8')),
                selected_line_reference=dict(selected_line['raw_bytes_reference'], source_file=relative),
                duplicate_ascii_name=selected_line['line_number'] != line['line_number'],
                outer_name_whitespace=name != name.strip(),
                outer_value_whitespace=value != value.strip(),
                scope='Hypothesis: first ASCII-insensitive name match, then filter and marker; no original execution')
            if '//' in name or '//' in selected_value:
                row['candidate_disposition'] = 'rejected_slash_candidate'
            elif selected_value == '%%none%%':
                row['candidate_disposition'] = 'empty_marker_candidate'
            elif not selected_value:
                row['candidate_disposition'] = 'empty_value_candidate'
            else:
                row['candidate_disposition'] = 'value_candidate'
        counts[row['candidate_disposition']] += 1
        rows.append(row)
    return dict(source_file=relative, source_sha256=source_sha, bytes=len(data),
        status='unsupported' if any(r['status'] == 'unsupported' for r in rows) else 'inferred',
        scope='All physical LF/CRLF text lines plus a restricted ASCII first-value hypothesis; no table execution',
        encoding=parsed[0][0]['encoding'] if parsed else None,
        encoding_status=parsed[0][0]['encoding_status'] if parsed else 'not_tested',
        physical_lines=len(parsed), candidate_counts=dict(counts), lines=rows,
        runtime_decoding='not_tested', stored_entry_count='not_tested',
        empty_optimization_flag='not_tested', query_results='not_tested')


def literal(field):
    raw = field['raw']
    return raw[1:-1] if len(raw) >= 2 and raw[0] == raw[-1] == '"' and '"' not in raw[1:-1] else None


def lexical_sites(data, relative, catalog_items):
    """Trace straight-line spellings only; branches/calls invalidate scope hints."""
    doc = lex(data, relative, field_model='native_grouping')
    if doc['status'] != 'verified':
        raise ProbeError('table_script_lexical_failure')
    rows = []
    declared = {}
    selected = []
    loads = {}
    by_logical = {}
    for item in catalog_items:
        logical = safe_member_name(item['logical_path'])
        if logical.isascii():
            by_logical.setdefault(logical.lower(), []).append(item)
    barrier_tokens = {'if', 'else', 'then', 'end', 'for', 'while', 'switch', 'case',
        'sub', 'subp', 'subr', 'ret', 'jmp', 'go', 'dbrk', 'break'}
    for record in doc['records']:
        token = (record.get('token') or '').lower()
        if record['record_type'] in {'label', 'include'} or token in barrier_tokens:
            selected = []
            loads.clear()
        if record['record_type'] != 'command':
            continue
        fields = record['operands']
        if token in {'var', 'gvar', 'svar'}:
            if len(fields) >= 2 and re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', fields[1]['raw']):
                name = ascii_key(fields[1]['raw'])
                if fields[0]['raw'].lower() == 'table' and len(fields) == 2:
                    row = dict(**proof(doc, record), status='inferred', command=token,
                        record_role='table_declaration_candidate', identifier_sha256=digest(name.encode()),
                        declaration_scope='Lexical spelling only; actual namespace/lifetime not_tested')
                    declared[name] = row
                    rows.append(row)
                else:
                    declared.pop(name, None)
            continue
        if token == 'scp':
            selected = []
            for slot, field in enumerate(fields):
                name = field['raw']
                if name.isascii() and name.lower() in declared and slot < 16:
                    selected.append(dict(slot=slot, declaration=declared[name.lower()]))
                else:
                    selected.append(dict(slot=slot, declaration=None))
            rows.append(dict(**proof(doc, record), status='inferred', command=token,
                record_role='scope_selector_candidate', selector_count=len(fields),
                matched_table_slots=sum(r['declaration'] is not None for r in selected),
                actual_object_binding='not_tested'))
            continue
        if token not in {'l', '?v'}:
            continue
        # Preserve unbound candidates too: these spellings can belong to other classes.
        row = dict(**proof(doc, record), status='inferred', command=token,
            lexical_arity=len(fields), record_role='load_candidate' if token == 'l' else 'query_candidate',
            reference_type='Unknown', actual_object_binding='not_tested',
            scope_hint='straight_line_lexical_candidate_only',
            declaration_candidates=[dict(slot=r['slot'], **{k: v for k, v in r['declaration'].items()
                if k in {'source_file', 'source_sha256', 'byte_offset', 'byte_length', 'raw_bytes_reference'}})
                for r in selected if r['declaration'] is not None])
        if token == 'l':
            text = literal(fields[0]) if len(fields) == 1 else None
            row['resource_candidates'] = []
            if text is None:
                row.update(status='unsupported', unknown_reason='Load filename is not one simple quoted literal')
            else:
                try:
                    logical = safe_member_name(text)
                    if not logical.isascii():
                        raise ProbeError('table_resource_non_ascii_comparison_unknown')
                    candidates = by_logical.get(logical.lower(), [])
                    row['resource_candidates'] = [dict(source_file=r['source_file'], source_sha256=r['sha256']) for r in candidates]
                    row['differing_variant_count'] = len({r['sha256'] for r in candidates})
                    if not candidates:
                        row.update(status='unsupported', unknown_reason='Literal has no match in the bounded text corpus')
                except ProbeError as exc:
                    row.update(status='unsupported', unknown_reason=str(exc))
            for candidate in row['declaration_candidates']:
                loads[candidate['byte_offset']] = row
        else:
            row['default_field_shape'] = ('absent' if len(fields) == 1 else
                'string_literal' if len(fields) == 2 and literal(fields[1]) is not None else
                'canonical_integer_literal' if len(fields) == 2 and re.fullmatch(r'-?(0|[1-9][0-9]*)', fields[1]['raw']) else
                'expression_or_other')
            key_text = literal(fields[0]) if fields else None
            row['key_field_shape'] = 'ascii_string_literal' if key_text is not None and key_text.isascii() else 'expression_or_other'
            if row['key_field_shape'] == 'ascii_string_literal':
                row['literal_ascii_key_sha256'] = digest(ascii_key(key_text).encode())
            row['prior_load_candidates'] = []
            seen_loads = set()
            for candidate in row['declaration_candidates']:
                load = loads.get(candidate['byte_offset'])
                if load and load['byte_offset'] not in seen_loads:
                    seen_loads.add(load['byte_offset'])
                    row['prior_load_candidates'].append({k: load[k] for k in [
                        'source_file', 'source_sha256', 'byte_offset', 'byte_length',
                        'raw_bytes_reference', 'resource_candidates']})
        rows.append(row)
    for row in rows:
        row['raw_bytes_reference']['source_file'] = relative
    return rows


def native_bindings(program, source_file):
    image = Image(program)
    classes = [parse_class(image, at, 0, name) for at, name in [
        (0x6889b4, 'TImoObjectDataFastStringList'), (0x562d00, 'TFastStringList'), (0x432d50, 'TStringList')]]
    table, fast, _ = classes
    if table['instance_size'] != 32 or fast['instance_size'] != 16:
        raise ProbeError('table_class_size_identity')
    if {f['name']: f['offset'] for f in table['fields']} != {'obj': 24}:
        raise ProbeError('table_component_offset_identity')
    if {f['name']: f['offset'] for f in fast['fields']} != {'FList': 4, 'FNoneOptimize': 8}:
        raise ProbeError('table_fast_list_fields_identity')
    if image.read(0x6bf131, 5) != b'\xba\x78\xf6\x6b\x00' or image.read(0x6bf141, 5) != b'\xa1\x5c\x89\x68\x00':
        raise ProbeError('table_factory_selected_arguments')
    if image.u32(0x68895c) != 0x6889b4 or image.u32(0x562ca8) != 0x562d00:
        raise ProbeError('table_class_pointer_identity')
    literals = []
    for address, text in [(0x6bf678, 'table'), (0x563b48, '//'), (0x563af4, '%%none%%'),
                          (0x6ce72c, 'ResultStr'), (0x6ce74c, 'ResultInt')]:
        raw = (text + '\0').encode('utf-16-le')
        if image.u32(address - 4) != len(text) or image.read(address, len(raw)) != raw:
            raise ProbeError('table_literal_identity')
        literals.append(dict(symbol=text, address=hex(address), raw_bytes_reference=image.reference(address - 4, len(raw) + 4)))
    slots = []
    for slot, target in [(0x58, 0x43da78), (0x70, 0x43dc60), (0x74, 0x43dc6c), (0x34, 0x43ef14)]:
        if image.u32(0x432d50 + slot) != target:
            raise ProbeError('table_temporary_list_slot_identity')
        slots.append(dict(offset=slot, target=hex(target), raw_bytes_reference=image.reference(0x432d50 + slot, 4)))
    result = dict(status='inferred', classes=classes, literals=literals, temporary_list_slots=slots,
        factory_class_argument=image.reference(0x6bf141, 5),
        factory_literal_argument=image.reference(0x6bf131, 5),
        factory_compare_call=relative_call(image, 0x6bf136, 0x407b38),
        factory_create_call=relative_call(image, 0x6bf146, 0x68f1e8),
        dispatch=dispatch_case(image, 0x6aaeb1, 0x6aaec5, 40, 36, 0x6aafc1, 0x6aafca, 0x6cdd34),
        original_execution='not_tested')
    sha = digest(program)
    def add_identity(value):
        if isinstance(value, dict):
            if {'offset', 'length', 'sha256'} <= value.keys():
                value.update(source_file=source_file, source_sha256=sha)
            for v in list(value.values()):
                add_identity(v)
        elif isinstance(value, list):
            for v in value:
                add_identity(v)
    add_identity(result)
    return result


def key_links(sites, texts):
    """Conditional byte links, never an answer to a script query."""
    by_source = {r['source_file']: r for r in texts}
    links = []
    for site in sites:
        if site.get('record_role') != 'query_candidate':
            continue
        loads = site.get('prior_load_candidates', [])
        if not loads:
            links.append(dict(query_reference=site['raw_bytes_reference'], status='unsupported',
                reference_type='Unknown', unknown_reason='No straight-line prior table load candidate',
                actual_query='not_tested'))
        for load in loads:
            if len(links) >= 50000:
                raise ProbeError('table_key_link_count_limit')
            if not load['resource_candidates']:
                links.append(dict(query_reference=site['raw_bytes_reference'],
                    load_reference=load['raw_bytes_reference'], status='unsupported', reference_type='Unknown',
                    unknown_reason='Prior load literal has no resource candidates', actual_query='not_tested'))
            for resource in load['resource_candidates']:
                text = by_source.get(resource['source_file'])
                key_sha = site.get('literal_ascii_key_sha256')
                matches = [r for r in text.get('lines', []) if key_sha and r.get('ascii_name_sha256') == key_sha] if text else []
                if text and resource['source_sha256'] != text['source_sha256']:
                    raise ProbeError('table_link_source_identity')
                line_refs = []
                seen = set()
                for match in matches:
                    ref = match['selected_line_reference']
                    if ref['offset'] not in seen:
                        seen.add(ref['offset'])
                        line_refs.append(ref)
                links.append(dict(query_reference=site['raw_bytes_reference'],
                    load_reference=load['raw_bytes_reference'], table_source=resource,
                    status='inferred' if line_refs else 'unsupported', reference_type='Unknown',
                    candidate_line_references=line_refs, actual_query='not_tested',
                    scope='Conditional literal-key/first-ASCII-name match only; branch reachability and runtime package winner unknown',
                    unknown_reason=None if line_refs else 'Literal key has no supported candidate row; this does not prove the original query misses'))
                if len(links) > 50000:
                    raise ProbeError('table_key_link_count_limit')
    return links


def analyze_corpus(assets, items, script_files):
    if not 1 <= len(items) <= 2000 or not 1 <= len(script_files) <= 16 or len(set(script_files)) != len(script_files):
        raise ProbeError('table_corpus_count_limit_or_duplicate_selection')
    by_source = {}
    for item in items:
        name = safe_member_name(item['source_file'])
        if name in by_source:
            raise ProbeError('table_duplicate_catalog_source')
        by_source[name] = item
    sites = []
    total = 0
    def read(name, limit):
        nonlocal total
        if name not in by_source:
            raise ProbeError('table_source_not_in_locked_corpus')
        data = read_bounded(assets / name, limit)
        total += len(data)
        if total > MAX_CORPUS_BYTES or digest(data) != by_source[name]['sha256']:
            raise ProbeError('table_source_identity_or_total_size')
        return data
    for source in script_files:
        source = safe_member_name(source)
        sites.extend(lexical_sites(read(source, 16 * 1024 * 1024), source, items))
        if len(sites) > 20000:
            raise ProbeError('table_script_site_limit')
    targets = sorted({r['source_file'] for s in sites if s.get('declaration_candidates')
        for r in s.get('resource_candidates', [])})
    if len(targets) > 32:
        raise ProbeError('table_target_count_limit')
    texts = []
    table_rows = 0
    table_bytes = 0
    for name in targets:
        data = read(name, MAX_TABLE_BYTES)
        table_bytes += len(data)
        if table_bytes > 8 * 1024 * 1024:
            raise ProbeError('table_target_total_byte_limit')
        try:
            texts.append(table_text(data, name))
        except (ProbeError, UnicodeError) as exc:
            texts.append(dict(source_file=name, source_sha256=digest(data), status='unsupported',
                unknown_reason=str(exc), scope='Failed text probe; no candidate state published'))
        table_rows += len(texts[-1].get('lines', []))
        if table_rows > 50000:
            raise ProbeError('table_target_total_line_limit')
    links = key_links(sites, texts)
    unknowns = Counter(r['unknown_reason'] for r in sites + links + texts if r.get('unknown_reason'))
    return dict(status='inferred', selected_script_files=script_files, selected_script_count=len(script_files),
        sites=sites, site_counts=dict(Counter(s['record_role'] for s in sites)),
        site_status_counts=dict(Counter(s['status'] for s in sites)),
        table_texts=texts, table_text_count=len(texts),
        table_text_status_counts=dict(Counter(t['status'] for t in texts)),
        conditional_key_links=links, key_link_count=len(links),
        key_link_status_counts=dict(Counter(r['status'] for r in links)),
        issue_count=sum(unknowns.values()), unknown_reasons=dict(unknowns),
        all_versions_preserved=True, resource_reference_types='Unknown',
        scope='Only explicitly selected script spellings and their literal text targets; no reachability or object-binding proof',
        actual_startup_reachability='not_tested', execution_semantics='not_tested')


def run_analysis(args, game, assets, output):
    native_path = ROOT / 'reports/p1/table-native-report.json'
    native_bytes = read_bounded(native_path)
    native = json.loads(native_bytes)
    needed = {'table_tag_and_list', 'line_loader_order', 'slash_filter', 'marker_null_branch',
        'query_default_pair', 'query_missing_results', 'query_found_results'}
    if native.get('errors') or native.get('independent_collection', {}).get('status') != 'verified' or not needed <= {
        r['id'] for r in native['observations'] if r['status'] == 'verified'}:
        raise ProbeError('table_native_evidence_missing')
    helper_bytes = read_bounded(ROOT / 'reports/p1/table-helper-native-report.json')
    helper = json.loads(helper_bytes)
    if helper.get('errors') or helper.get('independent_collection', {}).get('status') != 'verified' or not {
        'slash_word_scan', 'slash_zero_or_position', 'name_position_pointer_index'} <= {
            r['id'] for r in helper['observations'] if r['status'] == 'verified'}:
        raise ProbeError('table_helper_evidence_missing')
    name = safe_member_name(args.exe)
    program = read_bounded(game / name, 64 * 1024 * 1024)
    sha = digest(program)
    inventory = json.loads(read_bounded(ROOT / 'reports/p0/inventory.json'))
    if sha != native['source_sha256'] or sha != helper['source_sha256'] or not any(f['path'] == name and f.get('sha256') == sha for f in inventory['files']):
        raise ProbeError('table_program_inventory_identity')
    corpus_bytes = read_bounded(ROOT / 'reports/p1/corpus-report.json')
    corpus = json.loads(corpus_bytes)
    with processing_deadline(120):
        bindings = native_bindings(program, name)
        report = analyze_corpus(assets, corpus['items'], args.script_file)
    if digest(read_bounded(game / name, 64 * 1024 * 1024)) != sha:
        raise ProbeError('table_program_changed_during_probe')
    report.update(schema_version=1, dataset='real', native_report='reports/p1/table-native-report.json',
        native_report_sha256=digest(native_bytes), corpus_report_sha256=digest(corpus_bytes),
        helper_report='reports/p1/table-helper-native-report.json', helper_report_sha256=digest(helper_bytes),
        source_file=name, source_sha256=sha, native_bindings=bindings,
        original_files_written=False, external_game_data_uploads=False,
        commercial_text_in_public_reports=False, runtime_development_ready=False,
        full_native_port='not_tested')
    write_json(output, report)
    print(json.dumps(dict(status=report['status'], scripts=report['selected_script_count'],
        sites=report['site_counts'], texts=report['table_text_count'], text_statuses=report['table_text_status_counts'])))
    return 2 if report['table_text_status_counts'].get('unsupported') else 0


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir', type=Path, required=True)
    p.add_argument('--exe', required=True)
    p.add_argument('--assets-dir', type=Path, required=True)
    p.add_argument('--script-file', action='append', required=True)
    p.add_argument('--output', type=Path, default=ROOT / 'reports/p1/table-analysis-report.json')
    args = p.parse_args()
    output_safe = False
    try:
        game, assets, output = map(absolute, [args.game_dir, args.assets_dir, args.output])
        if ROOT / 'reports/p1' not in output.parents:
            raise ProbeError('table_summary_must_be_public_P1')
        for source in [game, assets]:
            if source == output or source in output.parents or output in source.parents:
                raise ProbeError('table_input_output_overlap')
        output_safe = True
        return run_analysis(args, game, assets, output)
    except (OSError, ValueError, KeyError, TimeoutError) as exc:
        # Invalid paths cannot authorize any output write, including diagnostics.
        diagnostic = dict(schema_version=1, status='unsupported',
            scope='Failed static probe; no partial compatibility result',
            errors=[dict(category=type(exc).__name__, code=str(exc) if isinstance(exc, ProbeError) else type(exc).__name__)],
            original_files_written=False, execution_semantics='not_tested')
        print(json.dumps(diagnostic))
        if output_safe:
            write_json(output, diagnostic)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
