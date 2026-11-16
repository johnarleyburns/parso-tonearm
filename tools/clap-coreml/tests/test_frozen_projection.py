import hashlib
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import generate_candidate_common as G  # noqa: E402

FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "frozen_projection_v1.bin"


class FrozenProjectionTests(unittest.TestCase):
    def test_reads_the_checked_in_fixture_with_no_starter_database(self):
        # The fixture is a plain file read now, not a --starter-dir sqlite lookup -- this
        # must keep working once the Jamendo starter pack (and its database) is gone entirely.
        mean, components, sha = G.frozen_projection()
        self.assertEqual(tuple(mean.shape), (512,))
        self.assertEqual(tuple(components.shape), (128, 512))
        self.assertEqual(sha, hashlib.sha256(FIXTURE.read_bytes()).hexdigest())

    def test_rejects_a_fixture_of_the_wrong_size(self):
        bad = Path(__file__).resolve().parent / "bad_projection.bin"
        bad.write_bytes(b"\x00" * 16)
        self.addCleanup(bad.unlink)
        with self.assertRaisesRegex(RuntimeError, "unexpected projection shape"):
            G.frozen_projection(bad)


if __name__ == "__main__":
    unittest.main()
