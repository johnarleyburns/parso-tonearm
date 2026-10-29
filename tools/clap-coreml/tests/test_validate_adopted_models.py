import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import validate_adopted_models as v  # noqa: E402

A, T, P = "a" * 64, "b" * 64, "c" * 64


class ValidatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.dims = [128]
        v.output_dimensions = lambda package: self.dims

    def make(self, kind, sha, **over):
        pkg = self.root / f"CLAP{kind.title()}Encoder.mlpackage"
        pkg.mkdir()
        (self.root / f".{pkg.name}.sha256").write_text(sha + "\n")
        m = {"component": kind, "dimensions": 128, "precision": "int4",
             "quantization": {"dtype": "int4"}, "projection_sha256": P}
        m.update(over)
        (pkg / "manifest.json").write_text(json.dumps(m))
        return pkg

    def run_validator(self, **over):
        audio = self.make("audio", A, **over.get("audio", {}))
        text = self.make("text", T, **over.get("text", {}))
        return v.main(["--audio", str(audio), "--text", str(text), "--audio-sha256", A,
                       "--text-sha256", T, "--projection-sha256", P])

    def test_accepts_adopted_pair(self):
        self.assertEqual(self.run_validator(), 0)

    def test_rejects_wrong_projection(self):
        self.assertEqual(self.run_validator(text={"projection_sha256": "d" * 64}), 1)

    def test_rejects_non_int4(self):
        self.assertEqual(self.run_validator(audio={"precision": "int8", "quantization": {"dtype": "int8"}}), 1)

    def test_rejects_wrong_component(self):
        self.assertEqual(self.run_validator(text={"component": "audio"}), 1)

    def test_rejects_512_output(self):
        self.dims = [512]
        self.assertEqual(self.run_validator(), 1)

    def test_rejects_old_archive_marker(self):
        audio = self.make("audio", "e" * 64)
        text = self.make("text", T)
        self.assertEqual(v.main(["--audio", str(audio), "--text", str(text), "--audio-sha256", A,
                                 "--text-sha256", T, "--projection-sha256", P]), 1)


if __name__ == "__main__":
    unittest.main()
