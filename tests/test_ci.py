import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class CiWorkflowTests(unittest.TestCase):
    def test_tests_run_with_the_system_python(self):
        with open(os.path.join(ROOT, ".github", "workflows", "ci.yml"), encoding="utf-8") as handle:
            workflow = handle.read()
        self.assertIn("run: /usr/bin/python3 -m unittest discover -s tests -v", workflow)


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        with open(os.path.join(ROOT, ".github", "workflows", "release.yml"), encoding="utf-8") as handle:
            self.workflow = handle.read()

    def test_runs_only_on_a_version_tag(self):
        self.assertIn('  push:\n    tags: ["v*"]', self.workflow)
        self.assertNotIn("branches", self.workflow)

    def test_builds_notarizes_then_attaches_the_zip(self):
        build = self.workflow.index("./build-app.sh dist/TicketPilot.app")
        notarize = self.workflow.index("./notarize.sh dist/TicketPilot.app")
        attach = self.workflow.index("gh release")
        self.assertLess(build, notarize)
        self.assertLess(notarize, attach)

    def test_waits_for_the_approval_of_the_protected_release_environment(self):
        self.assertIn("    environment: release\n", self.workflow)

    def test_takes_its_signing_material_from_the_secrets(self):
        for secret in (
            "DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD",
            "NOTARY_KEY_P8_BASE64", "NOTARY_KEY_ID", "NOTARY_ISSUER_ID",
        ):
            self.assertIn("${{ secrets.%s }}" % secret, self.workflow)

    def test_never_prints_a_secret_and_always_deletes_the_keychain(self):
        for secret in ("$P12_PASSWORD", "$P12_BASE64", "$NOTARY_KEY_BASE64"):
            self.assertNotIn("echo \"%s" % secret, self.workflow)
            self.assertNotIn("echo %s" % secret, self.workflow)
        self.assertIn("if: always()\n        run: security delete-keychain", self.workflow)


if __name__ == "__main__":
    unittest.main()
