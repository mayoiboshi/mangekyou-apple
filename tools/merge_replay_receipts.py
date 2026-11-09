#!/usr/bin/env python3
"""Merge local, digest-pinned media receipts into a new private replay directory."""

import argparse
import hashlib
import json
import re
from itertools import chain
from pathlib import Path

from mangekyou_p0 import ROOT, ProbeError, absolute, read_bounded, safe_member_name, write_json

LIMIT = 32 * 1024 * 1024
RECIPE_LIMIT = 1024 * 1024
FIELDS = ("image_resources", "audio_resources", "wave_resources")
MEDIA_SUFFIXES = {".png", ".jpg", ".jpeg", ".bmp", ".ogg", ".ogv", ".wav", ".b"}
ASCII_FOLD = str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")


def key(path):
    return safe_member_name(path).translate(ASCII_FOLD)


def load_replay(directory):
    summary = json.loads(read_bounded(directory / "summary.json", LIMIT))
    catalog = read_bounded(directory / "combined-catalog.json", LIMIT)
    if hashlib.sha256(catalog).hexdigest() != summary["corpus_report_sha256"]:
        raise ProbeError("replay_catalog_identity_mismatch")
    if any(not isinstance(summary.get(field), list) for field in FIELDS):
        raise ProbeError("replay_requires_structured_receipts")
    return summary, json.loads(catalog)


def recipe_groups(directory):
    groups = {}
    for entry in json.loads(read_bounded(directory / "image-recipe.json", RECIPE_LIMIT)):
        digest = entry["container_sha256"]
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ProbeError("invalid_image_recipe_digest")
        groups.setdefault(digest, []).append(entry)
    return groups


def merge(base, donors, output, refresh_digests=(), *, recipe_only=False):
    if ROOT / "private" not in output.parents or output.exists() or output.is_symlink():
        raise ProbeError("replay_output_must_be_new_private_directory")
    summary, catalog = load_replay(base)
    if recipe_only and not refresh_digests:
        raise ProbeError("recipe_only_requires_refresh_digest")
    sources = () if recipe_only else chain((summary,), (load_replay(directory)[0] for directory in donors))
    indexed = {key(name) for name in catalog.get("indexedResourceNames", [])}
    by_logical = {}
    for entry in catalog["items"]:
        by_logical.setdefault(key(entry["logical_path"]), []).append(entry)
    merged = {field: [] for field in FIELDS}
    added = dict.fromkeys(FIELDS, 0)
    seen = {}
    for source_index, source in enumerate(sources):
        for field in FIELDS:
            for entry in source[field]:
                logical = key(entry["logical_path"])
                physical = safe_member_name(entry["source_file"])
                if Path(physical).suffix.lower() not in MEDIA_SUFFIXES:
                    raise ProbeError("invalid_resource_receipt_format")
                if not re.fullmatch(r"[a-f0-9]{64}", entry["sha256"]):
                    raise ProbeError("invalid_resource_receipt_digest")
                if logical in seen:
                    if entry != seen[logical]:
                        raise ProbeError(f"resource_receipt_conflict: {entry['logical_path']}")
                    continue
                if logical in by_logical:
                    if entry not in by_logical[logical]:
                        raise ProbeError(f"resource_catalog_conflict: {entry['logical_path']}")
                elif logical not in indexed:
                    raise ProbeError(f"resource_not_indexed: {entry['logical_path']}")
                seen[logical] = entry
                merged[field].append(entry)
                if source_index:
                    added[field] += 1
                if len(seen) > 50_000:
                    raise ProbeError("replay_receipt_count_limit")
    recipes = recipe_groups(base)
    base_digests = set(recipes)
    refresh_digests = set(refresh_digests)
    if not refresh_digests <= base_digests:
        raise ProbeError("refresh_recipe_not_in_base")
    refreshed = {}
    identity_fields = ("offset", "length", "sha256", "format")
    admitted_digests = {entry["sha256"] for entry in seen.values()}
    admitted_digests.update(entry["sha256"] for entry in catalog["items"])
    if recipe_only:
        admitted_digests.update(entry["sha256"] for field in FIELDS for entry in summary[field])
    retained = set()
    for directory in donors:
        for digest, group in recipe_groups(directory).items():
            if digest not in admitted_digests or (recipe_only and digest not in refresh_digests):
                continue
            if digest in refresh_digests:
                original = [tuple(entry.get(field) for field in identity_fields) for entry in recipes[digest]]
                replacement = [tuple(entry.get(field) for field in identity_fields) for entry in group]
                # Old receipts may omit slot metadata. A refresh can add it,
                # while existing slot assignments remain pinned.
                slots_match = all(
                    old.get("image_slot") is None or old.get("image_slot") == new.get("image_slot")
                    for old, new in zip(recipes[digest], group)
                )
                if original != replacement or not slots_match:
                    raise ProbeError(f"refresh_recipe_member_identity: {digest}")
                if digest in refreshed and refreshed[digest] != group:
                    raise ProbeError(f"image_recipe_conflict: {digest}")
                refreshed[digest] = group
                continue
            if digest in base_digests:
                if recipes[digest] != group:
                    retained.add(digest)
                continue
            if digest in recipes and recipes[digest] != group:
                raise ProbeError(f"image_recipe_conflict: {digest}")
            recipes[digest] = group
    if refresh_digests != refreshed.keys():
        raise ProbeError("refresh_recipe_missing_from_donors")
    recipes.update(refreshed)
    recipe = list(chain.from_iterable(recipes.values()))
    recipe_indent = None if recipe_only else 2
    if len(json.dumps(recipe, indent=recipe_indent, ensure_ascii=False).encode("utf-8")) + 1 > RECIPE_LIMIT:
        raise ProbeError("replay_image_recipe_size_limit")
    added["image_recipe_containers"] = len(recipes) - len(base_digests)
    write_json(output / "combined-catalog.json", catalog)
    if not recipe_only:
        summary.update(merged)
    summary["corpus_report_sha256"] = hashlib.sha256(
        read_bounded(output / "combined-catalog.json", LIMIT)
    ).hexdigest()
    write_json(output / "image-recipe.json", recipe, indent=recipe_indent)
    write_json(output / "summary.json", summary)
    return {"added": added, "retained_base_recipe_containers": len(retained), "refreshed_recipe_containers": len(refreshed)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--donor", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--refresh-recipe", action="append", default=[], metavar="SHA256",
                        help="Replace this base recipe using a donor with identical member ranges and digests")
    parser.add_argument("--recipe-only", action="store_true", help="Refresh selected recipes without merging donor resource receipts")
    args = parser.parse_args()
    if len(args.donor) > 32:
        parser.error("at most 32 donor replays are supported")
    try:
        result = merge(absolute(args.base), [absolute(path) for path in args.donor], absolute(args.output),
                       args.refresh_recipe, recipe_only=args.recipe_only)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"{exc}\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
