#!/usr/bin/env python3
"""Project Mangekyou P0: bounded, read-only local inventory and probes."""
import argparse
from collections import Counter, defaultdict
import hashlib
import io
import json
import os
from pathlib import Path, PureWindowsPath
import re
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
STATUSES = ['verified', 'inferred', 'unsupported', 'not_tested']
MAX_BYTES = 64 * 1024 * 1024
MAX_PIXELS = 16_000_000
MAX_RECORDS = 100_000
MAX_ENTRIES = 100_000
MAX_INDEX = 32 * 1024 * 1024
VERSIONS = {'FilePackVer1.0', 'FilePackVer2.0', 'FilePackVer3.0', 'FilePackVer3.1'}


class ProbeError(ValueError):
    pass


def error(category, detail, **kwargs):
    return dict(category=category, detail=str(detail), **kwargs)


def absolute(path):
    return Path(os.path.abspath(os.path.expanduser(str(path))))


def safe_open(path, directory=False):
    """Open every component with O_NOFOLLOW, including all parent dirs."""
    path = absolute(path)
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for index, part in enumerate(path.parts[1:]):
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if index < len(path.parts[1:]) - 1 or directory:
                flags |= os.O_DIRECTORY
            next_fd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        kind = os.fstat(fd).st_mode
        if not (stat.S_ISDIR(kind) if directory else stat.S_ISREG(kind)):
            raise ProbeError('input is not a regular file/directory')
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_bounded(path, limit=MAX_BYTES):
    with os.fdopen(safe_open(path), 'rb') as stream:
        if os.fstat(stream.fileno()).st_size > limit:
            raise ProbeError('size_limit')
        data = stream.read(limit + 1)
        if len(data) > limit:
            raise ProbeError('size_limit')
        return data


def safe_member_name(name):
    """Validation only. No extraction API is provided."""
    normalized = name.replace('\\', '/')
    parts = normalized.split('/')
    if (not name or '\x00' in name or PureWindowsPath(name).drive or normalized.startswith('/')
            or any(p in {'', '.', '..'} or ':' in p or p.endswith((' ', '.')) for p in parts)):
        raise ProbeError('unsafe_member_path')
    return normalized


def collision_key(name):
    return unicodedata.normalize('NFC', safe_member_name(name)).casefold()


def footer_probe(tail, size):
    if size < 28 or len(tail) != 28:
        raise ProbeError('short_footer')
    signature, count, offset = struct.unpack('<16sIQ', tail)
    if not signature.startswith(b'FilePackVer'):
        raise ProbeError('signature_not_found')
    version = signature.rstrip(b'\0').decode('ascii', errors='strict')
    result = dict(version=version, declared_entry_count=count, table_offset=offset,
                  footer_offset=size - 28, signature_status='verified',
                  index_status='not_tested', content_status='not_tested')
    if version not in VERSIONS:
        raise ProbeError('unsupported_version:' + version)
    if offset >= size - 28:
        raise ProbeError('invalid_table_offset')
    if count > MAX_ENTRIES or size - 28 - offset > MAX_INDEX:
        raise ProbeError('index_limit')
    if version == 'FilePackVer3.1' and size < 1088:
        raise ProbeError('short_v31_key_trailer')
    return result


def signature(data):
    pairs = [(b'\x89PNG\r\n\x1a\n', 'PNG'), (b'DPNG', 'DPNG'),
             (b'\xff\xd8\xff', 'JPEG'), (b'GIF87a', 'GIF'), (b'GIF89a', 'GIF'),
             (b'BM', 'BMP'), (b'ARGBSaveData1', 'ARGB'), (b'OggS', 'Ogg'), (b'fLaC', 'FLAC'),
             (b'ID3', 'MP3-ID3'), (b'MZ', 'PE-candidate'),
             (b'OTTO', 'OpenType'), (b'\x00\x01\x00\x00', 'TrueType-candidate'),
             (b'ttcf', 'TTC'), (b'1PC\xff', 'QLIE-BPE'),
             (b'abmp', 'ABMP-candidate'), (b'IMOAVI', 'IMOAVI-candidate')]
    for magic, kind in pairs:
        if data.startswith(magic):
            return kind
    if len(data) >= 12 and data[:4] == b'RIFF':
        return {b'WAVE': 'WAVE', b'AVI ': 'AVI', b'WEBP': 'WebP'}.get(data[8:12], 'RIFF-unknown')
    if len(data) >= 12 and data[4:8] == b'ftyp':
        return 'ISO-BMFF'
    return 'Unknown'


def inventory(root):
    files, errors = [], []
    def visit(folder_fd, relative):
        if len(relative.parts) > 64:
            errors.append(error('directory_depth_limit', relative.as_posix()))
            return
        try:
            with os.scandir(folder_fd) as entries:
                names = sorted(e.name for e in entries)
            for name in names:
                rel = relative / name
                try:
                    info = os.stat(name, dir_fd=folder_fd, follow_symlinks=False)
                    if stat.S_ISLNK(info.st_mode):
                        errors.append(error('symlink_rejected', rel.as_posix()))
                    elif stat.S_ISDIR(info.st_mode):
                        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=folder_fd)
                        try:
                            visit(fd, rel)
                        finally:
                            os.close(fd)
                    elif stat.S_ISREG(info.st_mode):
                        if len(files) >= MAX_RECORDS:
                            raise ProbeError('inventory_file_limit')
                        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=folder_fd)
                        with os.fdopen(fd, 'rb') as stream:
                            current = os.fstat(stream.fileno())
                            if not stat.S_ISREG(current.st_mode):
                                raise ProbeError('file_changed_type')
                            size = current.st_size
                            head = stream.read(64)
                            stream.seek(max(0, size - 28))
                            tail = stream.read(28)
                            pack = tail.startswith(b'FilePackVer') or rel.suffix.lower() == '.pack'
                            record = dict(path=rel.as_posix(), size=size, extension=rel.suffix.lower(),
                                          signature_hex=head[:32].hex(), signature_type=signature(head),
                                          archive_candidate=pack, status='verified')
                            if head.startswith(b'MZ') and len(head)>=64:
                                pe_offset=struct.unpack_from('<I',head,60)[0]
                                if 0<=pe_offset<=min(size-24,1024*1024):
                                    stream.seek(pe_offset);pe=stream.read(24)
                                    if pe[:4]==b'PE\0\0':
                                        record['pe_metadata']=dict(status='verified',header_offset=pe_offset,
                                            machine=hex(struct.unpack_from('<H',pe,4)[0]),
                                            coff_timestamp=struct.unpack_from('<I',pe,8)[0],timestamp_trusted=False,
                                            resource_version_status='not_tested')
                            if rel.name.lower()=='version.txt' and size<=65536:
                                stream.seek(0);version_raw=stream.read(65537)
                                encoding='utf-16' if version_raw.startswith((b'\xff\xfe',b'\xfe\xff')) else 'cp932'
                                try:
                                    version_text=version_raw.decode(encoding,errors='strict')
                                    record['version_clues']=dict(status='verified',encoding=encoding,
                                        fields={k:v for line in version_text.splitlines() if '=' in line
                                                for k,v in [line.split('=',1)] if k in {'product','version'}},
                                        authenticity='not_tested')
                                except UnicodeError as exc:
                                    record['version_clues']=dict(status='unsupported',reason=str(exc))
                            if pack or rel.suffix.lower() in {'.exe', '.dll', '.fkey', '.key'}:
                                stream.seek(0)
                                digest = hashlib.sha256()
                                for block in iter(lambda: stream.read(1024 * 1024), b''):
                                    digest.update(block)
                                record['sha256'] = digest.hexdigest()
                            if current != os.fstat(stream.fileno()):
                                # atime can change from our read; compare only content metadata.
                                after = os.fstat(stream.fileno())
                                if (current.st_size, current.st_mtime_ns, current.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
                                    raise ProbeError('input_changed_during_read')
                            if pack:
                                record['footer_hex'] = tail.hex()
                            files.append(record)
                    else:
                        errors.append(error('special_file_rejected', rel.as_posix()))
                except (OSError, ValueError) as exc:
                    errors.append(error('inventory_error', exc, path=rel.as_posix()))
                    if str(exc) == 'inventory_file_limit':
                        return
        except OSError as exc:
            errors.append(error('directory_error', exc, path=relative.as_posix()))
    fd = safe_open(root, directory=True)
    try:
        visit(fd, Path())
    finally:
        os.close(fd)
    return dict(status='verified' if not errors else 'unsupported', files=files, errors=errors,
                file_count=len(files), total_bytes=sum(f['size'] for f in files),
                extensions=dict(Counter(f['extension'] for f in files)),
                limitations=['No RT_VERSION/product edition decoding', 'No unknown executable is run'])


def dpng_metadata(data):
    if len(data) < 20 or data[:4] != b'DPNG':
        raise ProbeError('truncated_or_invalid_dpng_header')
    unknown, count, width, height = struct.unpack_from('<IIII', data, 4)
    if not width or not height or width * height > MAX_PIXELS:
        raise ProbeError('pixel_limit_or_zero_dimension')
    if count > MAX_ENTRIES or count * 28 > len(data) - 20:
        raise ProbeError('invalid_tile_count')
    pos, tiles = 20, []
    for index in range(count):
        if pos + 28 > len(data):
            raise ProbeError('truncated_tile_header')
        start = pos
        x, y, w, h, size, u1, u2 = struct.unpack_from('<7I', data, pos)
        pos += 28
        if x + w > width or y + h > height or pos + size > len(data):
            raise ProbeError('tile_bounds_or_length')
        if size and (not w or not h or not data[pos:pos + size].startswith(b'\x89PNG\r\n\x1a\n')):
            raise ProbeError('invalid_tile_png')
        tiles.append(dict(index=index, byte_offset=start, x=x, y=y, width=w, height=h,
                          length=size, unknown_fields=[u1, u2]))
        pos += size
    if pos != len(data):
        raise ProbeError('dpng_trailing_data')
    return dict(width=width, height=height, unknown_header=unknown, tiles=tiles,
                metadata_status='verified', conversion_status='not_tested',
                blend_semantics_status='not_tested')


def inspect_asset(path, rel, use_ffprobe=False):
    result = dict(path=rel, status='unsupported', errors=[])
    try:
        data = read_bounded(path)
        kind = signature(data)
        result['format'] = kind
        result['sha256'] = hashlib.sha256(data).hexdigest()
        if kind == 'Unknown' and Path(rel).suffix.lower() == '.txt':
            encoding = 'utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else ('utf-8-sig' if data.startswith(b'\xef\xbb\xbf') else 'cp932')
            text = data.decode(encoding, errors='strict')
            if '\x00' in text or any(ord(c)<32 and c not in '\r\n\t' for c in text):
                raise ProbeError('text_has_binary_controls')
            result.update(format='Text', status='verified', encoding=encoding,
                encoding_status='verified' if data.startswith((b'\xff\xfe',b'\xfe\xff',b'\xef\xbb\xbf')) else 'inferred',
                text_role='Unknown', line_count=len(text.splitlines()))
        elif kind == 'DPNG':
            result.update(dpng_metadata(data))
            result['status'] = 'verified'
        elif kind in {'PNG', 'JPEG', 'BMP', 'GIF', 'WebP'}:
            if kind == 'PNG' and len(data) >= 33 and data[12:16] == b'IHDR':
                w, h, depth, color = struct.unpack_from('>IIBB', data, 16)
                result.update(width=w, height=h, bit_depth=depth, png_color_type=color,
                              channels={0:1, 2:3, 3:1, 4:2, 6:4}.get(color),
                              alpha_channel=color in {4, 6}, metadata_status='verified')
                if w * h > MAX_PIXELS or not w or not h:
                    raise ProbeError('pixel_limit_or_zero_dimension')
            try:
                from PIL import Image
                Image.MAX_IMAGE_PIXELS = MAX_PIXELS
                import warnings
                with warnings.catch_warnings():
                    warnings.simplefilter('error', Image.DecompressionBombWarning)
                    with Image.open(io.BytesIO(data)) as im:
                        if im.width * im.height > MAX_PIXELS:
                            raise ProbeError('pixel_limit')
                        im.load()
                        rgba = im.convert('RGBA')
                        result.update(width=im.width, height=im.height, mode=im.mode,
                                      channels=len(im.getbands()), alpha_channel='A' in im.getbands() or 'transparency' in im.info,
                                      alpha_extrema=list(rgba.getextrema()[3]), decode_status='verified', status='verified')
            except ImportError:
                result.update(decode_status='not_tested', status='inferred')
                result['errors'].append(error('dependency_missing', 'Pillow'))
            except (Image.DecompressionBombWarning, Image.DecompressionBombError) as exc:
                raise ProbeError('pixel_limit:' + str(exc))
        elif kind in {'WAVE', 'Ogg', 'FLAC', 'MP3-ID3', 'AVI', 'ISO-BMFF'}:
            result.update(status='verified', signature_status='verified', codec_status='not_tested')
            if use_ffprobe:
                # No URLs or network protocols. Keep the validated inode open via stdin.
                proc = subprocess.run(['ffprobe', '-v', 'error', '-protocol_whitelist', 'pipe',
                    '-show_entries', 'format=format_name,duration:stream=codec_name,codec_type,width,height,sample_rate,channels',
                    '-of', 'json', '-i', 'pipe:0'], input=data, capture_output=True, timeout=15)
                if proc.returncode:
                    raise ProbeError('ffprobe_failed:' + proc.stderr.decode('utf-8', 'replace')[:500])
                result.update(media=json.loads(proc.stdout), codec_status='verified')
        elif kind in {'OpenType', 'TrueType-candidate', 'TTC', 'PE-candidate'}:
            result['status'] = 'inferred'
            result['unknown_reason'] = 'signature only; font tables / PE resource versions not decoded'
        else:
            result['unknown_reason'] = 'no supported decoder; extension is not evidence'
    except (OSError, ValueError, struct.error, subprocess.SubprocessError) as exc:
        result['errors'].append(error('asset_probe_error', exc))
        result['status'] = 'unsupported'
    return result


def tokenize_tag(text):
    """Conservative lexical fields, without execution or expression semantics."""
    fields, current, quoted = [], [], False
    for char in text:
        if char == '"':
            quoted = not quoted
        if char == ',' and not quoted:
            fields.append(''.join(current))
            current = []
        else:
            current.append(char)
    if quoted:
        raise ProbeError('unclosed_quote')
    fields.append(''.join(current))
    return fields


def script_probe(data, source_file, include_text=False):
    digest = hashlib.sha256(data).hexdigest()
    result = dict(source_file=source_file, sha256=digest, status='inferred', errors=[], records=[],
                  levels=dict(dialogue_extraction='not_tested', physical_order='not_tested',
                              control_structure='unsupported', execution_semantics='unsupported'))
    encoding, bom = 'cp932', 0
    for marker, codec in [(b'\xff\xfe', 'utf-16-le'), (b'\xfe\xff', 'utf-16-be'), (b'\xef\xbb\xbf', 'utf-8')]:
        if data.startswith(marker):
            encoding, bom = codec, len(marker)
            break
    result.update(encoding=encoding, encoding_status='verified' if bom else 'inferred', bom_size=bom,
                  format_version=None, version_status='not_tested')
    try:
        # Split original byte units, not re-encoded text: CP932 aliases need not roundtrip.
        unit = 2 if encoding.startswith('utf-16') else 1
        if (len(data) - bom) % unit:
            raise ProbeError('odd_utf16_length')
        newline = '\n'.encode(encoding)
        boundaries = [bom]
        for pos in range(bom, len(data), unit):
            if data[pos:pos + unit] == newline:
                boundaries.append(pos + unit)
        if boundaries[-1] != len(data):
            boundaries.append(len(data))
        if len(boundaries) > MAX_RECORDS + 1:
            raise ProbeError('script_record_limit')
        for number, (start, end) in enumerate(zip(boundaries, boundaries[1:]), 1):
            raw = data[start:end]
            decoded = raw.decode(encoding, errors='strict')
            if '\x00' in decoded or any(ord(c) < 32 and c not in '\r\n\t' for c in decoded):
                raise ProbeError('binary_or_control_bytes')
            line = decoded.rstrip('\r\n').strip()
            kind, operand_fields, token, reason = 'text_candidate', [], None, 'dialogue vs macro text unverified'
            if not line:
                kind, reason = 'empty', None
            elif line.startswith('@@@'):
                kind, operand_fields, reason = 'include_candidate', [line[3:]], 'include execution / resolution unverified'
            elif line.startswith('@@'):
                kind, operand_fields, reason = 'label_candidate', [line[2:]], 'label scope unverified'
            elif line.startswith(('^', '\\')):
                kind = 'line_tag' if line[0] == '^' else 'command'
                try:
                    fields = tokenize_tag(line[1:])
                    token, operand_fields = fields[0], fields[1:]
                    reason = 'unknown command semantics; operands are lexical only'
                except ProbeError as exc:
                    kind, reason = 'unknown_record', str(exc)
                    result['errors'].append(error('script_lexical_error', exc, byte_offset=start))
            elif line.startswith('【') and line.endswith('】'):
                kind, reason = 'name_candidate', 'association with following dialogue unverified'
            elif line.startswith('％'):
                kind, operand_fields, reason = 'sound_candidate', [line[1:]], 'sound role and filename mapping unverified'
            elif line.startswith('//'):
                kind, reason = 'comment_candidate', 'comment semantics not confirmed for fourth game'
            record = dict(source_file=source_file, byte_offset=start, byte_length=end-start, line_number=number,
                          line_count=1,
                          record_type=kind, raw_bytes_reference=dict(source_sha256=digest, offset=start, length=end-start,
                          sha256=hashlib.sha256(raw).hexdigest()), decoded_text=decoded if include_text else None,
                          text_redacted=not include_text, decoded_text_sha256=hashlib.sha256(decoded.encode()).hexdigest(),
                          token=token, operands=[dict(value=v if include_text else None,
                          sha256=hashlib.sha256(v.encode()).hexdigest()) for v in operand_fields],
                          confidence='inferred', unknown_reason=reason)
            # Only literal path spelling is recorded. No guessed opcode-to-role mapping.
            literals = []
            candidates = operand_fields if kind != 'text_candidate' else []
            for candidate in candidates:
                value = candidate.strip('"')
                if re.fullmatch(r'[^\s,"<>|]+\.(?:png|jpg|jpeg|bmp|ogg|wav|mp3|flac|avi|mp4|b|s)', value, re.I):
                    # Script-relative ../ is data, not an extraction destination. Never open it.
                    if '\x00' not in value and not PureWindowsPath(value).drive and not value.startswith(('/', '\\\\')):
                        literals.append(value.replace('\\', '/'))
                    else:
                        result['errors'].append(error('unsafe_reference', 'absolute reference not resolved', byte_offset=start))
            record['literal_references'] = literals
            if kind == 'empty' and result['records'] and result['records'][-1]['record_type'] in {'empty','empty_span'}:
                previous=result['records'][-1]
                previous.update(record_type='empty_span', byte_length=end-previous['byte_offset'],
                    line_count=previous['line_count']+1, decoded_text=None, text_redacted=True)
                previous['raw_bytes_reference']['length']=previous['byte_length']
            else:
                result['records'].append(record)
        for record in result['records']:
            if record['record_type']=='empty_span':
                raw=data[record['byte_offset']:record['byte_offset']+record['byte_length']]
                record['raw_bytes_reference']['sha256']=hashlib.sha256(raw).hexdigest()
                record['decoded_text_sha256']=hashlib.sha256(raw.decode(encoding).encode()).hexdigest()
        result['physical_line_count']=sum(r['line_count'] for r in result['records'])
        result['levels']['physical_order'] = 'verified'
        result['unknown_record_count'] = sum(r['unknown_reason'] is not None for r in result['records'])
    except (UnicodeError, ValueError) as exc:
        result.update(status='unsupported')
        result['errors'].append(error('script_decode_error', exc))
        # Whole original file remains addressable even when no record boundary is known.
        result['unparsed_reference'] = dict(source_sha256=digest, offset=0, length=len(data))
    return result


def reference_graph(scripts, resource_names):
    import posixpath
    exact = defaultdict(list)
    folded = defaultdict(list)
    for name in resource_names:
        try:
            normalized = safe_member_name(name)
            if normalized.split('/')[0].endswith('.pack'):
                normalized=normalized.split('/',1)[1]
            exact[normalized].append(name)
            folded[collision_key(normalized)].append(name)
        except ProbeError:
            continue
    edges = []
    for script in scripts:
        for record in script.get('records', []):
            for literal in record['literal_references']:
                member=script['source_file'].replace('\\','/')
                if member.split('/')[0].endswith('.pack'):
                    member=member.split('/',1)[1]
                relative=posixpath.normpath(posixpath.join(posixpath.dirname(member),literal))
                lookups=[p for p in dict.fromkeys([literal,relative]) if not p.startswith('../') and p!='..']
                matches = list(dict.fromkeys(n for p in lookups for n in exact.get(p,[])))
                method = 'exact_literal'
                if not matches:
                    matches=list(dict.fromkeys(n for p in lookups for n in folded.get(collision_key(p),[])))
                    method='casefold_candidate'
                if len(matches)>1:
                    method='ambiguous_archive_or_base'
                edges.append(dict(source_file=script['source_file'], byte_offset=record['byte_offset'],
                    record_sha256=record['raw_bytes_reference']['sha256'], literal=literal, candidates=matches,
                    lookup_candidates=lookups,
                    relationship_type='Unknown', match_method=method,
                    status='verified' if method == 'exact_literal' and len(matches) == 1 else 'inferred',
                    unknown_reason='literal equality is not a resolved runtime resource identifier'))
    return dict(status='inferred' if edges else 'not_tested', edges=edges,
                required_roles={k:'not_tested' for k in ['background', 'sprite', 'voice', 'bgm', 'sfx', 'animation']})


def upstream_call(source, operation, path):
    command = [sys.executable, str(ROOT / 'tools/upstream_worker.py'), '--source', str(absolute(source)),
               '--operation', operation, '--input', str(absolute(path))]
    try:
        proc = subprocess.run(command, capture_output=True, timeout=25)
        if proc.returncode:
            return dict(status='unsupported', errors=[error('upstream_worker_failed', proc.stderr.decode('utf-8', 'replace')[-1000:])])
        return json.loads(proc.stdout)
    except (subprocess.SubprocessError, ValueError) as exc:
        return dict(status='unsupported', errors=[error('upstream_worker_error', exc)])


def archive_probe(root, item, upstream=None):
    result = dict(path=item['path'], sha256=item.get('sha256'), status='unsupported', errors=[],
                  enumerated_resource_count=None, content_status='not_tested')
    try:
        result.update(footer_probe(bytes.fromhex(item['footer_hex']), item['size']))
        result['status'] = 'verified'
        if upstream:
            parsed = upstream_call(upstream, 'index', root / item['path'])
            result['index'] = parsed
            result['index_status'] = parsed['status']
            result['enumerated_resource_count'] = len(parsed.get('entries', [])) if parsed['status'] == 'verified' else None
            result['errors'].extend(parsed.get('errors', []))
        else:
            result['blocking_reason'] = 'index_not_tested: no --upstream-source supplied'
    except (UnicodeError, ValueError, KeyError) as exc:
        result['errors'].append(error('archive_footer_error', exc))
    return result


def report_summary(items, missing_reason):
    errors = [dict(item_path=i.get('path', i.get('source_file')), **e) for i in items for e in i.get('errors', [])]
    status = 'not_tested' if not items else ('unsupported' if errors or any(i.get('status') == 'unsupported' for i in items)
              else ('verified' if all(i.get('status') == 'verified' for i in items) else 'inferred'))
    return dict(status=status,
                items=items, errors=errors, error_count=len(errors),
                errors_by_category=dict(Counter(e['category'] for e in errors)),
                unknown_count=sum(i.get('status') == 'unsupported' for i in items),
                missing_reason=None if items else missing_reason)


def write_json(path, data):
    path = absolute(path)
    # Validate existing ancestors before mkdir, then open the created dir safely.
    for parent in [path] + list(path.parents):
        if parent.is_symlink():
            raise ProbeError('symlink output refused')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = safe_open(path.parent, directory=True)
    try:
        temporary = '.p0-' + os.urandom(12).hex() + '.tmp'
        out_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        try:
            with os.fdopen(out_fd, 'w', encoding='utf-8') as stream:
                json.dump(data, stream, indent=2, ensure_ascii=False)
                stream.write('\n')
            os.replace(temporary, path.name, src_dir_fd=fd, dst_dir_fd=fd)
        finally:
            try:
                os.unlink(temporary, dir_fd=fd)
            except FileNotFoundError:
                pass
    finally:
        os.close(fd)


def run(game_dir=None, assets_dir=None, output=None, upstream=None, ffprobe=False, dataset='real'):
    output = absolute(output or ROOT / 'reports/p0')
    roots = [absolute(p) for p in (game_dir, assets_dir) if p is not None]
    for root in roots:
        if output == root or root in output.parents or output in root.parents:
            raise ProbeError('input/output trees must not overlap')
        fd = safe_open(root, directory=True)
        os.close(fd)
    if roots and output == ROOT / 'reports/p0' and dataset != 'synthetic':
        raise ProbeError('real reports must use --output private/<run> (baseline is sanitized)')
    provenance = dict(schema_version=1, dataset='absent' if not roots else dataset,
                      real_game_status='not_tested' if not roots or dataset == 'synthetic' else 'inferred',
                      evidence_status_values=STATUSES, original_files_written=False,
                      note='directory identity and fourth-game edition require human confirmation')
    inv = inventory(absolute(game_dir)) if game_dir else dict(status='not_tested', file_count=None,
          total_bytes=None, files=[], errors=[], missing_reason='No legal game data supplied; user preparing resources')
    archives = [archive_probe(absolute(game_dir), item, upstream) for item in inv['files'] if item['archive_candidate']]
    asset_inv = inventory(absolute(assets_dir)) if assets_dir else dict(files=[], errors=[], status='not_tested')
    assets, scripts = [], []
    for item in asset_inv['files']:
        path = absolute(assets_dir) / item['path']
        if item['extension'] == '.s':
            try:
                scripts.append(script_probe(read_bounded(path), item['path'], include_text=dataset == 'synthetic'))
            except (OSError, ValueError) as exc:
                scripts.append(dict(source_file=item['path'], status='unsupported', errors=[error('script_read_error', exc)]))
        else:
            asset = inspect_asset(path, item['path'], ffprobe)
            if asset.get('format') == 'DPNG' and upstream and asset['status'] == 'verified':
                asset['upstream_conversion'] = upstream_call(upstream, 'dpng', path)
            assets.append(asset)
    ars = report_summary(archives, 'No actual PACK files accessible')
    ars['enumerated_resource_count'] = sum(a['enumerated_resource_count'] or 0 for a in archives) if archives else None
    ars['unknown_archive_count'] = sum(bool(a['errors']) for a in archives)
    ass = report_summary(assets, 'No legally extracted asset copies supplied')
    ass['inventory_errors'] = asset_inv['errors']
    ass['errors'].extend(asset_inv['errors'])
    ass['error_count'] = len(ass['errors'])
    ass['errors_by_category'] = dict(Counter(e['category'] for e in ass['errors']))
    if ass['errors']:
        ass['status'] = 'unsupported'
    ass['format_counts'] = dict(Counter(a.get('format', 'Unreadable') for a in assets))
    ss = report_summary(scripts, 'No real .s or other script carrier supplied')
    ss['semantic_status'] = 'unsupported'
    ss['levels'] = dict(dialogue_extraction='not_tested', physical_order='verified' if scripts and all(s.get('levels', {}).get('physical_order') == 'verified' for s in scripts) else 'not_tested',
                        control_structure='unsupported', execution_semantics='unsupported')
    registry=[Path(a['path']).name+'/'+e['name'].replace('\\','/') for a in archives for e in a.get('index',{}).get('entries',[])]
    graph = reference_graph(scripts, registry or [f['path'] for f in asset_inv['files']])
    comp = dict(status='inferred', p0_scope='static_research_only', p0_fully_passed=False,
                recommendation='P1 evidence acquisition and static script corpus only; no runtime yet',
                real_game_compatibility='not_tested', runtime_compatibility='not_tested',
                blockers=['No authenticated fourth-game corpus' if not roots or dataset == 'synthetic' else 'Fourth-game edition and corpus coverage unconfirmed',
                          'Control flow, variable model, effects and save semantics unverified',
                          'qlie-unpack has no explicit license at pinned commit'],
                unsupported=['Script execution', 'PACK extraction', 'Repacking', 'Game launch', 'Save/load emulation'])
    reports = {'inventory.json':inv, 'archive-report.json':ars, 'asset-report.json':ass,
               'script-report.json':ss, 'reference-graph.json':graph, 'compatibility-report.json':comp}
    for name, body in reports.items():
        write_json(output / name, dict(**provenance, **body))
    return reports


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--game-dir', type=Path, help='Read-only original game tree; never executed')
    ap.add_argument('--assets-dir', type=Path, help='Existing legally extracted copies; no extraction is performed')
    ap.add_argument('--output', type=Path, default=ROOT / 'reports/p0')
    ap.add_argument('--upstream-source', type=Path, help='Pinned qlie-unpack source root from fetch_sources.py')
    ap.add_argument('--probe-media', action='store_true', help='Optional local ffprobe, bounded input and timeout')
    args = ap.parse_args()
    try:
        reports = run(args.game_dir, args.assets_dir, args.output, args.upstream_source, args.probe_media)
        failures = sum(len(r.get('errors', [])) for r in reports.values())
        print(json.dumps(dict(output=str(absolute(args.output)), reports=len(reports), errors=failures, real_game='not_tested' if not args.game_dir else 'inferred'), ensure_ascii=False))
        return 2 if failures else 0
    except (OSError, ValueError) as exc:
        print(json.dumps(error('run_refused', exc), ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
