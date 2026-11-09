#!/usr/bin/env python3
"""Decode script, UTF-16 table PNG and Ogg video overlays from the verified fourth-game BOXFILE samples."""
import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import tempfile
import zlib

from mangekyou_p0 import ROOT, ProbeError, absolute, collision_key, safe_member_name, safe_open
from pe_probe import MAX_PE, pe32, read_bounded

LOADER_SHA = "8bca87f6871f53a6e37f12e72e12faea7f2138c4fab3aefa496c062050b1185f"
SUPPORTED_CN = {
    "47cae339c103fc890ac273d0756c0b75f35739453a52d06d391dcb5286823d95",
    "cc1fbde7c4bc9d571042945c09f5ab61a7a1ffcc493158f1c582d5b983e352ab",
}


def require(condition, reason):
    if not condition:
        raise ProbeError(reason)


def loader_transform(path):
    data = read_bounded(path, MAX_PE)
    require(hashlib.sha256(data).hexdigest() == LOADER_SHA, "unsupported_loader_sha256")
    pe = pe32(data)
    section = next(row for row in pe['sections'] if row['name'] == '.adata')
    start = 0x7d2332
    offset = section['raw_offset'] + start - pe['image_base'] - section['rva']
    state = start
    first = (offset + 12) & ~3
    end = section['raw_offset'] + section['raw_size']
    mapped = bytearray(data)
    for pos in range(first, end, 4):
        state = (state * 0x19660d + 0x3c6ef375) & 0xffffffff
        word = struct.unpack_from('<I', data, pos)[0]
        struct.pack_into('<I', mapped, pos, state ^ word)
    expected, length, checksum = struct.unpack_from('<III', mapped, offset)
    require(0 < length <= 65536 and 0 < expected <= 1024 * 1024, "loader_size")
    require(offset + 12 + length <= end, "loader_range")
    decoded = mapped[offset + 12:offset + 12 + length]

    window = bytearray(b' ' * 4078 + b'\0' * 18)
    cursor = 4078
    index = 0
    output = bytearray()
    while index < length:
        flags = decoded[index]
        index += 1
        for bit in range(8):
            if index == length:
                break
            if flags & (1 << bit):
                values = (decoded[index],)
                index += 1
            else:
                if index + 1 == length:
                    index = length
                    break
                lo, hi = decoded[index:index + 2]
                index += 2
                position = lo | ((hi & 0xf0) << 4)
                values = (window[(position + delta) & 0xfff] for delta in range((hi & 15) + 3))
            for value in values:
                if len(output) < expected:
                    output.append(value)
                window[cursor] = value
                cursor = (cursor + 1) & 0xfff
    require(len(output) == expected, "loader_output_length")
    actual = zlib.adler32(output, 0)
    require(actual == checksum, "loader_checksum")
    def from_va(address, size):
        off = offset + address - start
        if address >= start:
            return output[off-offset:off-offset+size]
        return data[off:off+size]

    table = from_va(0x7d114c, 256)
    config = bytearray(from_va(0x7d22de, 64))
    key = from_va(0x7d22de+0x71, 15)
    def transform(buf, schedule):
        for pos in range(0,len(buf),8):
            k=0
            for round_index in range(9):
                for j in range(4):
                    buf[pos+4+j] ^= table[buf[pos+j] ^ schedule[k]]
                    k+=1
                if round_index == 8:
                    break
                buf[pos+1] ^= table[buf[pos+4] ^ schedule[k]]
                buf[pos+2] ^= table[buf[pos+5] ^ buf[pos+4]]
                buf[pos+3] ^= table[buf[pos+6] ^ schedule[k+1]]
                buf[pos] ^= table[buf[pos+7] ^ schedule[k+2]]
                k+=3
    transform(config, key * 4)
    config[:] = bytes(a ^ b for a,b in zip(config, b"\x37" + config[:-1]))
    pointer = struct.unpack_from("<I", config, 44)[0]

    params = bytearray(from_va(pointer, 0x200))
    state = pointer
    for i in range(0, len(params), 4):
        state = (state * 0x19660d + 0x3c6ef35f) & 0xffffffff
        struct.pack_into('<I', params, i, struct.unpack_from('<I', params, i)[0] ^ state)
    key = params[32:47]
    schedule = bytearray()
    position = 11
    for _ in range(9):
        schedule.extend(key[(position+j)%15] for j in range(4))
        position = (position+12)%15
        if position == 12:
            break
        schedule.extend(key[position:position+3])
        position = (position+11)%15
    require(len(schedule) == 60, "loader_schedule_length")
    return lambda block: transform(block, schedule)


def decode_members(data, transform):
    require(hashlib.sha256(data).hexdigest() in SUPPORTED_CN, "unsupported_cn_sha256")
    footer = len(data) - 44
    size, _, start, records, count, total = struct.unpack_from('<6I', data, footer)
    require(total == len(data) and 0 < size <= 1024 * 1024 and size % 8 == 0
            and start + size <= footer and 0 < count <= 512 and records + count * 16 <= size,
            "invalid_cn_directory")
    directory = bytearray(data[start:start + size])
    transform(directory)
    require(hashlib.md5(directory).digest() == data[-20:-4], "cn_directory_checksum")
    seen = set()
    skipped = Counter()
    normalized = Counter()
    members = {}
    total_output = 0
    for row in range(count):
        name_offset, member_offset, length, flags = struct.unpack_from('<4I', directory, records + row * 16)
        require(name_offset < size, "cn_name_offset")
        end = directory.index(0, name_offset)
        name = safe_member_name(directory[name_offset:end].decode('gbk'))
        key = collision_key(name)
        require(key not in seen, "cn_duplicate_path")
        seen.add(key)
        extension = Path(name).suffix.lower()
        if extension not in {'.s', '.txt', '.png', '.ogv', '.b'}:
            skipped[extension] += 1
            continue
        limit = (48 if extension == '.ogv' else 16) * 1024 * 1024
        require(flags == 0x33 and 0 < length <= limit, "unsupported_cn_member")
        total_output += length
        require(total_output <= 128 * 1024 * 1024, "cn_total_output_limit")
        chunks = (length + 65535) // 65536
        table_offset = member_offset - chunks * 4
        require(0 <= table_offset < member_offset < start, "cn_block_table_range")
        output = bytearray()
        for (word,) in struct.iter_unpack('<I', data[table_offset:member_offset]):
            stored_length = word & 0x7fffffff
            require(0 < stored_length <= 65536 and member_offset + stored_length <= start,
                    "cn_block_range")
            block = data[member_offset:member_offset + stored_length]
            member_offset += stored_length
            aligned = stored_length & ~7
            prefix = bytearray(block[:aligned])
            transform(prefix)
            clear = prefix + block[aligned:]
            expected = min(65536, length - len(output))
            if word >> 31:
                plain = clear
            else:
                decoder = zlib.decompressobj()
                plain = decoder.decompress(clear, expected + 1)
                require(decoder.eof and not decoder.unused_data, "cn_block_stream")
            require(len(plain) == expected, "cn_block_output_length")
            output.extend(plain)
        require(len(output) == length, "cn_member_output_length")
        if extension in {'.s', '.txt'}:
            if extension == '.txt' and not output.startswith((b'\xff\xfe', b'\xfe\xff')):
                if name != 'script/soundmode/list.txt':
                    skipped['.txt_without_utf16_bom'] += 1
                    continue
                # The pinned samples use GBK for this sound-gallery table.
                output = b'\xff\xfe' + output.decode('gbk').encode('utf-16-le')
            require(output.startswith((b'\xff\xfe', b'\xfe\xff')), "cn_script_bom")
            text = output.decode('utf-16')
            if extension == '.s' and name == 'scenario/本編/t10_01.s' and '\x1e' in text:
                normalized['script_literal_u001e_removed'] += text.count('\x1e')
                output = b'\xff\xfe' + text.replace('\x1e', '').encode('utf-16-le')
        elif extension == '.png':
            require(output.startswith(b'\x89PNG\r\n\x1a\n'), "cn_png_signature")
        elif extension == '.ogv':
            require(output.startswith(b'OggS'), "cn_ogg_signature")
        elif extension == '.b':
            require(output.startswith(b'abmp12\0\0'), "cn_abmp_signature")
        members[name] = output
    return members, skipped, normalized


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--assets-dir', required=True, help='Existing assets directory under workspace private/')
    parser.add_argument('--loader', required=True, help='Local 1.00 patch EXE, read as data')
    parser.add_argument('--cn', required=True)
    args = parser.parse_args()
    assets = absolute(args.assets_dir)
    try:
        require((ROOT / 'private') in assets.parents, "assets_must_be_under_private")
        os.close(safe_open(assets, directory=True))
        members, skipped, normalized = decode_members(read_bounded(args.cn, MAX_PE), loader_transform(args.loader))
        output = Path(tempfile.mkdtemp(prefix='local-cn-', dir=assets))
        try:
            for name, payload in members.items():
                path = output / name
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open('xb') as stream:
                    stream.write(payload)
        except OSError:
            shutil.rmtree(output)
            raise
    except (OSError, ValueError, zlib.error, struct.error) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps(dict(overlay=output.name, decoded=len(members), skipped=skipped, normalized=normalized)))


if __name__ == '__main__':
    main()
