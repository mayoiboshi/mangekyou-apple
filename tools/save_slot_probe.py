#!/usr/bin/env python3
"""Validate the outer envelope of a QLIE slot file without extracting it."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

if __package__:
    from .delphi_metadata import Image
    from .mangekyou_p0 import ProbeError, read_bounded, safe_member_name
else:
    from delphi_metadata import Image
    from mangekyou_p0 import ProbeError, read_bounded, safe_member_name


HEADER = struct.Struct("<III")
MAGIC = 0xFD324D4E
MAX_FILE_SIZE = 16 * 1024 * 1024
MASK32 = 0xFFFFFFFF
SLOT_HEADER_SIZE = 138
SAVE_TEMPLATE_EXE_SHA256 = "ad02b1115887b8e5b453d4b5760077e8b63e153bba1161e1704209cf3db5cda5"


def load_slot_header_template(game_dir, exe):
    binary = read_bounded(game_dir / safe_member_name(exe), 64 * 1024 * 1024)
    if hashlib.sha256(binary).hexdigest() != SAVE_TEMPLATE_EXE_SHA256:
        raise ProbeError("save_header_template_exe_identity")
    return Image(binary, budget=40).read(0x6908A4, 40)


def signed_word(value):
    return value - 0x10000 if value & 0x8000 else value


def payload_checksum(payload):
    """Scalar translation of the original Win32 routine at VA 0x4e2578."""
    low = high = 0
    salt_low = salt_high = 0
    block_end = len(payload) & ~7
    for first, second in struct.iter_unpack("<II", payload[:block_end]):
        salt_low = (salt_low + 0x93A7) & 0xFFFF
        salt_high = (salt_high + 0xA357) & 0xFFFF
        salt = salt_low | (salt_high << 16)
        first ^= salt
        second ^= salt
        low = (((low + first) & 0xFFFF) |
               ((((low >> 16) + (first >> 16)) & 0xFFFF) << 16))
        high = (((high + second) & 0xFFFF) |
                ((((high >> 16) + (second >> 16)) & 0xFFFF) << 16))
        low = ((low << 3) | (low >> 29)) & MASK32
        high = ((high << 3) | (high >> 29)) & MASK32
    return (signed_word(low & 0xFFFF) * signed_word(high & 0xFFFF) +
            signed_word(low >> 16) * signed_word(high >> 16)) & MASK32


def decode_runlengthpack(data):
    """Decode the version-one state stream after any outer transformation."""
    if len(data) < 64 or data[:14] != b"runlengthpack\0":
        raise ProbeError("invalid_runlengthpack_header")
    version, block_bytes, tail_bytes = struct.unpack_from("<III", data, 16)
    if version != 1 or block_bytes % 4 or tail_bytes > 3:
        raise ProbeError("unsupported_runlengthpack_layout")
    if block_bytes + tail_bytes > MAX_FILE_SIZE:
        raise ProbeError("runlengthpack_output_limit")

    output = bytearray()
    entries = [None] * 64
    protected = [False] * 64
    next_entry = 0
    cursor = 64
    while len(output) < block_bytes:
        if cursor >= len(data):
            raise ProbeError("truncated_runlengthpack_control")
        control, = struct.unpack_from("<b", data, cursor)
        cursor += 1
        if control > 0:
            source, size, count = cursor, 4, control
            cursor += size
        elif -63 <= control < 0:
            source, size, count = cursor, -control * 4, 1
            while protected[next_entry]:
                protected[next_entry] = False
                next_entry = (next_entry + 1) % 64
            entries[next_entry] = (source, size)
            next_entry = (next_entry + 1) % 64
            cursor += size
        elif -127 <= control <= -64:
            entry = -control - 64
            if entries[entry] is None:
                raise ProbeError("undefined_runlengthpack_reference")
            source, size = entries[entry]
            protected[entry] = True
            count = 1
        else:
            raise ProbeError("invalid_runlengthpack_control")
        if cursor > len(data) or size * count > block_bytes - len(output):
            raise ProbeError("runlengthpack_block_bounds")
        output.extend(bytes(data[source:source + size]) * count)
    if cursor != len(data):
        raise ProbeError("runlengthpack_trailing_data")
    output.extend(data[28:28 + tail_bytes])
    return bytes(output)


def slot_sections(payload):
    """Locate sections without decoding text, JPEG, or the state stream."""
    cursor = SLOT_HEADER_SIZE
    for _ in range(8):
        if len(payload) - cursor < 2:
            raise ProbeError("truncated_slot_string_length")
        units, = struct.unpack_from("<h", payload, cursor)
        if units < 0:
            raise ProbeError("negative_slot_string_length")
        cursor += 2 + 2 * units
        if cursor > len(payload):
            raise ProbeError("truncated_slot_string")

    sections = {}
    for name in ("thumbnail", "state"):
        if len(payload) - cursor < 4:
            raise ProbeError(f"truncated_slot_{name}_length")
        size, = struct.unpack_from("<i", payload, cursor)
        cursor += 4
        if not 0 <= size <= len(payload) - cursor:
            raise ProbeError(f"invalid_slot_{name}_length")
        sections[name] = {"offset": HEADER.size + cursor, "length": size}
        cursor += size
    sections["trailing_bytes"] = len(payload) - cursor
    return sections


def reader_record_offset(data, routine_count):
    """Walk version-10 routines and their control blocks without applying state."""
    cursor = 16
    remaining_blocks = 4096

    def take(size):
        nonlocal cursor
        start = cursor
        cursor += size
        if cursor > len(data):
            raise ProbeError("truncated_thread_record")
        return data[start:cursor]

    def strings(count):
        for _ in range(count):
            units, = struct.unpack("<h", take(2))
            if units < 0:
                raise ProbeError("negative_routine_string_length")
            take(2 * units)

    def routines(count):
        nonlocal remaining_blocks
        if not 0 <= count <= 1024:
            raise ProbeError("routine_tree_limit")
        for _ in range(count):
            if take(8) != b"routine\0" or take(4) != struct.pack("<i", 10):
                raise ProbeError("unsupported_routine_header")
            strings(16)
            take(13)
            strings(3)
            if take(1)[0]:
                take(64)
                strings(33)
                take(16)
                strings(4)
                take(24)
                strings(4)
            children, = struct.unpack("<i", take(4))
            if not 0 <= children <= min(1024, remaining_blocks):
                raise ProbeError("saved_control_block_limit")
            remaining_blocks -= children
            for _ in range(children):
                if take(4) != struct.pack("<i", 10):
                    raise ProbeError("unsupported_saved_control_block_version")
                strings(2)
                take(9)
                strings(8)

    routines(routine_count)
    start = cursor
    if struct.unpack_from("<i", take(77))[0] != 10:
        raise ProbeError("unsupported_reader_record_version")
    return start


def reader_metadata(data, offset):
    """Report the saved cursor and reader boundaries without exposing text."""
    relative_line, position, replace_enabled = struct.unpack_from("<iiB", data, offset + 4)
    cursor = offset + 77

    def take(size):
        nonlocal cursor
        start = cursor
        cursor += size
        if cursor > len(data):
            raise ProbeError("truncated_reader_metadata")
        return memoryview(data)[start:cursor]

    def string_reference():
        units, = struct.unpack("<h", take(2))
        if units < 0:
            raise ProbeError("negative_reader_string_length")
        start = cursor
        raw = take(units * 2)
        return {"decoded_offset": start, "length": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}

    fields = {
        name: string_reference()
        for name in ("line_buffer", "script_path", "label", "text_prefix", "empty_line_text")
    }
    count, = struct.unpack("<i", take(4))
    if not 0 <= count <= 65536:
        raise ProbeError("reader_replacement_count_limit")
    for _ in range(count):
        string_reference()
        string_reference()
        take(4)
    return {
        "relative_line": relative_line,
        "utf16_position": position,
        "replace_enabled_raw": replace_enabled,
        "strings": fields,
        "replacement_count": count,
        "next_decoded_offset": cursor,
    }


def path_record(data, offset):
    """Locate the end of the TImoPath record without reporting its strings."""
    start = offset
    if len(data) - offset < 4:
        raise ProbeError("truncated_path_count")
    count, = struct.unpack_from("<i", data, offset)
    if not 0 <= count <= 65535:
        raise ProbeError("invalid_path_count")
    offset += 4
    for _ in range(count):
        if len(data) - offset < 2:
            raise ProbeError("truncated_path_string_length")
        units, = struct.unpack_from("<h", data, offset)
        if units < 0 or units * 2 > len(data) - offset - 2:
            raise ProbeError("invalid_path_string_length")
        offset += 2 + units * 2
    if offset >= len(data):
        raise ProbeError("truncated_path_flag")
    return {"decoded_offset": start, "entry_count": count, "raw_flag": data[offset],
            "next_decoded_offset": offset + 1}


def state_table_record(data, offset):
    """Walk the fixed table following TImoPath, preserving field opacity."""
    start = offset
    offset += 76
    for _ in range(256):
        for _ in range(4):
            if len(data) - offset < 2:
                raise ProbeError("truncated_state_table_string_length")
            units, = struct.unpack_from("<h", data, offset)
            if units < 0 or units * 2 > len(data) - offset - 2:
                raise ProbeError("invalid_state_table_string_length")
            offset += 2 + units * 2
        offset += 16
        if offset > len(data):
            raise ProbeError("truncated_state_table_values")
    return {"decoded_offset": start, "entry_count": 256, "next_decoded_offset": offset}


def sound_records(data, offset):
    """Walk both sound banks without interpreting playback state."""
    banks = {}
    for tag, record_size, string_count in ((b"dsnd", 86, 1), (b"ssnd", 131, 2)):
        if len(data) - offset < 12 or bytes(data[offset:offset + 8]).split(b"\0", 1)[0] != tag:
            raise ProbeError(f"{tag.decode()}_prefix_missing")
        start = offset
        count, = struct.unpack_from("<i", data, offset + 8)
        offset += 12
        if not 0 <= count <= (len(data) - offset) // (record_size + 2 * string_count):
            raise ProbeError("invalid_sound_record_count")
        for _ in range(count):
            offset += record_size
            for _ in range(string_count):
                if len(data) - offset < 2:
                    raise ProbeError("truncated_sound_string_length")
                units, = struct.unpack_from("<h", data, offset)
                if units < 0 or units * 2 > len(data) - offset - 2:
                    raise ProbeError("invalid_sound_string_length")
                offset += 2 + units * 2
        banks[tag.decode()] = {"decoded_offset": start, "entry_count": count,
                               "next_decoded_offset": offset}
    return banks


def skip_image_generator(take):
    if take(8) != b"vgene\0\0\0":
        raise ProbeError("invalid_image_generator_tag")
    version, = struct.unpack("<i", take(4))
    if version not in (1, 2, 3):
        raise ProbeError("unsupported_image_generator_version")
    take(39 + (version >= 2) + 4 * (version >= 3))


def generator_group(take):
    units, = struct.unpack("<h", take(2))
    try:
        descriptor = bytes(take(units * 2)).decode("utf-16le")
    except UnicodeDecodeError:
        raise ProbeError("invalid_generator_group_encoding") from None
    fields = descriptor.split(chr(92)) if descriptor else []
    if any(not field or any(not ch.isprintable() or ch.isspace() or ch in '()[]{}"/' for ch in field)
           for field in fields):
        return {"generator_group": "not_tested", "reason": "generator_group_descriptor_unparsed"}
    for _ in fields:
        skip_image_generator(take)
    return {"generator_group": "verified", "generator_group_entry_count": len(fields)}


def image_library_prefix(data, offset):
    """Locate image resource references and embedded blobs before child objects."""
    start = offset
    cursor = offset

    def take(size):
        nonlocal cursor
        if not 0 <= size <= len(data) - cursor:
            raise ProbeError("invalid_image_library_prefix_bounds")
        begin = cursor
        cursor += size
        return memoryview(data)[begin:cursor]

    def skip_string():
        units, = struct.unpack("<h", take(2))
        take(units * 2)
        return units > 0

    take(0xA5E)
    references = int(skip_string())
    embedded = 0
    for _ in range(33):
        references += skip_string()
        length, = struct.unpack("<i", take(4))
        take(length)
        embedded += length > 0
    for _ in range(64):
        references += skip_string()
    take(256)
    child_start = cursor
    for _ in range(4):
        skip_image_generator(take)
    result = {"decoded_offset": start, "reference_count": references, "embedded_blob_count": embedded,
              "child_objects_offset": child_start, "fixed_generator_count": 4,
              "generator_group_offset": cursor}
    if len(data) - cursor < 2:
        raise ProbeError("invalid_image_library_prefix_bounds")
    result["generator_group_entries_offset"] = cursor + 2 + 2 * struct.unpack_from("<h", data, cursor)[0]
    result.update(generator_group(take))
    if result["generator_group"] != "verified":
        return result

    for _ in range(8):
        take(4)
        skip_string()
    skip_string()
    result["generator_group"] = "verified"
    result["next_decoded_offset"] = cursor
    return result


def display_state_record(data, offset):
    """Read the display state boundary, including conditional embedded images."""
    start = offset
    source = memoryview(data)

    def take(size):
        nonlocal offset
        if not 0 <= size <= len(data) - offset:
            raise ProbeError("invalid_display_state_bounds")
        begin = offset
        offset += size
        return source[begin:offset]

    def skip_string():
        units, = struct.unpack("<h", take(2))
        take(units * 2)

    fixed = take(140)
    skip_string()
    embedded = 0
    for flag in fixed[33:35]:
        if flag == 1:
            skip_string()
            size, = struct.unpack("<i", take(4))
            take(size)
            embedded += 1
    result = {"decoded_offset": start, "raw_mode": fixed[9], "embedded_image_count": embedded}
    if fixed[9] == 9:
        library = image_library_prefix(data, offset)
        result["nested_image_library"] = library
        if "next_decoded_offset" not in library:
            return result
        offset = library["next_decoded_offset"]
    result["next_decoded_offset"] = offset
    return result


def post_display_records(data, offset):
    """Walk the next two state objects without assigning field semantics."""
    source = memoryview(data)
    start = offset

    def take(size):
        nonlocal offset
        if not 0 <= size <= len(source) - offset:
            raise ProbeError("invalid_post_display_bounds")
        begin = offset
        offset += size
        return source[begin:offset]

    def skip_string():
        units, = struct.unpack("<h", take(2))
        take(units * 2)

    take(69)
    count, = struct.unpack("<i", take(4))
    if not 0 <= count <= (len(source) - offset) // 12:
        raise ProbeError("invalid_post_display_count")
    for _ in range(count):
        take(4)
        for _ in range(4):
            skip_string()
    take(4)
    for _ in range(27):
        skip_string()
        take(12)
    fixed_start = offset
    take(141)
    return {"decoded_offset": start, "entry_count": count,
            "fixed_record_offset": fixed_start, "next_decoded_offset": offset}


def variable_array_records(data, offset):
    """Locate scalar arrays and bounded list/table object payloads."""
    start = offset

    def take(size):
        nonlocal offset
        if not 0 <= size <= len(data) - offset:
            raise ProbeError("invalid_variable_array_bounds")
        begin = offset
        offset += size
        return memoryview(data)[begin:offset]

    def string_bytes():
        units, = struct.unpack("<h", take(2))
        return take(units * 2)

    def skip_strings(count):
        for _ in range(count):
            string_bytes()

    count, = struct.unpack("<i", take(4))
    if not 0 <= count <= min(65536, (len(data) - offset) // 22):
        raise ProbeError("invalid_variable_array_count")
    result = {"declared_count": count, "integer_arrays": 0, "string_arrays": 0,
              "object_arrays": 0, "absent_values": 0, "text_object_payload_count": 0}
    remaining_values = 1_000_000
    for _ in range(count):
        record_start = offset
        header = take(18)
        string_bytes()
        object_type = bytes(string_bytes()).lower()
        kind = header[12]
        if kind == 3:
            # 0x69eda3 emits this tag for a null value object.
            result["absent_values"] += 1
            continue
        if kind not in (0, 1, 2):
            return {**result, "status": "unsupported", "raw_type": kind,
                    "unparsed_offset": record_start}
        take(16)
        length, = struct.unpack("<i", take(4))
        if not 0 <= length <= min(remaining_values, (len(data) - offset) // (4 if kind == 0 else 2)):
            raise ProbeError("invalid_variable_array_length")
        remaining_values -= length
        if kind == 2:
            has_payload = header[13] == 0
            if length and has_payload and object_type not in ("list".encode("utf-16le"), "table".encode("utf-16le")):
                return {**result, "status": "unsupported", "raw_type": kind,
                        "reason": "object_callback_payload_unparsed", "unparsed_offset": record_start}
            for _ in range(length):
                string_bytes()
                if has_payload:
                    # 0x68e3cc and 0x68f308 share the base record and text stream.
                    tag, version, _, lines = struct.unpack("<4siii", take(16))
                    if tag != b"objd" or version != 1:
                        raise ProbeError("unsupported_saved_text_object_header")
                    if not -1 <= lines <= min(65535, remaining_values, (len(data) - offset) // 2):
                        raise ProbeError("invalid_saved_text_object_line_count")
                    remaining_values -= max(0, lines)
                    skip_strings(max(0, lines))
                    result["text_object_payload_count"] += 1
            result["object_arrays"] += 1
        elif kind == 0:
            take(length * 4)
            result["integer_arrays"] += 1
        else:
            skip_strings(length)
            result["string_arrays"] += 1
    return {**result, "status": "verified", "decoded_offset": start, "next_decoded_offset": offset}


def indexed_variable_records(data, offset):
    """Read the optional version-zero ValIdx groups after CalVal arrays."""
    if bytes(data[offset:offset + 8]).split(b"\0", 1)[0] != b"ValIdx":
        return {"status": "not_tested", "reason": "validx_tag_absent", "decoded_offset": offset}
    if len(data) - offset < 16:
        raise ProbeError("truncated_validx_header")
    version, count = struct.unpack_from("<ii", data, offset + 8)
    if version != 0:
        return {"status": "unsupported", "reason": "unsupported_validx_version", "version": version}
    cursor = offset + 16
    if not 0 <= count <= min(4096, (len(data) - cursor) // 4):
        raise ProbeError("invalid_validx_count")
    for index in range(count):
        arrays = variable_array_records(data, cursor)
        if "next_decoded_offset" not in arrays:
            return {"status": "unsupported", "group_index": index, "arrays": arrays}
        cursor = arrays["next_decoded_offset"]
    return {"status": "verified", "decoded_offset": offset, "group_count": count,
            "next_decoded_offset": cursor}


def engine_state_prefix(data, offset):
    """Locate the engine strings after the fixed 419-byte state block."""
    cursor = offset + 419
    if cursor > len(data):
        raise ProbeError("truncated_engine_state_header")
    for _ in range(7):
        if len(data) - cursor < 2:
            raise ProbeError("truncated_engine_state_string_length")
        units, = struct.unpack_from("<h", data, cursor)
        cursor += 2
        if not 0 <= units * 2 <= len(data) - cursor:
            raise ProbeError("invalid_engine_state_string_length")
        cursor += units * 2
    return {"decoded_offset": offset, "fixed_length": 419, "string_count": 7,
            "next_decoded_offset": cursor, "remaining_length": len(data) - cursor}


def engine_object_records(data, offset):
    """Walk the first three engine objects after the engine state prefix."""
    start = offset

    def take(size):
        nonlocal offset
        if not 0 <= size <= len(data) - offset:
            raise ProbeError("invalid_engine_object_bounds")
        begin = offset
        offset += size
        return memoryview(data)[begin:offset]

    def skip_string():
        units, = struct.unpack("<h", take(2))
        take(units * 2)

    take(69)
    take(69)
    count, = struct.unpack("<i", take(4))
    if not 0 <= count <= 65535:
        raise ProbeError("invalid_engine_string_list_count")
    for _ in range(count):
        skip_string()
    take(68)
    blobs, = struct.unpack("<i", take(4))
    if not 0 <= blobs <= min(65536, (len(data) - offset) // 14):
        raise ProbeError("invalid_engine_blob_count")
    for _ in range(blobs):
        skip_string()
        take(8)
        length, = struct.unpack("<i", take(4))
        take(length)
    return {"decoded_offset": start, "string_count": count, "blob_count": blobs,
            "next_decoded_offset": offset}


def final_object_prefix(data, offset):
    """Read the fixed prefix and generators of the object after imotwt."""
    start = offset

    def take(size):
        nonlocal offset
        if not 0 <= size <= len(data) - offset:
            raise ProbeError("truncated_final_object_prefix")
        begin = offset
        offset += size
        return memoryview(data)[begin:offset]

    take(53)
    version, = struct.unpack("<i", take(4))
    if version not in (1, 2, 3):
        raise ProbeError("unsupported_final_object_version")
    take(121)
    for _ in range(4):
        skip_image_generator(take)
    result = {"decoded_offset": start, "version": version, "fixed_generator_count": 4}
    if version >= 2:
        result.update(generator_group(take))
        if result["generator_group"] != "verified":
            return result
    if version >= 3:
        take(4)
    take(4)
    tail_version, = struct.unpack("<i", take(4))
    if tail_version not in (1, 2):
        raise ProbeError("unsupported_final_object_tail_version")
    take(24 + 4 * (tail_version == 2))
    for _ in range(8):
        units, = struct.unpack("<h", take(2))
        if units < 0:
            raise ProbeError("invalid_final_object_string_length")
        take(2 * units)
    result.update(tail_version=tail_version, next_decoded_offset=offset)
    return result


def decode_state_transform(data, seed):
    """Reverse the state block transform at VA 0x4e182c."""
    if not 0 <= seed <= MASK32:
        raise ProbeError("invalid_state_seed")
    output = bytearray(data)
    state_low = state_high = 0xA73C5F9D
    feedback_low = feedback_high = ((len(data) + seed) & MASK32) ^ 0xFEC9753E
    for offset in range(0, len(data) & ~7, 8):
        state_low = ((state_low + 0xCE24F523) & MASK32) ^ feedback_low
        state_high = ((state_high + 0xCE24F523) & MASK32) ^ feedback_high
        low, high = struct.unpack_from("<II", data, offset)
        struct.pack_into("<II", output, offset, low ^ state_low, high ^ state_high)
        feedback_low, feedback_high = low, high
    return output


def inspect_decoded_state(data, report):
    """Read known sections in order and retain the first unparsed boundary."""
    offset = 0
    stage = "state_prefix"
    try:
        if len(data) < 16 or data[:8] != b"thread\0\0":
            raise ProbeError("thread_prefix_missing")
        version, count = struct.unpack_from("<ii", data, 8)
        supported = version == 10 and count >= 0
        report[stage] = {"status": "verified" if supported else "unsupported",
                         "scope": "thread prefix only", "version": version, "routine_count": count}
        offset = 16
        if not supported:
            return
        stage = "reader_record"
        offset = reader_record_offset(data, count)
        report[stage] = {"status": "verified", "decoded_offset": offset, "length": 77}

        for stage, parse in (
            ("reader_metadata", reader_metadata),
            ("path_record", path_record),
            ("state_table", state_table_record),
            ("sound_records", sound_records),
            ("image_library", image_library_prefix),
            ("second_image_library", image_library_prefix),
            ("display_state", display_state_record),
            ("post_display", post_display_records),
        ):
            section = parse(data, offset)
            report[stage] = {"status": "verified", **section}
            if stage == "sound_records":
                offset = section["ssnd"]["next_decoded_offset"]
            elif "next_decoded_offset" in section:
                offset = section["next_decoded_offset"]
            else:
                return

        stage = "variable_state"
        if len(data) - offset < 16 or bytes(data[offset:offset + 8]).split(b"\0", 1)[0] != b"CalVal":
            raise ProbeError("calval_prefix_missing")
        version, = struct.unpack_from("<i", data, offset + 8)
        variables = {"status": "verified" if version == 1 else "unsupported",
                     "scope": "CalVal prefix only", "decoded_offset": offset,
                     "version": version, "body_offset": offset + 16}
        report[stage] = variables
        if version != 1:
            return
        offset += 16
        stage = "arrays"
        arrays = variable_array_records(data, offset)
        variables[stage] = arrays
        if "next_decoded_offset" not in arrays:
            offset = arrays.get("unparsed_offset", offset)
            return
        offset = arrays["next_decoded_offset"]
        stage = "indexed"
        indexed = indexed_variable_records(data, offset)
        variables[stage] = indexed
        if indexed.get("reason") != "validx_tag_absent":
            if "next_decoded_offset" not in indexed:
                return
            offset = indexed["next_decoded_offset"]
        stage = "engine_state"
        engine = engine_state_prefix(data, offset)
        report[stage] = {"status": "verified", **engine}
        offset = engine["next_decoded_offset"]
        stage = "engine_objects"
        objects = engine_object_records(data, offset)
        report[stage] = {"status": "verified", **objects}
        offset = objects["next_decoded_offset"]
        stage = "imotwt_record"
        if len(data) - offset < 264:
            raise ProbeError("truncated_imotwt_record")
        if bytes(data[offset:offset + 8]).split(b"\0", 1)[0] != b"imotwt":
            raise ProbeError("imotwt_tag_mismatch")
        report[stage] = {"status": "verified", "decoded_offset": offset, "length": 264,
                         "next_decoded_offset": offset + 264}
        offset += 264
        stage = "final_object_prefix"
        prefix = final_object_prefix(data, offset)
        report[stage] = {"status": "verified", **prefix}
        offset = prefix.get("next_decoded_offset", offset)
    except ProbeError as exc:
        target = variables if stage in ("arrays", "indexed") else report
        target[stage] = {"status": "unsupported", "reason": str(exc)}
    finally:
        complete = report.get("final_object_prefix", {}).get("status") == "verified" and offset == len(data)
        report["state_structure_status"] = "verified" if complete else "unsupported"
        report["remaining_state"] = {
            "status": "not_tested", "decoded_offset": offset, "length": len(data) - offset,
        }


def probe(data, seed=None, header_template=None):
    if len(data) < HEADER.size:
        raise ProbeError("truncated_envelope")
    magic, checksum, length = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise ProbeError("unknown_envelope_magic")
    if length != len(data) - HEADER.size:
        raise ProbeError("envelope_length_mismatch")
    payload = memoryview(data)[HEADER.size:]
    if payload_checksum(payload) != checksum:
        raise ProbeError("envelope_checksum_mismatch")
    slot_tag = b"IMOSAVE110"
    system_tag = b"IMOSYSDATA12"
    if payload[:len(slot_tag) + 1] == slot_tag + b"\0":
        inner_kind = "slot" if length >= SLOT_HEADER_SIZE else "truncated_slot_header"
    elif payload[:len(system_tag)] == system_tag:
        inner_kind = "system"
    else:
        inner_kind = "unknown"
    result = {
        "status": "verified",
        "scope": "outer envelope and inner tag only",
        "inner_kind": inner_kind,
        "payload_offset": HEADER.size,
        "payload_length": length,
        "checksum_ignored_tail_length": length % 8,
        "inner_container": "not_tested",
        "restore": "not_tested",
        "state_structure_status": "not_tested",
    }

    if inner_kind == "slot":
        header_version, = struct.unpack_from("<i", payload, 56)
        if header_version > 10:
            raise ProbeError("unsupported_slot_header_version")
        result["slot_header_version"] = header_version
        result["sections"] = slot_sections(payload)
        result["scope"] = "outer envelope, inner tag and section bounds only"
        if header_template is not None:
            if len(header_template) != 40 or seed is not None:
                raise ProbeError("invalid_slot_header_template")
            stored = payload[16:56]
            first, = struct.unpack_from("<I", stored)
            clear, = struct.unpack_from("<I", header_template)
            initial = first ^ clear ^ ((0xA73C5F9D + 0xCE24F523) & MASK32) ^ 0xFEC9753E
            seed = (initial - 32) & MASK32
            if decode_state_transform(stored[:32], seed) != header_template[:32] or stored[32:] != header_template[32:]:
                raise ProbeError("save_header_verification_mismatch")
            result["slot_header_verification"] = "verified"
        state = result["sections"]["state"]
        start = state["offset"]
        state_data = memoryview(data)[start:start + state["length"]]
        transformed = payload[60] != 0
        packed = payload[61] != 0
        codec, = struct.unpack_from("<I", payload, 70)
        if transformed and seed is None:
            result["state_codec"] = {"status": "not_tested", "reason": "state_seed_required"}
            return result
        if transformed:
            state_data = decode_state_transform(state_data, seed)
        if packed and codec == 1:
            decoded = decode_runlengthpack(state_data)
            result["state_codec"] = {
                "status": "verified",
                "scope": "runlengthpack decoding only",
                "decoded_length": len(decoded),
            }
        elif packed:
            result["state_codec"] = {"status": "unsupported", "reason": "unknown_state_codec"}
            return result
        else:
            decoded = state_data
            result["state_codec"] = {
                "status": "verified",
                "scope": "uncompressed state bytes",
                "decoded_length": len(decoded),
            }
        inspect_decoded_state(decoded, result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("slot", type=Path)
    parser.add_argument("--seed-stdin", action="store_true", help="read a 32-bit hex seed from stdin")
    parser.add_argument("--game-dir", type=Path, help="local installation for verified slot-header inspection")
    parser.add_argument("--exe", help="relative path of the pinned original executable")
    parser.add_argument("--require-state", action="store_true", help="fail unless the known state structure is fully parsed")
    args = parser.parse_args()
    if (args.game_dir is None) != (args.exe is None) or (args.game_dir and args.seed_stdin):
        parser.error("--game-dir and --exe must be paired and cannot be combined with --seed-stdin")
    report = {"source_file": args.slot.name}
    try:
        data = read_bounded(args.slot, MAX_FILE_SIZE)
        report["sha256"] = hashlib.sha256(data).hexdigest()
        seed = None
        if args.seed_stdin:
            raw_seed = sys.stdin.buffer.readline(17).strip()
            if not 1 <= len(raw_seed) <= 8 or any(c not in b"0123456789abcdefABCDEF" for c in raw_seed):
                raise ProbeError("invalid_state_seed")
            seed = int(raw_seed, 16)
        template = load_slot_header_template(args.game_dir, args.exe) if args.game_dir else None
        report.update(probe(data, seed=seed, header_template=template))
    except (ProbeError, OSError) as exc:
        report.update(status="unsupported", reason=str(exc))
    print(json.dumps(report))
    return 0 if report["status"] == "verified" and (
        not args.require_state or report.get("state_structure_status") == "verified"
    ) else 1


if __name__ == "__main__":
    raise SystemExit(main())
