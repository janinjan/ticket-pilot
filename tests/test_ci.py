import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class CiWorkflowTests(unittest.TestCase):
    def test_tests_run_with_the_system_python(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as handle:
            workflow = handle.read()
        self.assertIn("run: /usr/bin/python3 -m unittest discover -s tests -v", workflow)


if __name__ == "__main__":
    unittest.main()
