import contextlib
import io
import os
import subprocess
import tempfile
import unittest
from unittest import mock

from ticket_pilot import cli, commit_size

SNAPSHOT_GLOBS = ["**/__Snapshots__/**"]


class ParseNumstatTests(unittest.TestCase):
    def test_sums_additions_and_deletions(self):
        text = "10\t5\ta.swift\n3\t0\tb.swift\n"
        self.assertEqual(commit_size.parse_numstat(text, []), 18)

    def test_binary_counts_zero(self):
        text = "-\t-\timage.png\n4\t1\ta.swift\n"
        self.assertEqual(commit_size.parse_numstat(text, []), 5)

    def test_snapshot_images_excluded(self):
        text = "0\t0\tFoo/__Snapshots__/x.png\n"
        self.assertEqual(commit_size.parse_numstat(text, SNAPSHOT_GLOBS), 0)

    def test_generated_glob_excluded(self):
        text = "500\t0\tGen/Mocks.generated.swift\n2\t2\tsrc/a.swift\n"
        self.assertEqual(commit_size.parse_numstat(text, ["**/*.generated.swift"]), 4)

    def test_rename_uses_destination(self):
        text = "7\t3\told/name.txt => Foo/__Snapshots__/new.png\n"
        self.assertEqual(commit_size.parse_numstat(text, SNAPSHOT_GLOBS), 0)
        braces = "7\t3\tFoo/{a => __Snapshots__}/new.png\n"
        self.assertEqual(commit_size.parse_numstat(braces, SNAPSHOT_GLOBS), 0)
        kept = "7\t3\tFoo/{__Snapshots__ => src}/new.swift\n"
        self.assertEqual(commit_size.parse_numstat(kept, SNAPSHOT_GLOBS), 10)

    def test_rename_with_empty_side(self):
        self.assertEqual(
            commit_size.destination_path("Foo/{ => __Snapshots__}/x.png"),
            "Foo/__Snapshots__/x.png",
        )
        self.assertEqual(commit_size.destination_path("Foo/{old => }/x.png"), "Foo/x.png")

    def test_double_star_semantics(self):
        match = commit_size.matches_glob
        glob = "**/__Snapshots__/**"
        self.assertTrue(match("Foo/__Snapshots__/x.png", glob))
        self.assertTrue(match("a/b/__Snapshots__/c/d.png", glob))
        self.assertTrue(match("__Snapshots__/x.png", glob))
        self.assertFalse(match("Foo/Snapshots/x.png", glob))
        self.assertFalse(match("a/b.swift", "*.swift"))
        self.assertTrue(match("b.swift", "*.swift"))


class SizeClassTests(unittest.TestCase):
    def test_size_class_bounds(self):
        expected = {0: "XS", 1: "XS", 9: "XS", 10: "S", 49: "S", 50: "M",
                    249: "M", 250: "L", 999: "L", 1000: "XL"}
        for lines, name in expected.items():
            self.assertEqual(commit_size.size_class(lines), name, lines)


class CliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = os.path.join(self.tmp.name, "repo")
        os.mkdir(self.repo)
        env = {
            "TICKET_PILOT_HOME": os.path.join(self.tmp.name, "home"),
            "TICKET_PILOT_CONFIG": os.path.join(self.tmp.name, "missing.json"),
        }
        patcher = mock.patch.dict(os.environ, env)
        patcher.start()
        self.addCleanup(patcher.stop)
        cwd = os.getcwd()
        os.chdir(self.repo)
        self.addCleanup(os.chdir, cwd)

    def git(self, *args):
        subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.com",
             "-c", "commit.gpgsign=false", *args],
            cwd=self.repo, check=True, capture_output=True,
        )

    def write(self, name, lines):
        with open(os.path.join(self.repo, name), "w") as handle:
            handle.write("".join("line %d\n" % i for i in range(lines)))

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = cli.main(["commit-size", *argv])
        return code, out.getvalue().strip(), err.getvalue()

    def test_cli_over_threshold(self):
        self.git("init", "-q")
        self.write("big.txt", 1000)
        self.git("add", ".")
        self.git("commit", "-q", "-m", "big")
        code, out, _ = self.run_cli()
        self.assertEqual(code, 0)
        self.assertTrue(out.endswith("XL over"), out)

    def test_cli_ok_and_staged(self):
        self.git("init", "-q")
        self.write("a.txt", 3)
        self.git("add", ".")
        self.git("commit", "-q", "-m", "first")
        self.write("a.txt", 20)
        self.git("add", ".")
        code, out, _ = self.run_cli("--staged")
        self.assertEqual((code, out), (0, "17 S ok"))
        self.git("commit", "-q", "-m", "second")
        code, out, _ = self.run_cli("HEAD")
        self.assertEqual((code, out), (0, "17 S ok"))

    def test_non_ascii_generated_path_is_excluded(self):
        self.git("init", "-q")
        os.mkdir(os.path.join(self.repo, "Gén"))
        self.write(os.path.join("Gén", "café.generated.swift"), 40)
        self.write("a.txt", 3)
        self.git("add", ".")
        self.git("commit", "-q", "-m", "first")
        text = commit_size.numstat(None, False)
        self.assertEqual(commit_size.parse_numstat(text, ["**/*.generated.swift"]), 3, text)
        self.write(os.path.join("Gén", "café.generated.swift"), 80)
        self.git("add", ".")
        text = commit_size.numstat(None, True)
        self.assertEqual(commit_size.parse_numstat(text, ["**/*.generated.swift"]), 0, text)
        self.git("commit", "-q", "-m", "second")
        text = commit_size.numstat("HEAD", False)
        self.assertEqual(commit_size.parse_numstat(text, ["**/*.generated.swift"]), 0, text)

    def test_cli_not_a_repo(self):
        code, out, err = self.run_cli()
        self.assertEqual((code, out), (2, ""))
        self.assertTrue(err)

    def test_cli_invalid_rev(self):
        self.git("init", "-q")
        code, _, err = self.run_cli("nope")
        self.assertEqual(code, 2)
        self.assertTrue(err)


if __name__ == "__main__":
    unittest.main()
