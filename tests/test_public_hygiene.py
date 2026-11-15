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
    "94b27686cacb28da0eedcfa08bd50b284ed29948c1c6d7259c7a97dd266bd8a8": 11,
    "6c296fde55b852788be0818c74fc20be7554d5fede6bbd3d421965755dd3d0c1": 7,
    "f0db20bde5226b49bea62cadbc421d3fd8a142c8afb8851eb4ceec939a5586e6": 10,
    "7f15adbb3ecd5f7658a6d56d23d27c00ac8bb75647f81248d0f4bf644a038d10": 9,
    "94c7b80678b71545aa471cc8b8a9c0f2daac7ab81542302e8b0e9d0d37aac41a": 8,
    "4e1690527bdf3a16f3472edfd46dfe6930a1f1aaa7d6678a4c3f2eda17b8ef46": 17,
    "707a9cc8f614ef255597fc668e11d7699041945d65032462d0a11f1f2a8645df": 17,
    "72f894e07e492998f1ab5b710127b96c788b815f8662f6b82d8a15cc4b29953e": 16,
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
