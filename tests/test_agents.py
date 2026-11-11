import os
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AGENTS_DIR = os.path.join(ROOT, "agents")
AGENT_NAMES = ["reviewer", "auditor"]


def read_agent(name):
    with open(os.path.join(AGENTS_DIR, name + ".md"), encoding="utf-8") as handle:
        return handle.read()


def split_agent(text):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, text
    fields = {}
    for index, line in enumerate(lines[1:], start=1):
        if line.strip() == "---":
            return fields, "\n".join(lines[index + 1:])
        key, separator, value = line.partition(":")
        if separator and not line.startswith((" ", "\t")):
            fields[key.strip()] = value.strip()
    return {}, text


class AgentFileTests(unittest.TestCase):
    def test_agents_have_frontmatter(self):
        for name in AGENT_NAMES:
            with self.subTest(agent=name):
                fields, body = split_agent(read_agent(name))
                self.assertEqual(fields.get("name"), name)
                self.assertTrue(fields.get("description"))
                self.assertTrue(fields.get("tools"))
                self.assertTrue(body.strip())

    def test_agents_are_read_only(self):
        for name in AGENT_NAMES:
            with self.subTest(agent=name):
                fields, _ = split_agent(read_agent(name))
                tools = [tool.strip() for tool in fields.get("tools", "").split(",")]
                self.assertEqual(tools, ["Read", "Grep", "Glob", "Bash"])
                self.assertNotIn("Edit", tools)
                self.assertNotIn("Write", tools)

    def test_reviewer_defines_output_format(self):
        _, body = split_agent(read_agent("reviewer"))
        self.assertIn("Score: <-2|-1|0|+1|+2>", body)

    def test_reviewer_marks_missing_input(self):
        _, body = split_agent(read_agent("reviewer"))
        self.assertIn("INPUT MISSING:", body)

    def test_reviewer_mentions_ci_prompt(self):
        _, body = split_agent(read_agent("reviewer"))
        self.assertIn("CI review prompt", body)

    def test_reviewer_lists_remarks_at_every_score(self):
        _, body = split_agent(read_agent("reviewer"))
        self.assertIn("one line per problem or suggestion, whatever the score", body)
        self.assertNotIn("For `0`, `+1` or `+2`, nothing after line 2", body)

    def test_auditor_checks_every_added_symbol(self):
        _, body = split_agent(read_agent("auditor"))
        self.assertIn("## Symbol pass", body)
        for check in ("**Used?**", "**Already named?**", "**Accurate?**", "**Needed?**"):
            self.assertIn(check, body)

    def test_auditor_has_three_axes(self):
        _, body = split_agent(read_agent("auditor"))
        for section in ["## Conventions", "## Necessity", "## Cleanliness"]:
            self.assertIn(section, body)

    def test_agents_find_memory_from_worktrees(self):
        for name in AGENT_NAMES:
            with self.subTest(agent=name):
                _, body = split_agent(read_agent(name))
                self.assertIn("--git-common-dir", body)
                self.assertIn("every non-alphanumeric character", body)


if __name__ == "__main__":
    unittest.main()
