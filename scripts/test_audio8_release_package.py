from __future__ import annotations

from argparse import Namespace
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parent))

from audio8_release_package import (  # noqa: E402
    ReleasePackagingError,
    build_native_command,
    main,
    parse_args,
)


class Audio8ReleasePackageTests(unittest.TestCase):
    def test_release_command_forces_publishable_manifest_validation(self):
        args = parse_args(
            [
                "--generator-f32",
                "/models/f32.gguf",
                "--generator-q8",
                "/models/q8.gguf",
                "--codec",
                "/models/codec.gguf",
                "--tokenizer",
                "/models/tokenizer.json",
                "--output",
                "/tmp/audio8-release.json",
                "--release-base-url",
                "https://downloads.example/audio8/v1",
            ]
        )

        command = build_native_command(
            args, Path("/opt/audio8.cpp/tools/audio8_release_manifest.py")
        )

        self.assertEqual(
            command,
            [
                sys.executable,
                "/opt/audio8.cpp/tools/audio8_release_manifest.py",
                "--generator-f32",
                "/models/f32.gguf",
                "--generator-q8",
                "/models/q8.gguf",
                "--codec",
                "/models/codec.gguf",
                "--tokenizer",
                "/models/tokenizer.json",
                "--output",
                "/tmp/audio8-release.json",
                "--release-base-url",
                "https://downloads.example/audio8/v1",
                "--require-release-url",
            ],
        )

    def test_packaging_rejects_non_https_release_base_before_native_call(self):
        runner = Mock()

        with self.assertRaisesRegex(ReleasePackagingError, "HTTPS"):
            main(
                [
                    "--generator-f32",
                    "/models/f32.gguf",
                    "--generator-q8",
                    "/models/q8.gguf",
                    "--codec",
                    "/models/codec.gguf",
                    "--tokenizer",
                    "/models/tokenizer.json",
                    "--output",
                    "/tmp/audio8-release.json",
                    "--release-base-url",
                    "http://downloads.example/audio8/v1",
                    "--native-tool",
                    "/opt/audio8.cpp/tools/audio8_release_manifest.py",
                ],
                run=runner,
            )

        runner.assert_not_called()

    def test_release_base_url_is_required(self):
        with redirect_stderr(StringIO()), self.assertRaises(SystemExit):
            parse_args(
                [
                    "--generator-f32",
                    "/models/f32.gguf",
                    "--generator-q8",
                    "/models/q8.gguf",
                    "--codec",
                    "/models/codec.gguf",
                    "--tokenizer",
                    "/models/tokenizer.json",
                    "--output",
                    "/tmp/audio8-release.json",
                ]
            )

    def test_packaging_delegates_to_native_tool(self):
        runner = Mock()
        with TemporaryDirectory() as directory:
            native_tool = Path(directory) / "audio8_release_manifest.py"
            native_tool.touch()
            args = [
                "--generator-f32",
                "/models/f32.gguf",
                "--generator-q8",
                "/models/q8.gguf",
                "--codec",
                "/models/codec.gguf",
                "--tokenizer",
                "/models/tokenizer.json",
                "--output",
                "/tmp/audio8-release.json",
                "--release-base-url",
                "https://downloads.example/audio8/v1",
                "--native-tool",
                str(native_tool),
            ]

            self.assertEqual(main(args, run=runner), 0)
            runner.assert_called_once_with(
                build_native_command(
                    Namespace(
                        generator_f32=Path("/models/f32.gguf"),
                        generator_q8=Path("/models/q8.gguf"),
                        codec=Path("/models/codec.gguf"),
                        tokenizer=Path("/models/tokenizer.json"),
                        output=Path("/tmp/audio8-release.json"),
                        release_base_url="https://downloads.example/audio8/v1",
                    ),
                    native_tool,
                ),
                check=True,
            )


if __name__ == "__main__":
    unittest.main()
