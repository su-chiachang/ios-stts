#!/usr/bin/env python3
"""Create a publishable Audio8 release manifest from local artifacts.

This is the App-repository entry point for the native Audio8 manifest
generator. A release package must name an HTTPS base URL explicitly; local
audit manifests remain available through the native tool but are never used
as an App download catalog.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Callable, Optional, Sequence
from urllib.parse import urlparse


DEFAULT_AUDIO8_SOURCE_DIR = Path(__file__).resolve().parents[2] / "audio8.cpp"


class ReleasePackagingError(ValueError):
    """Raised when a release package cannot satisfy the publishable contract."""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generator-f32", required=True, type=Path)
    parser.add_argument("--generator-q8", required=True, type=Path)
    parser.add_argument("--codec", required=True, type=Path)
    parser.add_argument("--tokenizer", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--release-base-url",
        required=True,
        help="HTTPS directory containing the uploaded release artifacts",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        default=Path(
            os.environ.get("AUDIO8_SOURCE_DIR", str(DEFAULT_AUDIO8_SOURCE_DIR))
        ),
        help="audio8.cpp checkout (default: sibling ../audio8.cpp)",
    )
    parser.add_argument(
        "--native-tool",
        type=Path,
        help="override tools/audio8_release_manifest.py under --source-dir",
    )
    return parser


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    return build_parser().parse_args(argv)


def validate_release_base_url(value: str) -> str:
    parsed = urlparse(value)
    if (
        parsed.scheme != "https"
        or not parsed.netloc
        or parsed.query
        or parsed.fragment
    ):
        raise ReleasePackagingError(
            "--release-base-url must be an HTTPS URL without query or fragment"
        )
    return value.rstrip("/")


def native_tool_for(args: argparse.Namespace) -> Path:
    return args.native_tool or args.source_dir / "tools" / "audio8_release_manifest.py"


def build_native_command(args: argparse.Namespace, native_tool: Path) -> list[str]:
    release_base_url = validate_release_base_url(args.release_base_url)
    return [
        sys.executable,
        str(native_tool),
        "--generator-f32",
        str(args.generator_f32),
        "--generator-q8",
        str(args.generator_q8),
        "--codec",
        str(args.codec),
        "--tokenizer",
        str(args.tokenizer),
        "--output",
        str(args.output),
        "--release-base-url",
        release_base_url,
        "--require-release-url",
    ]


def main(
    argv: Optional[Sequence[str]] = None,
    *,
    run: Callable[..., object] = subprocess.run,
) -> int:
    args = parse_args(argv)
    # Validate the trust boundary before touching any local tool path. This
    # keeps malformed hosting configuration deterministic even on a machine
    # without the sibling native checkout.
    validate_release_base_url(args.release_base_url)
    native_tool = native_tool_for(args)
    if not native_tool.is_file():
        raise ReleasePackagingError(
            f"native Audio8 release tool does not exist: {native_tool}"
        )
    command = build_native_command(args, native_tool)
    run(command, check=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ReleasePackagingError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
