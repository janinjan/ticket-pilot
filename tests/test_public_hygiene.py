import hashlib
import os
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# SHA-256 hex digest of each lowercase forbidden term -> length of the term,
# so that the terms themselves never appear in this public repository.
FORBIDDEN_DIGESTS = {
    "80f6e4d50f07dbe4bdfba3ae8055644c04a30a8450af3e291b67fe8d61ba2d03": 7,
    "20fe643e9f507627c209fff7a851192b3e61d4383cadeabf4711f65182c39f0e": 9,
    "4045fd9a84b268883f98c0cda013e57cb493130146623d8d2c50a177de6bb86d": 8,
    "1e4c930dd0a36d02bc2e1ba5904a7d68b68f5cd8a9a07aba5586ecf38c5c96c1": 12,
    "66760c907c32ba6339d8f74aa208a9e14524df8d8228c9f21a2b89cde878558e": 9,
    "7cc826203b303441489b7c102b85c7d7b9aeec1878a331c512defdc97eb0b189": 4,
    "521d046070f8d253d8d2b3637b676aaeee5b392419cfbb39418fb22caf3dc75f": 4,
}
TERM_LENGTHS = sorted(set(FORBIDDEN_DIGESTS.values()))


def contains_forbidden_term(line):
    lowered = line.lower()
    for length in TERM_LENGTHS:
        for start in range(len(lowered) - length + 1):
            chunk = lowered[start:start + length].encode("utf-8")
            if FORBIDDEN_DIGESTS.get(hashlib.sha256(chunk).hexdigest()) == length:
                return True
    return False


def tracked_files():
    output = subprocess.run(
        ["git", "-c", "core.quotePath=false", "ls-files", "-z"],
        cwd=ROOT, check=True, capture_output=True,
    ).stdout.decode("utf-8")
    return [name for name in output.split("\0") if name]


class PublicHygieneTests(unittest.TestCase):
    def test_no_internal_terms(self):
        hits = []
        for rel in tracked_files():
            try:
                with open(os.path.join(ROOT, rel), encoding="utf-8") as handle:
                    lines = handle.readlines()
            except (UnicodeDecodeError, OSError):
                continue
            for number, line in enumerate(lines, start=1):
                if contains_forbidden_term(line):
                    hits.append("%s:%d: forbidden term" % (rel, number))
        self.assertEqual(hits, [], "internal terms found: " + ", ".join(hits))

    def test_detects_a_hashed_term(self):
        term = "xegc"[::-1]
        self.assertTrue(contains_forbidden_term("prefix %s suffix" % term.upper()))
        self.assertFalse(contains_forbidden_term("nothing to see here"))


if __name__ == "__main__":
    unittest.main()
