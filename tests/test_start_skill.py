import os
import re
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_DIR = os.path.join(ROOT, "skills", "start")
SKILL_PATH = os.path.join(SKILL_DIR, "SKILL.md")
REFERENCES = ["references/test-plan-format.md", "references/commit-splitting.md"]
STEP_HEADING = re.compile(r"^## Step (\d+) — ", re.MULTILINE)
SEND_COMMANDS = ("git push", "git review", "gh pr create")
NOT_RUN_MARKERS = ("do not run", "never run")


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def skill():
    return read(SKILL_PATH)


def frontmatter(text):
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return {}
    fields = {}
    for line in lines[1:]:
        if line.strip() == "---":
            return fields
        key, separator, value = line.partition(":")
        if separator and not line.startswith((" ", "\t")):
            fields[key.strip()] = value.strip().strip('"')
    return {}


def step_sections(text):
    matches = list(STEP_HEADING.finditer(text))
    sections = {}
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        sections[int(match.group(1))] = text[match.start():end]
    return sections


def skill_files():
    return [SKILL_PATH] + [os.path.join(SKILL_DIR, name) for name in REFERENCES]


class StartSkillTests(unittest.TestCase):
    def test_frontmatter(self):
        fields = frontmatter(skill())
        self.assertEqual(fields.get("name"), "start")
        self.assertIn("Jira ticket", fields.get("description", ""))
        self.assertEqual(fields.get("argument-hint"), "<JIRA-KEY>")

    def test_has_ten_step_headings(self):
        numbers = [int(number) for number in STEP_HEADING.findall(skill())]
        self.assertEqual(numbers, list(range(1, 11)))

    def test_absolute_rule_first(self):
        text = skill()
        step_one = text.index("## Step 1 — ")
        rule = text.lower().find("nothing visible to others without an explicit yes")
        self.assertNotEqual(rule, -1, "absolute rule is missing")
        self.assertLess(rule, step_one)
        head = text[:step_one].lower()
        for action in ["push", "pull request", "comment", "vote", "jira transition", "slack message"]:
            with self.subTest(action=action):
                self.assertIn(action, head)

    def test_each_step_records_progress(self):
        sections = step_sections(skill())
        self.assertEqual(sorted(sections), list(range(1, 11)))
        for number, section in sections.items():
            with self.subTest(step=number):
                self.assertRegex(section, r'tp"? run-step <id> %d\b' % number)

    def test_waits_are_recorded(self):
        text = skill()
        for kind in ["go", "question", "launch_app"]:
            with self.subTest(kind=kind):
                self.assertRegex(text, r'tp"? run-wait <id> %s "' % kind)

    def test_never_pushes(self):
        for path in skill_files():
            for number, line in enumerate(read(path).split("\n"), start=1):
                lowered = line.lower()
                if any(command in lowered for command in SEND_COMMANDS):
                    with self.subTest(file=os.path.relpath(path, ROOT), line=number):
                        self.assertTrue(
                            any(marker in lowered for marker in NOT_RUN_MARKERS),
                            "send command without 'do not run': %s" % line,
                        )

    def test_co_authored_by_is_allowed_unless_forbidden(self):
        section = step_sections(skill())[9]
        self.assertIn("you may add the `Co-Authored-By` line", section)
        self.assertIn("unless the repo's conventions or the user's instructions forbid it", section)
        self.assertNotIn("never add co-authored-by", skill().lower())

    def test_commit_size_used_before_commit(self):
        section = step_sections(skill())[9]
        size = section.find("commit-size --staged")
        commit = section.find("git commit")
        self.assertNotEqual(size, -1, "step 9 must measure staged changes")
        self.assertNotEqual(commit, -1, "step 9 must show the commit command")
        self.assertLess(size, commit)

    def test_jira_line_only_when_validated(self):
        text = skill()
        self.assertIn("--jira-line", text)
        self.assertIn("JIRA: <KEY>", step_sections(text)[9])

    def test_run_is_done_at_the_end(self):
        self.assertRegex(step_sections(skill())[10], r'tp"? run-done <id>')

    def test_references_exist_and_are_linked(self):
        text = skill()
        for name in REFERENCES:
            with self.subTest(reference=name):
                self.assertTrue(os.path.isfile(os.path.join(SKILL_DIR, name)))
                self.assertIn(name, text)

    def test_references_are_used_at_their_steps(self):
        sections = step_sections(skill())
        self.assertIn("references/test-plan-format.md", sections[7])
        self.assertIn("references/commit-splitting.md", sections[9])

    def test_reviewer_input_missing_is_not_a_pass(self):
        texts = {
            "step 9": step_sections(skill())[9],
            "commit-splitting": read(os.path.join(SKILL_DIR, "references/commit-splitting.md")),
        }
        for name, text in texts.items():
            with self.subTest(source=name):
                self.assertIn("a reason not starting with `INPUT MISSING:`", text)
                self.assertIn("re-run the reviewer", text)

    def test_split_unstages_before_first_commit(self):
        section = step_sections(skill())[9]
        measure = section.find("git add -A")
        unstage = section.find('git -C "<worktree>" reset -q')
        self.assertNotEqual(unstage, -1, "step 9 must unstage before splitting")
        self.assertLess(measure, unstage)
        reference = read(os.path.join(SKILL_DIR, "references/commit-splitting.md"))
        self.assertIn('git -C "<worktree>" reset -q', reference)

    def test_resume_and_prepare_reuse_the_run_worktree(self):
        text = skill()
        resume = text[text.index("## Resume"):]
        self.assertIn("only if they are recorded", resume)
        self.assertNotIn("If the run was waiting", resume)
        prepare = step_sections(text)[2]
        self.assertIn("belongs to this run", prepare)
        self.assertIn("reuse it", prepare)
        self.assertRegex(prepare, r'tp"? run-wait <id> question "')

    def test_resume_recomputes_the_base_commit(self):
        text = skill()
        command = re.search(r"`(git -C \"<worktree>\" merge-base [^`]+)`", step_sections(text)[2])
        self.assertIsNotNone(command, "step 2 must compute <base> with merge-base")
        resume = text[text.index("## Resume"):]
        recompute = resume.find(command.group(1))
        self.assertNotEqual(recompute, -1, "resume must recompute <base> as step 2 does")
        self.assertIn("step 3 or later", resume)
        self.assertLess(recompute, resume.index("restart it with `run-step`"))

    def test_ticket_key_is_normalized_and_validated(self):
        from ticket_pilot import runs
        head = skill()[:skill().index("## Absolute rule")]
        self.assertIn("first word", head)
        self.assertIn("uppercase", head)
        self.assertIn("`%s`" % runs.KEY_PATTERN, head)
        self.assertIn("stop", head)
        self.assertIn("`/ticket-pilot:start <KEY>`", head)

    def test_merged_code_is_read_from_the_remote_branch(self):
        section = step_sections(skill())[3]
        self.assertIn('git -C "<repo>" log origin/<main_branch> --grep', section)
        self.assertIn('git -C "<repo>" grep', section)
        self.assertIn("never their working tree", section)

    def test_absolute_rule_has_a_catch_all(self):
        text = skill()
        head = text[:text.index("## Step 1 — ")].lower()
        self.assertIn("any other action that someone else can see or that changes a shared system", head)
        self.assertIn("nothing visible to others without an explicit yes", step_sections(text)[3].lower())


    def test_test_plan_format_forbids_code_references(self):
        text = read(os.path.join(SKILL_DIR, "references", "test-plan-format.md")).lower()
        self.assertIn("no code references", text)
        for word in ("file paths", "path:line", "endpoint paths", "backticks"):
            self.assertIn(word, text)

    def test_test_plan_example_has_no_code(self):
        text = read(os.path.join(SKILL_DIR, "references", "test-plan-format.md"))
        example = text[text.index("## Example"):].split("```")[1]
        self.assertNotIn("`", example)
        self.assertIsNone(re.search(r"\w/\w", example))
        self.assertIsNone(re.search(r":\d+", example))

    def test_research_looks_for_local_work_in_progress(self):
        section = step_sections(skill())[3]
        self.assertIn("Local work in progress", section)
        self.assertIn("for-each-ref refs/heads --sort=-committerdate", section)
        self.assertIn('git -C "<repo>" log --branches --not origin/<main_branch> --source -i --grep', section)
        self.assertIn('git -C "<repo>" log origin/<main_branch>..<branch> -i -G "<term>" --oneline', section)
        self.assertIn('git -C "<repo>" diff origin/<main_branch>...<branch> | grep -i "<term>"', section)
        self.assertNotIn('grep -l "<term>" <branch>', section)
        self.assertIn("A candidate branch is", section)
        self.assertIn("branch names", section)
        self.assertIn("Exclude the run's own branch", section)
        self.assertIn("nothing reads", section)
        self.assertRegex(section, r'tp"? run-wait <id> question "<in the user\'s language: is branch')
        self.assertIn("primary reference", section)
        self.assertIn("not as merged", section)

    def test_compare_table_has_a_local_branch_column(self):
        self.assertIn("Local branch", step_sections(skill())[4])

    def test_app_test_never_touches_a_user_launched_app(self):
        section = step_sections(skill())[7].lower()
        whole_step = section[:section.index("\n1. ")]
        self.assertIn("never install, reinstall, rebuild or relaunch", whole_step)
        self.assertIn("means ready, not permission", whole_step)
        self.assertIn("debug menu", section)
        self.assertIn("never edit generated or shipped config files", section)

    def test_app_test_checks_the_proxy_rules(self):
        section = step_sections(skill())[7]
        self.assertIn("proxy's active rules", section)
        self.assertRegex(section, r'tp"? run-wait <id> question "<in the user\'s language: [^"]*disabl')
        self.assertIn("Never leave a rule you enabled active", section)
        plan = read(os.path.join(SKILL_DIR, "references", "test-plan-format.md"))
        self.assertIn("real (unaltered) traffic", plan)

    def test_autonomy_rule_before_questions(self):
        text = skill()
        self.assertIn("**Autonomy.**", text)
        self.assertLess(text.index("**Autonomy.**"), text.index("**Questions.**"))
        for needle in ("the app you drive", "My ads", "run-shell", "genuinely cannot obtain", "what you already tried"):
            self.assertIn(needle, text)
        sections = step_sections(text)
        for number in (2, 6, 7):
            self.assertIn("autonomy rule", sections[number])
        self.assertIn("never ask the user to confirm that no rule is active", sections[7])

    def test_user_language_and_register_everywhere(self):
        text = skill()
        head = text[:text.index("## Absolute rule")]
        self.assertIn("only in the language decided at the start", head)
        self.assertIn("language and register", head)
        self.assertIn("progress narration", head)
        self.assertIn("never paste or echo them", head)
        self.assertIn("CLAUDE.md, memory", head)
        self.assertIn("write the report in the user's language", step_sections(text)[3])

    def test_checklist_tool_fallback_is_silent(self):
        text = skill()
        startup = text[text.index("## Start-up"):text.index("## Step 1 — ")]
        self.assertIn("When the task tool is not available", startup)
        self.assertIn("do not mention it to the user", startup)
        self.assertIn("`run-step` only", startup)

    def test_every_question_is_recorded_with_its_text(self):
        text = skill()
        head = text[:text.index("## Start-up")]
        self.assertIn("Every question to the user", head)
        self.assertIn('tp" run-wait <id> <kind> "<the question text, in the user\'s language>"', head)
        self.assertIn("never an empty text", head)

    def test_question_templates_are_in_the_user_language(self):
        text = skill()
        templates = re.findall(r'tp"? run-wait <id> (\w+) "([^"]*)"', text)
        self.assertGreaterEqual(len(templates), 6)
        for kind, template in templates:
            with self.subTest(kind=kind, template=template):
                self.assertTrue(template.startswith("<"), "template must be a placeholder")
                self.assertIn("in the user's language", template)
        self.assertNotIn("to the commits?", text)
        self.assertNotIn("is taken; use", text)

    def test_resume_checklist_only_with_the_task_tool(self):
        resume = skill()[skill().index("## Resume"):]
        self.assertIn("Recreate the checklist when the task tool is available", resume)

    def test_missing_key_lists_the_runs(self):
        text = skill()
        head = text[:text.index("## Absolute rule")]
        self.assertRegex(head, r'tp"? run-list')
        startup = text[text.index("## Start-up"):text.index("## Step 1 — ")]
        self.assertIn("Not inside a git repo", startup)
        self.assertRegex(startup, r'tp"? run-list')

    def test_ticket_title_is_recorded_in_step_one(self):
        self.assertRegex(step_sections(skill())[1], r'tp"? run-set <id> --title "')

    def test_requests_are_recorded_and_reused_on_resume(self):
        text = skill()
        self.assertRegex(step_sections(text)[1], r'tp"? run-set <id> --request "')
        resume = text[text.index("## Resume"):]
        self.assertIn("recorded `requests`", resume)

    def test_feedback_after_the_report_reopens_the_run(self):
        text = skill()
        after = text[text.index("## After the report"):text.index("## Resume")]
        reopen = after.find('tp" run-step <id> 5')
        done = after.find('tp" run-done <id>')
        self.assertNotEqual(reopen, -1, "a code change after the report must reopen the run")
        self.assertLess(reopen, done)
        self.assertIn("reviewer and auditor", after)

    def test_each_commit_regenerates_untracked_files(self):
        self.assertIn("regenerate what git does not track", step_sections(skill())[9])
        reference = read(os.path.join(SKILL_DIR, "references/commit-splitting.md"))
        self.assertIn("regenerate what git does not track", reference)
        self.assertIn("""--exec '"<plugin-root>/bin/tp" run-shell <id> "<setup> && """, reference)

    def test_app_test_never_builds_its_own_driving_tool(self):
        section = step_sections(skill())[7]
        self.assertIn("never write your own tooling to drive the app", section)
        self.assertIn("system permissions", section)

    def test_ci_review_is_replayed_on_each_commit(self):
        sections = step_sections(skill())
        self.assertIn("it is not the CI review itself", sections[8])
        step_nine = sections[9]
        self.assertIn('TP_REV=<sha> TP_BASE=<base> TP_WORKTREE="<worktree>" <ci_review_command>', step_nine)
        self.assertIn("If it can post, comment or vote anywhere, do not run it", step_nine)
        self.assertIn("never a pass", step_nine)
        self.assertIn("the CI review was not replayed", sections[10])
        reference = read(os.path.join(SKILL_DIR, "references/commit-splitting.md"))
        self.assertIn("replay the CI review on that commit", reference)

    def test_ci_review_job_is_found_when_not_configured(self):
        step_nine = step_sections(skill())[9]
        self.assertIn("**Without `ci_review_command`**", step_nine)
        self.assertIn("without the publishing step", step_nine)
        self.assertRegex(step_nine, r'tp"? run-wait <id> question "<in the user\'s language: the CI review job found')
        self.assertIn("never into the repo or the worktree", step_nine)
        self.assertIn("a job only **referenced** there", step_nine)
        self.assertIn("ask before cloning it", step_nine)
        self.assertIn("also runs locally", step_nine)

    def test_skill_reads_the_repo_memory_itself(self):
        text = skill()
        head = text[:text.index("## Start-up")]
        self.assertIn("The user's memory for this repo", head)
        self.assertIn("every non-alphanumeric character replaced by `-`", head)
        self.assertIn("a rule of the memory wins over a default of this skill", head)

    def test_commit_subject_is_never_generic(self):
        section = step_sections(skill())[9]
        self.assertIn("Never a generic word", section)

    def test_unread_sources_are_asked_not_guessed(self):
        section = step_sections(skill())[1]
        self.assertIn("never guess its content, not even from the description", section)
        self.assertIn("ask the user to paste each unread source", section)

    def test_report_has_a_coverage_list(self):
        text = skill()
        self.assertIn("Coverage", step_sections(text)[7])
        self.assertIn("Coverage", step_sections(text)[10])

    def test_worktree_commands_go_through_run_shell(self):
        text = skill()
        self.assertIn('"<plugin-root>/bin/tp" run-shell <id>', text)
        self.assertIn("run-shell", step_sections(text)[2])
        self.assertNotIn('eval "$("<plugin-root>/bin/tp" run-env', text)
        splitting = read(os.path.join(SKILL_DIR, "references/commit-splitting.md"))
        self.assertIn("run-shell <id>", splitting)
        self.assertIn("git rebase --exec", splitting)
        self.assertNotIn('eval "$(', splitting)

    def test_language_is_recorded_and_checked_before_every_message(self):
        text = skill()
        self.assertRegex(text, r'tp"? run-set <id> --language <code>')
        self.assertIn("On resume, read `language`", text)
        self.assertIn("Before EVERY message to the user", text)
        for word in ("status summaries", "errors and blockers", "never paste or echo"):
            self.assertIn(word, text)


if __name__ == "__main__":
    unittest.main()
