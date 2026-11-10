# Commit splitting (step 9)

`"<plugin-root>/bin/tp" commit-size --staged` measures what is staged; `"<plugin-root>/bin/tp" commit-size <sha>` measures an existing commit. Both print `<lines> <class> <ok|over>`: added + removed lines, tests included, files matching `generated_globs` and `snapshot_globs` excluded, compared with `max_commit_lines` (999 by default).

## When to split

- Stage the whole change and measure it. `ok` → one single commit, toggle included. Never split a change that is under the threshold.
- `over` → split it yourself, without asking, following the order below. Every commit must also measure `ok`.
- **A toggle clean-up is always one single commit**, whatever its size: it mostly removes code. Use the repo's toggle-cleaning skill if it has one, then check that no dead code and no use of the toggle is left (search the toggle's name and its key in the whole worktree).

## Toggle rule

The same rule on every platform:

- the whole change fits in **one commit** (toggle included) → the toggle is created **in that commit**;
- the change must be split → the **toggle creation goes alone, first**.

## Order of the commits

1. toggle creation;
2. data (network, models, storage);
3. domain (use cases, business rules);
4. presentation (view models, formatting);
5. view;
6. accessibility, always last.

Tests go with the code they test, snapshots with the view change they reflect. Incomplete wiring is accepted as long as the commit builds.

## Making the commits

The whole change was staged to measure it. Unstage everything first, so that each commit starts from an empty index: `git -C "<worktree>" reset -q`.

Then, for each commit, in order:

1. Stage only its files or hunks: `git -C "<worktree>" add <paths>` (for part of a file, write a patch of the wanted hunks and `git -C "<worktree>" apply --cached <patch>`; keep the patch outside the worktree).
2. Measure: `cd "<worktree>" && "<plugin-root>/bin/tp" commit-size --staged` must print `ok`.
3. Commit with the message of step 9.

At the end, `git -C "<worktree>" status --porcelain` is empty and `git -C "<worktree>" diff <base>` equals the change reviewed in step 8.

## Verifying each commit

Oldest first, for each commit `<sha>` of `git -C "<worktree>" log --reverse --format=%H <base>..HEAD`. A rebase rewrites every later commit, so recompute this list after each rebase and continue from the position you reached.

1. Check it out in the worktree (`git -C "<worktree>" checkout --detach <sha>`), build, run the tests. Go back with `git -C "<worktree>" checkout <branch>`.
2. Run the reviewer on `git -C "<worktree>" show <sha>` with the step 8 inputs.
3. Score 0 or more and a reason not starting with `INPUT MISSING:` → next commit. A reason starting with `INPUT MISSING:` → fix the input and re-run the reviewer; it is never a pass.
4. Score -1 or -2 → fix it in that commit:
   1. on the branch, make the fix and stage it;
   2. `cd "<worktree>" && git commit --fixup=<sha>`;
   3. `cd "<worktree>" && GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash <base>`;
   4. re-verify **the whole chain**: every commit builds and passes its tests, for example `cd "<worktree>" && git rebase --exec "<build command> && <test command>" <base>`;
   5. recompute the commit list (the shas changed), run the reviewer again on the rewritten commit, then carry on with the next one.

The final branch holds only the planned commits: no fixup commit is left.
