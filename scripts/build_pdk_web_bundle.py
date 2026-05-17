#!/usr/bin/env python3
"""Create a small browser-loadable Sky130 PDK bundle.

The browser build cannot read a user's local PDK_ROOT, so this script copies the
subset of an enabled Ciel/open_pdks tree that the web app can serve as static
assets: xschem symbols, ngspice model files, and a JSON manifest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_SYMBOL_DIRS = (
    "libs.tech/xschem/sky130_fd_pr",
    "libs.tech/xschem/sky130_fd_sc_hd",
)

DEFAULT_MODEL_PATTERNS = (
    "libs.tech/ngspice/**/*.spice",
    "libs.tech/ngspice/**/*.lib",
    "libs.ref/sky130_fd_pr/spice/**/*.spice",
    "libs.ref/sky130_fd_sc_hd/spice/**/*.spice",
)


@dataclass(frozen=True)
class ManifestFile:
    path: str
    size: int
    sha256: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_text_lossy(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def extract_braced_block(text: str, start: int) -> str:
    depth = 0
    block_start = -1
    for index in range(start, len(text)):
        char = text[index]
        if char == "{":
            if depth == 0:
                block_start = index + 1
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and block_start >= 0:
                return text[block_start:index]
    return ""


def extract_symbol_metadata(symbol_path: Path, rel_path: str) -> dict:
    text = read_text_lossy(symbol_path)
    metadata: dict[str, object] = {
        "id": symbol_path.stem,
        "name": symbol_path.stem,
        "library": symbol_path.parent.name,
        "symbol_path": rel_path,
        "type": "",
        "template": "",
        "pins": [],
    }

    k_index = text.find("K {")
    if k_index >= 0:
        k_block = extract_braced_block(text, k_index)
        metadata["type"] = extract_token_value(k_block, "type")
        metadata["template"] = extract_quoted_value(k_block, "template")

    pins = []
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if not stripped.startswith("B "):
            continue
        brace_index = stripped.find("{")
        if brace_index < 0:
            continue
        attrs = extract_braced_block(stripped, brace_index)
        pin_name = extract_token_value(attrs, "name")
        pin_dir = extract_token_value(attrs, "dir")
        if pin_name:
            pins.append({"name": pin_name, "dir": pin_dir})
    metadata["pins"] = pins

    return metadata


def extract_token_value(text: str, key: str) -> str:
    needle = key + "="
    index = text.find(needle)
    if index < 0:
        return ""
    value_start = index + len(needle)
    value_end = value_start
    while value_end < len(text) and not text[value_end].isspace():
        value_end += 1
    return text[value_start:value_end].strip('"')


def extract_quoted_value(text: str, key: str) -> str:
    needle = key + '="'
    start = text.find(needle)
    if start < 0:
        return ""
    start += len(needle)
    end = start
    escaped = False
    while end < len(text):
        char = text[end]
        if char == '"' and not escaped:
            return text[start:end]
        escaped = char == "\\" and not escaped
        if char != "\\":
            escaped = False
        end += 1
    return text[start:]


def copy_file(src: Path, dst: Path) -> ManifestFile:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return ManifestFile(path=dst.as_posix(), size=dst.stat().st_size, sha256=sha256_file(dst))


def iter_symbols(pdk_dir: Path, symbol_dirs: Iterable[str]) -> Iterable[Path]:
    for symbol_dir in symbol_dirs:
        root = pdk_dir / symbol_dir
        if root.exists():
            yield from sorted(root.glob("*.sym"))


def iter_model_files(pdk_dir: Path, patterns: Iterable[str]) -> Iterable[Path]:
    seen: set[Path] = set()
    for pattern in patterns:
        for path in sorted(pdk_dir.glob(pattern)):
            if path.is_file() and path not in seen:
                seen.add(path)
                yield path


def resolve_pdk_dir(pdk_root: Path, pdk_family: str) -> Path:
    def is_open_pdks_dir(path: Path) -> bool:
        return (path / "libs.tech").exists() and (path / "libs.ref").exists()

    direct = pdk_root / pdk_family
    if is_open_pdks_dir(direct):
        return direct
    if pdk_root.name == pdk_family and is_open_pdks_dir(pdk_root):
        return pdk_root

    if is_open_pdks_dir(pdk_root):
        return pdk_root

    ciel_family = pdk_root / "ciel" / pdk_family
    current_file = ciel_family / "current"
    if current_file.exists():
        current_version = current_file.read_text(encoding="utf-8").strip()
        for variant in (pdk_family, pdk_family + "A", pdk_family + "B"):
            candidate = ciel_family / "versions" / current_version / variant
            if is_open_pdks_dir(candidate):
                return candidate

    versions_dir = ciel_family / "versions"
    if versions_dir.exists():
        for version_dir in sorted(versions_dir.iterdir(), reverse=True):
            if not version_dir.is_dir():
                continue
            for variant in (pdk_family, pdk_family + "A", pdk_family + "B"):
                candidate = version_dir / variant
                if is_open_pdks_dir(candidate):
                    return candidate

    raise SystemExit(f"Could not find an enabled {pdk_family!r} PDK under {pdk_root}")


def build_bundle(args: argparse.Namespace) -> None:
    pdk_dir = resolve_pdk_dir(args.pdk_root.expanduser().resolve(), args.pdk_family)
    output_dir = args.output.expanduser().resolve()
    bundle_root = output_dir / args.pdk_family
    bundle_root.mkdir(parents=True, exist_ok=True)

    symbol_entries = []
    copied_files: list[ManifestFile] = []

    for symbol_path in iter_symbols(pdk_dir, args.symbol_dir):
        source_rel = symbol_path.relative_to(pdk_dir)
        dest_rel = Path("symbols") / source_rel
        copied = copy_file(symbol_path, bundle_root / dest_rel)
        copied_files.append(ManifestFile(dest_rel.as_posix(), copied.size, copied.sha256))
        symbol_entries.append(extract_symbol_metadata(symbol_path, dest_rel.as_posix()))

    for model_path in iter_model_files(pdk_dir, args.model_pattern):
        source_rel = model_path.relative_to(pdk_dir)
        dest_rel = Path("models") / source_rel
        copied = copy_file(model_path, bundle_root / dest_rel)
        copied_files.append(ManifestFile(dest_rel.as_posix(), copied.size, copied.sha256))

    manifest = {
        "schema": 1,
        "pdk_family": args.pdk_family,
        "source_pdk_dir": str(pdk_dir),
        "virtual_pdk_root": f"pdks/{args.pdk_family}",
        "symbols": sorted(symbol_entries, key=lambda item: str(item["id"])),
        "files": [entry.__dict__ for entry in sorted(copied_files, key=lambda item: item.path)],
    }

    manifest_path = bundle_root / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"Wrote {manifest_path}")
    print(f"Copied {len(symbol_entries)} symbols and {len(copied_files) - len(symbol_entries)} model files.")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pdk-root",
        type=Path,
        default=Path(os.environ.get("PDK_ROOT", "~/.ciel")),
        help="Path to the Ciel/open_pdks root, or directly to the sky130 directory.",
    )
    parser.add_argument("--pdk-family", default="sky130", help="PDK family directory to bundle.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("project/build/web/release/pdks"),
        help="Output directory that will contain <pdk-family>/manifest.json.",
    )
    parser.add_argument(
        "--symbol-dir",
        action="append",
        default=list(DEFAULT_SYMBOL_DIRS),
        help="PDK-relative directory containing .sym files. Can be repeated.",
    )
    parser.add_argument(
        "--model-pattern",
        action="append",
        default=list(DEFAULT_MODEL_PATTERNS),
        help="PDK-relative glob for ngspice model files. Can be repeated.",
    )
    return parser.parse_args()


if __name__ == "__main__":
    build_bundle(parse_args())
