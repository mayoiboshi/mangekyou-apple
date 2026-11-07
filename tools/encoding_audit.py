#!/usr/bin/env python3
"""Audit encoding ambiguity and selected native bindings; no script execution."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import platform

if __package__:
    from .mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from .qlie_lex import codec_for, digest
    from .delphi_metadata import Image, parse_class
    from .control_state_analysis import processing_deadline
else:
    from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json
    from qlie_lex import codec_for, digest
    from delphi_metadata import Image, parse_class
    from control_state_analysis import processing_deadline

CODECS = ('cp932', 'cp936', 'cp1252', 'utf-8', 'utf-16-le', 'utf-16-be')
PREAMBLES = ((b'\xff\xfe', 'utf-16-le'), (b'\xfe\xff', 'utf-16-be'), (b'\xef\xbb\xbf', 'utf-8'))
MAX_FILE_BYTES = 16 * 1024 * 1024
MAX_TOTAL_BYTES = 128 * 1024 * 1024


def reference(data, source, start=0, length=None):
    if length is None:
        length = len(data) - start
    if not 0 <= start <= start + length <= len(data):
        raise ProbeError('encoding_reference_bounds')
    return dict(source_file=safe_member_name(source), source_sha256=digest(data),
        offset=start, length=length, sha256=digest(data[start:start+length]))


def prefix_profile(data):
    for marker, codec in PREAMBLES:
        if data.startswith(marker):
            return codec, len(marker)
    return None, 0


def audit_text(data, source):
    source = safe_member_name(source)
    if len(data) > MAX_FILE_BYTES:
        raise ProbeError('encoding_file_size_limit')
    bom_codec, bom_size = prefix_profile(data)
    rows = []
    for codec in CODECS:
        skipped = bom_size if codec == bom_codec else 0
        try:
            text = data[skipped:].decode(codec, errors='strict')
            rows.append(dict(codec=codec, status='verified',
                scope='Python strict decoder accepted the bytes; not Windows NLS or engine equivalence',
                consumed_matching_bom_bytes=skipped, scalar_count=len(text),
                decoded_utf8_sha256=digest(text.encode('utf-8')),
                control_character_count=sum(ord(c) < 32 and c not in '\r\n\t' for c in text),
                cr_count=text.count('\r'), lf_count=text.count('\n')))
        except UnicodeError as exc:
            rows.append(dict(codec=codec, status='unsupported',
                reason='Python strict decoder rejected input',
                failure_reference=reference(data, source, skipped+exc.start, exc.end-exc.start)))
    # Reuse the existing corpus model. Never select a codec by trial-decoding order.
    model_codec, model_bom, model_status = codec_for(data)
    model = next(r for r in rows if r['codec'] == model_codec)
    accepted = [r for r in rows if r['status'] == 'verified']
    result = dict(source_file=source, source_sha256=digest(data), bytes=len(data),
        raw_bytes_reference=reference(data, source), status='inferred',
        prefix_status='verified', bom_codec=bom_codec, bom_bytes=bom_size,
        bom_reference=reference(data, source, 0, bom_size) if bom_size else None,
        native_encoding_branch_candidate='preamble' if bom_codec else 'system_default_codepage',
        actual_windows_codepage='not_tested', runtime_decoding='not_tested',
        candidates=rows, strict_success_count=len(accepted),
        distinct_strict_decoded_payloads=len({r['decoded_utf8_sha256'] for r in accepted}),
        research_model_codec=model_codec, research_model_codec_status=model_status,
        research_model_bom_bytes=model_bom, research_model_decode_status=model['status'],
        scope='Bounded byte/prefix/strict-codec observations; decoding acceptance does not identify the engine codec')
    if model['status'] == 'verified':
        result['research_model_decoded_utf8_sha256'] = model['decoded_utf8_sha256']
    else:
        result.update(status='unsupported', unknown_reason='Existing corpus decoding model rejected these bytes')
    by_codec = {r['codec']: r for r in accepted}
    result['cp932_cp936_both_accept'] = all(c in by_codec for c in ['cp932', 'cp936'])
    result['cp932_cp936_disagree'] = result['cp932_cp936_both_accept'] and (
        by_codec['cp932']['decoded_utf8_sha256'] != by_codec['cp936']['decoded_utf8_sha256'])
    return result


def compare_variants(rows):
    groups = defaultdict(list)
    for row in rows:
        groups[row['logical_path']].append(row)
    result = []
    for logical, variants in sorted(groups.items()):
        if len(variants) < 2:
            continue
        valid = all(v.get('research_model_decode_status') == 'verified' for v in variants)
        same = valid and len({v['research_model_decoded_utf8_sha256'] for v in variants}) == 1
        result.append(dict(logical_path=logical, status='inferred' if valid else 'unsupported',
            raw_bytes_equal=len({v['source_sha256'] for v in variants}) == 1,
            exact_decoded_scalars_equal=same if valid else None,
            comparison_status='verified' if valid else 'unsupported',
            scope='Existing research codecs; remove matching BOM only; no newline/NFC/case normalization',
            variants=[{k: v[k] for k in ['source_file', 'source_sha256', 'research_model_codec',
                'research_model_decode_status', 'research_model_decoded_utf8_sha256'] if k in v} for v in variants],
            actual_package_winner='not_tested', original_behavioral_equivalence='not_tested'))
    return result


def audit_corpus(assets, items, selected=None):
    if not 1 <= len(items) <= 2000:
        raise ProbeError('encoding_corpus_count_limit')
    index = {}
    for item in items:
        name = safe_member_name(item['source_file'])
        if name in index:
            raise ProbeError('encoding_duplicate_corpus_source')
        index[name] = item
    names = sorted(index) if selected is None else [safe_member_name(n) for n in selected]
    if not names or len(names) != len(set(names)) or any(n not in index for n in names):
        raise ProbeError('encoding_invalid_source_selection')
    rows = []
    total = 0
    for name in names:
        item = index[name]
        try:
            data = read_bounded(assets/name, MAX_FILE_BYTES)
            total += len(data)
            if total > MAX_TOTAL_BYTES:
                raise ProbeError('encoding_total_size_limit')
            if digest(data) != item['sha256']:
                raise ProbeError('encoding_source_digest_mismatch')
            row = audit_text(data, name)
            if row['research_model_codec'] != item['encoding']:
                raise ProbeError('encoding_corpus_label_mismatch')
        except (OSError, ValueError) as exc:
            row = dict(source_file=name, source_sha256=item['sha256'], status='unsupported',
                unknown_reason=str(exc) if isinstance(exc, ProbeError) else type(exc).__name__,
                research_model_decode_status='unsupported', research_model_codec=item['encoding'])
        row['logical_path'] = safe_member_name(item['logical_path'])
        rows.append(row)
        if total > MAX_TOTAL_BYTES:
            raise ProbeError('encoding_total_size_limit')
    groups = compare_variants(rows)
    return dict(status='unsupported' if any(r['status'] == 'unsupported' for r in rows) else 'inferred',
        physical_files=len(rows), logical_paths=len({r['logical_path'] for r in rows}), bytes=total,
        rows=rows, file_status_counts=dict(Counter(r['status'] for r in rows)),
        bom_counts=dict(Counter(r.get('bom_codec') or 'none_or_unreadable' for r in rows)),
        strict_decode_status_counts=dict(Counter(c['status'] for r in rows for c in r.get('candidates', []))),
        cp932_cp936_both_accept_count=sum(r.get('cp932_cp936_both_accept', False) for r in rows),
        cp932_cp936_disagreement_count=sum(r.get('cp932_cp936_disagree', False) for r in rows),
        duplicate_groups=groups, duplicate_group_count=len(groups),
        different_bytes_exact_model_text_equal=sum(not g['raw_bytes_equal'] and g['exact_decoded_scalars_equal'] is True for g in groups),
        different_bytes_exact_model_text_different=sum(not g['raw_bytes_equal'] and g['exact_decoded_scalars_equal'] is False for g in groups),
        all_selected_versions_preserved=True, actual_windows_codepage='not_tested',
        scope='Selected locked text corpus; strict codec observations and existing-model text comparison, no engine execution')


def minimal_class(image, vmt, name, slots):
    """Header/name/selected slots only; accepts an absent extended field table."""
    if len(slots) > 8 or image.u32(vmt-88) != vmt:
        raise ProbeError('encoding_class_header_identity')
    name_at = image.u32(vmt-56)
    actual_name, length = image.short(name_at)
    if actual_name != name or not 4 <= image.u32(vmt-52) <= 1024*1024:
        raise ProbeError('encoding_class_name_or_size')
    selected = []
    for offset, target in slots:
        if not -88 <= offset <= 128 or image.u32(vmt+offset) != target:
            raise ProbeError('encoding_class_slot_identity')
        image.code(target)
        selected.append(dict(offset=offset, target=hex(target), raw_bytes_reference=image.reference(vmt+offset, 4)))
    return dict(name=name, vmt=hex(vmt), status='inferred', instance_size=image.u32(vmt-52),
        header_reference=image.reference(vmt-88, 88), name_reference=image.reference(name_at, length),
        selected_slots=selected, extended_field_table_present=image.u32(vmt-68) != 0,
        complete_layout='not_tested', actual_dispatch='not_tested')


def bind_import(image, evidence, name, thunk, iat):
    if evidence.get('operation') != 'inspect_pe_imports' or evidence.get('subject', {}).get('digest', {}).get('sha256') != digest(image.data):
        raise ProbeError('encoding_import_evidence_identity')
    if evidence.get('provider', {}).get('id') != 'rea-pe-imports':
        raise ProbeError('encoding_import_provider')
    rows = [(lib, f) for lib in evidence['normalized_result']['imports'] for f in lib['functions']
        if f.get('name') == name and image.pe['image_base']+f['iat_rva'] == iat]
    if len(rows) != 1:
        raise ProbeError('encoding_import_slot_not_unique')
    lib, function = rows[0]
    if lib['name'].lower() != 'kernel32.dll' or image.read(thunk, 2) != b'\xff\x25' or image.u32(thunk+2) != iat:
        raise ProbeError('encoding_import_jump_identity')
    entry = image.u32(iat)
    if entry != int(function['thunk_hex'], 16) or entry & 0x80000000:
        raise ProbeError('encoding_import_entry_identity')
    name_at = image.pe['image_base'] + entry
    expected = name.encode('ascii')+b'\0'
    dll_at = image.pe['image_base']+lib['name_rva']
    if image.read(name_at+2, len(expected)) != expected or image.read(dll_at, len(lib['name'])+1) != lib['name'].encode('ascii')+b'\0':
        raise ProbeError('encoding_import_name_identity')
    return dict(name=name, dll=lib['name'], status='verified', thunk=hex(thunk), iat=hex(iat),
        thunk_reference=image.reference(thunk, 6), iat_reference=image.reference(iat, 4),
        name_reference=image.reference(name_at, len(expected)+2),
        dll_reference=image.reference(dll_at, len(lib['name'])+1), execution='not_tested')


def constructor_arguments(image, earlier_push, later_push, codepage_at):
    """Only the reviewed PUSH imm8 / MOV ECX imm32 or XOR ECX form.

    In the selected callee, EBP+12 (earlier push) feeds object+16,
    while EBP+8 (later push) feeds object+20. Not a general ABI decoder.
    """
    values = []
    for at in [earlier_push, later_push]:
        raw = image.read(at, 2)
        if raw[0] != 0x6a or raw[1] >= 128:
            raise ProbeError('encoding_constructor_push_form')
        values.append(raw[1])
    opcode = image.read(codepage_at, 1)[0]
    if opcode == 0xb9:
        cp = image.u32(codepage_at+1)
        cp_length = 5
    elif image.read(codepage_at, 2) == b'\x33\xc9':
        cp, cp_length = 0, 2
    else:
        raise ProbeError('encoding_constructor_codepage_form')
    return dict(status='inferred', codepage_argument=cp,
        decode_flags_argument=values[0], encode_flags_argument=values[1],
        earlier_push_reference=image.reference(earlier_push, 2),
        later_push_reference=image.reference(later_push, 2),
        codepage_reference=image.reference(codepage_at, cp_length),
        scope='Selected caller immediates plus reviewed EBP stack-to-field mapping, not original execution')


def native_bindings(program, source, imports):
    image = Image(program)
    classes = [minimal_class(image, vmt, name, slots) for vmt, name, slots in [
        (0x41443c, 'TUnicodeEncoding', [(24, 0x422924)]),
        (0x4145fc, 'TBigEndianUnicodeEncoding', [(24, 0x4229bc)]),
        (0x41427c, 'TUTF8Encoding', [(24, 0x422860)]),
        (0x413e38, 'TMBCSEncoding', [(12, 0x422744)])]]
    pointers = []
    for cell, vmt in [(0x4143e4, 0x41443c), (0x4145a4, 0x4145fc), (0x414224, 0x41427c), (0x413de0, 0x413e38)]:
        if image.u32(cell) != vmt:
            raise ProbeError('encoding_getter_class_pointer')
        pointers.append(dict(cell=hex(cell), target=hex(vmt), raw_bytes_reference=image.reference(cell, 4)))
    preambles = []
    specs = [('utf-16-le', 0x422927, b'\x6a\x02', [(0x422940, b'\xc6\x00\xff'), (0x422945, b'\xc6\x40\x01\xfe')]),
             ('utf-16-be', 0x4229bf, b'\x6a\x02', [(0x4229d8, b'\xc6\x00\xfe'), (0x4229dd, b'\xc6\x40\x01\xff')]),
             ('utf-8', 0x422863, b'\x6a\x03', [(0x42287c, b'\xc6\x00\xef'), (0x422881, b'\xc6\x40\x01\xbb'), (0x422887, b'\xc6\x40\x02\xbf')])]
    for codec, size_at, size_op, writes in specs:
        if image.read(size_at, len(size_op)) != size_op or any(image.read(at, len(raw)) != raw for at, raw in writes):
            raise ProbeError('encoding_preamble_write_identity')
        preambles.append(dict(codec=codec, status='inferred', size_argument_reference=image.reference(size_at, len(size_op)),
            byte_store_references=[image.reference(at, len(raw)) for at, raw in writes], actual_preamble='not_tested'))
    chains = []
    flag_fields = []
    for vmt, class_name, field_name, expected in [(0x432d50, 'TStringList', 'FCaseSensitive', 42),
            (0x562d00, 'TFastStringList', 'FNoneOptimize', 8)]:
        declaration = parse_class(image, vmt, 0, class_name)
        fields = [f for f in declaration['fields'] if f['name'] == field_name]
        if len(fields) != 1 or fields[0]['offset'] != expected:
            raise ProbeError('encoding_initial_flag_declaration')
        flag_fields.append(dict(class_name=class_name, name=field_name, offset=expected,
            raw_bytes_reference=fields[0]['raw_bytes_reference'], initial_value_candidate=0,
            initial_value_status='inferred', actual_live_value='not_tested'))
    for root in [0x432d50, 0x562d00]:
        vmt = root
        seen = set()
        chain = []
        while vmt:
            if len(seen) >= 8 or vmt in seen or image.u32(vmt-84) != 0:
                raise ProbeError('encoding_constructor_parent_chain_outside_scope')
            seen.add(vmt)
            name, _ = image.short(image.u32(vmt-56))
            cell = image.u32(vmt-48)
            chain.append(dict(name=name, vmt=hex(vmt), interface_reference=image.reference(vmt-84, 4),
                parent_pointer_reference=image.reference(vmt-48, 4),
                parent_cell_reference=image.reference(cell, 4) if cell else None))
            vmt = image.u32(cell) if cell else 0
        if image.u32(root-12) != 0x405690 or image.u32(root-28) != 0x4059f0 or image.read(0x4059f0, 1) != b'\xc3':
            raise ProbeError('encoding_allocation_or_post_constructor_identity')
        chains.append(dict(root=hex(root), chain=chain, allocation_reference=image.reference(root-12, 4),
            post_constructor_reference=image.reference(root-28, 4), empty_hook_reference=image.reference(0x4059f0, 1)))
    apis = [bind_import(image, imports, n, t, i) for n, t, i in [
        ('CompareStringW', 0x40c550, 0x71c264), ('MultiByteToWideChar', 0x40c864, 0x71c13c), ('GetCPInfo', 0x40c658, 0x71c204)]]
    field_uses = []
    for at, expected in [(0x422693, b'\x8b\x45\x0c\x89\x46\x10'),
            (0x422699, b'\x8b\x45\x08\x89\x46\x14'),
            (0x422752, b'\x8b\x50\x10'), (0x422756, b'\x8b\x40\x0c')]:
        if image.read(at, len(expected)) != expected:
            raise ProbeError('encoding_constructor_field_use_identity')
        field_uses.append(image.reference(at, len(expected)))
    arguments = dict(default=constructor_arguments(image, 0x422467, 0x422469, 0x42246b),
        utf8=constructor_arguments(image, 0x422826, 0x422828, 0x42282a))
    result = dict(status='inferred', classes=classes, getter_class_pointers=pointers, flag_declarations=flag_fields,
        constructor_arguments=arguments, constructor_field_use_references=field_uses,
        preamble_candidates=preambles, ordinary_constructor_chains=chains, selected_imports=apis,
        import_evidence_id=imports['evidence_id'],
        full_import_coverage='verified' if imports['normalized_result']['coverage']['status'] == 'complete' else 'unsupported',
        import_issues=imports['normalized_result']['issues'],
        initial_case_and_optimization_flags='inferred', later_flag_mutations='not_tested',
        windows_locale_value=1024, windows_default_codepage_argument=0,
        actual_windows_locale='not_tested', actual_windows_codepage='not_tested',
        scope='Selected fixed-source byte bindings and ordinary-constructor hypothesis only; no Windows NLS emulation')
    source_sha = digest(program)
    def identity(value):
        if isinstance(value, dict):
            if {'offset', 'length', 'sha256'} <= value.keys():
                value.update(source_file=source, source_sha256=source_sha)
            for child in list(value.values()):
                identity(child)
        elif isinstance(value, list):
            for child in value:
                identity(child)
    identity(result)
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--game-dir', type=Path, required=True)
    p.add_argument('--exe', required=True)
    p.add_argument('--assets-dir', type=Path, required=True)
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument('--all-corpus', action='store_true')
    group.add_argument('--source-file', action='append')
    p.add_argument('--imports-evidence', type=Path, required=True)
    p.add_argument('--output', type=Path, default=ROOT/'reports/p1/encoding-audit-report.json')
    args = p.parse_args()
    safe_output = False
    try:
        game, assets, output, imports_path = map(absolute, [args.game_dir, args.assets_dir, args.output, args.imports_evidence])
        if ROOT/'reports/p1' not in output.parents or ROOT/'private' not in imports_path.parents:
            raise ProbeError('encoding_report_locations')
        for source in [game, assets]:
            if source == output or source in output.parents or output in source.parents:
                raise ProbeError('encoding_input_output_overlap')
        safe_output = True
        native_bytes = read_bounded(ROOT/'reports/p1/encoding-native-report.json')
        native = json.loads(native_bytes)
        required = {'encoding_nil_priority', 'default_zero_codepage', 'mbcs_decode_arguments',
            'compare_sensitive_flags', 'compare_insensitive_flags', 'instance_zero_fill'}
        if native.get('errors') or native.get('independent_collection', {}).get('status') != 'verified' or not required <= {
            r['id'] for r in native['observations'] if r['status'] == 'verified'}:
            raise ProbeError('encoding_native_facts_missing')
        source = safe_member_name(args.exe)
        program = read_bounded(game/source)
        inventory = json.loads(read_bounded(ROOT/'reports/p0/inventory.json'))
        if digest(program) != native['source_sha256'] or not any(r['path'] == source and r.get('sha256') == digest(program) for r in inventory['files']):
            raise ProbeError('encoding_program_identity')
        import_bytes = read_bounded(imports_path, 4*1024*1024)
        imports = json.loads(import_bytes)
        if 'ok' in imports:
            if not imports['ok']:
                raise ProbeError('encoding_import_collection_failed')
            imports = imports['data']
        corpus_bytes = read_bounded(ROOT/'reports/p1/corpus-report.json')
        with processing_deadline(120):
            bindings = native_bindings(program, source, imports)
            report = audit_corpus(assets, json.loads(corpus_bytes)['items'], args.source_file)
        if digest(read_bounded(game/source)) != digest(program):
            raise ProbeError('encoding_program_changed_during_probe')
        report.update(schema_version=1, dataset='real', native_bindings=bindings,
            source_file=source, source_sha256=digest(program),
            selection='all_locked_corpus' if args.all_corpus else 'explicit_source_files',
            producer=dict(python=platform.python_version(), tool='tools/encoding_audit.py',
                tool_sha256=digest(read_bounded(ROOT/'tools/encoding_audit.py'))),
            native_report='reports/p1/encoding-native-report.json', native_report_sha256=digest(native_bytes),
            corpus_report_sha256=digest(corpus_bytes), imports_evidence_sha256=digest(import_bytes),
            original_files_written=False, external_game_data_uploads=False, commercial_text_in_public_reports=False,
            runtime_development_ready=False, full_native_port='not_tested', execution_semantics='not_tested')
        write_json(output, report)
        print(json.dumps({k: report[k] for k in ['status', 'physical_files', 'cp932_cp936_disagreement_count',
            'different_bytes_exact_model_text_equal', 'different_bytes_exact_model_text_different']}))
        return 2 if report['status'] == 'unsupported' else 0
    except (OSError, ValueError, KeyError, TimeoutError) as exc:
        report = dict(status='unsupported', schema_version=1, scope='Failed encoding audit; no partial compatibility result',
            errors=[dict(category=type(exc).__name__, code=str(exc) if isinstance(exc, ProbeError) else type(exc).__name__)],
            original_files_written=False, execution_semantics='not_tested')
        print(json.dumps(report))
        if safe_output:
            write_json(output, report)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
