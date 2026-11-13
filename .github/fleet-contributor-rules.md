<!-- Managed by _agent-guidance: built by scripts/build-contributor-rules.js
     from agents-md/base.md (the sections agents-md/eval-coverage.yml marks
     audience: contributor). Do not edit here; the next sync overwrites it. -->

# Fleet contributor rules

These rules apply to anyone, person or agent, changing this repository. They
are the contributor half of the fleet guidance kept in
[`_agent-guidance`](https://github.com/Adam-S-Daniel/_agent-guidance). Read
them before non-trivial work when the full guidance did not load in your
session.

## Working in these repos

- **An issue or PR labeled `on-hold` is paused by the owner.** Do not work on
  it (no commits, reviews, merges, closing or follow-ups that do it); read,
  cite and list it as on hold without asking again. A held PR stays open.
  Only the owner adds or removes the label, or an agent the owner directs in
  that session.
- Fix what was asked: no speculative features, premature abstractions or
  unused helpers. Prefer editing an existing file over creating one.
- A public interface change updates its tests; new behavior gets a test, a
  bug fix a regression test. Run the existing suite before calling a task
  complete and say what you ran.
- **American English spelling** in all text you add or change, comments and
  commits included: behavior, color, -ize.
- Tests are deterministic: no sleeps, network or wall-clock time.
- **Keep full numeric precision until the final output:** round or truncate
  only at the display or write.
- **A lint or check that reasons about code SHAPE** (which functions or
  `test()` blocks exist, what sits inside what, a call's arguments) **parses
  a real AST, never a regex or line scan** — regex cannot see a template-literal
  variable. Use `acorn`/`acorn-walk` for JS, `yaml` for YAML; regex only for a lexical token.
- Writing that goes out under Adam's name: invoke the
  `adam-writing-style` skill.
- Text to paste: give all of it, never edits.

## Security

- Validate anything crossing a trust boundary — user input, API responses,
  file contents.
- **Escape or encode untrusted data for each context it reaches**, just
  before it is placed there, with a well-established library or built-in
  (else a thoroughly vetted algorithm): HTML text or attribute, URL, YAML,
  SQL (parameterized queries), shell (arrays). Rejecting or stripping
  characters does not replace it.
- Never commit secrets, credentials or `.env` files, or disable TLS
  verification, authentication or CSRF protection.
- **Automation authenticates as a scoped GitHub App, not a PAT.**

## Data exposure in CI and public repos

CI logs, summaries, artifacts, run pages and git history are public on a
public repo.

- **Never print personal or sensitive data to a log** — emails, contacts,
  names, IDs, mailbox counts, tokens. Deliver results out-of-band (email the
  account itself); log a non-identifying status.
- **Don't interpolate `${{ inputs.* }}` / `${{ github.event.* }}` into a
  `run:` block** — the rendered command is echoed. Read inputs from
  `$GITHUB_EVENT_PATH`; `::add-mask::` sensitive values first.
- **Sensitive config goes in secrets**, not inputs or `vars`.
- **Sanitize error output** — never dump an API/HTTP body; log a status code
  plus error type, the data-bearing call inside the try/catch.
- **Least privilege:** minimal `permissions:` (usually `contents: read`);
  require approval for outside-collaborator fork PRs.
- **Fixtures use `example.com` / `example.net` only.**
- **Sanitize before the first commit.** Committed sensitive data means
  rewriting history, deleting every ref to it (branches, tags, PRs) and
  force-pushing — the one sanctioned force-push.
- **Commit with the `…@users.noreply.github.com` identity** on public repos.

## Automation vs branch protection

Fleet repos are PR-only on the default branch via ruleset, managed in
`repo-settings` (ADR 0001).

- Never design a bot that pushes to a protected default branch — rejected
  (GH013), even from its own workflows.
- Generated data goes on an unprotected results branch (skills-evals'
  `persistent/eval-results`), treated as untrusted.
- **A branch that outlives its PRs is `persistent/<purpose>`** (results,
  routine accumulation), guarded by a per-repo deletion-only
  `extra_rulesets` entry on `persistent/**` in `fleet.yml` (repo-settings
  ADR 0007). Never delete one; stale-branch cleanups skip the prefix.
- A bot that must write to a default branch needs a ruleset bypass actor
  declared in repo-settings' `fleet.yml`, never
  a hand-granted UI bypass.
- PR + auto-merge is a sanctioned bot-write path only where a repo-settings
  ADR declares the exception: the eval and guidance loops' PRs (ADRs 0003,
  0012, 0014), lesson-check PRs (0013) and the changelog routine's (0015);
  cms-platform-managed repos use it by design.
- **A required status check gets no `concurrency` group** when its job can
  fire twice on one head sha (label events, `opened` + `synchronize`): a
  cancelled run can win the context and block the merge for good.
  `cancel-in-progress: false` does not help (only the latest pending run
  survives), a shared group cancels older siblings, so make triggers pairwise
  disjoint; `push`/`synchronize`-only jobs may keep `cancel-in-progress:
  true`. Lock it with a test that parses the YAML.
- **Every CI job on pull requests is a required check** unless the repo's
  `AGENTS.md` documents why not. Ship the job and its ruleset change in one
  PR (`PUT` checked-in ruleset JSON; read back what is live).
- **Every `pull_request`/`push` workflow filters on its salient paths**
  (`/adam-coding-anywhere:workflow-path-audit`); update them when a step or
  dependency moves; table them in the repo's `AGENTS.md`.
  **A required check cannot use `on.paths`** — a missing check blocks the
  merge. Keep the trigger broad, detect salient changes in an early step,
  gate every later step on its output: the job still reports success.

## PR descriptions open with a TLDR

Start every PR description with a `## TLDR` heading and one to three
plain-English sentences on what changes and why. Only an attribution block
(HTML comments, a `_Requested by …_` line) may precede it. `agent-checks`
fails a PR without it; editing the description re-runs the check.

## A successful `git push` does not mean your commit exists

A pre-commit hook that refuses the commit does not stop the push: `git push`
pushes the base commit and prints an ordinary success. The
fleet's `secrets-scan` guard (cms-platform's `dev-hooks-sync.yml`) FAILS
CLOSED without `gitleaks` on `PATH`, which a fresh container lacks.

- **Verify the commit, not the push:** `git log --oneline -1` shows your
  message and `git status --short` is clean, or `git rev-parse HEAD` differs
  from `git rev-parse origin/<base>`.
- **`&&`-chain commit into push**; a newline or `;` lets a refused commit
  become a pushed branch.
- **Install the tool; skip the bypass.** `SKIP_SECRETS_SCAN=1` is for
  emergencies; the binary is one `curl` away.
- **A push can carry the WRONG ref while both checks pass.**
  `git push -u origin <name>` pushes the LOCAL branch of that name, maybe
  not the one you are on (the commit lands on `main` and the push
  updates a stale local branch). The only check naming commit AND
  remote branch: `git merge-base --is-ancestor <sha> origin/<branch>`, after
  every push.

## Dependency updates

Dependabot `cooldown`: `default-days: 7` (cms-platform `exclude`d);
`semver-major-days: 30` where supported (not `github-actions`). Version
updates only (advisories bypass it); unset still waits 3 days; leave
`semver-minor-days` / `-patch-days` undefined.
**By hand**, nothing watches: take the newest release past 7 days
(`npm view <pkg> time --json`), pinned exact. **Harness CLIs are unpinned**
(Claude Code, Codex; not `uses:` or SDKs): a run installs npm `latest`;
record its version and the models used.

## A name you choose becomes data a scanner reads

gitleaks' `generic-api-key` rule fires on a keyword next to a
high-entropy value:

```
access  auth  api  credential  creds  key  passwd  password  secret  token
```

Any generated file serializing such a `name: value` beside a hash looks like
a leak: **`cms-platform-secrets`** in `skills.lock` turned both consumer sites
red on every push (PR lane scans `base..head`, push lane full history; the
name outlives a rename).

- **Check a name against that list** whenever it lands in a generated
  artifact; name the purpose (`consumer-repo-provisioning`), not the
  sensitive noun.
- **Fix it at the source, not with an allowlist.** A `.gitleaksignore`
  fingerprint is `<commit>:<file>:<rule>:<line>` — repo-unique, unpropagable.
- **Do not lean on a scanner's internals.** `sha256:<hex>` dodges the rule
  only because `:` is outside its capture class.
- **Suppress by value, never by path.** A `paths` entry skips the file before
  any rule runs.

## Pinning GitHub Actions

**Two forms while repos migrate** ([ADR 0024](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/decisions/0024-actions-pin-through-lockfiles.md)):

- **Lockfile, the target:** `.github/workflows/actions.lock` covers every
  workflow; each `uses:` on its most exact tag, by hand; local actions
  `$/<path>`. Then `gh actions-lock --no-narrow`. Repos where actionlint
  meets `$/`, or with `./` refs into a runtime checkout (`cms-platform`),
  stay legacy.
- **Legacy:** full 40-character SHA, no trailing version comment.
- **Cross-repo reusable workflows take a full SHA in both forms**; no lockfile
  covers them.
- **The runner runs whatever commit the lockfile names**, even off-tag:
  require `Adam-S-Daniel/verify-actions-lock` (fails on any pin finding) and
  the Require lockfile policy. Review `actions.lock` as pins.
- **Wait 7 days after a third-party release**, else pin the previous.
- **Dereference annotated tags:** `git ls-remote <url> 'refs/tags/<tag>^{}'`.
- **The one carve-out:** `cms-platform` refs stay on its release tag.

`sha_pinning_required: true` stays on; a locked tag satisfies it.

## A test that can signal can kill every session

A mocked pid became `kill(-1, SIGKILL)`; every user process died
([evidence](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/evidence/2026-10-04-killpg-on-a-mocked-pid.md)).

- **Code that signals refuses any pid or group but an `int` > 1**, before the
  call.
- **A test that mocks a spawn patches every signal call** the code can reach.
- **A sandboxed 137 with no OOM is a finding.** Never escalate out
  (`require_escalated`, `dangerouslyDisableSandbox`); it contained the
  kill. Find what sent the signal.
- **A session that dies mid-verifier is evidence against it.** After a
  restart, find what killed it (journal, 137, `dmesg`) before re-running:
  resumed agents re-running the suite made one kill fifteen.
- **Run spawning or signaling suites in a PID namespace:**
  `unshare --user --map-current-user --pid --fork --mount-proc -- <cmd>`.

## Git practices

- Concise commit messages that explain *why*; one logical change per commit.
  Never amend published commits or force-push shared branches.
- **Merge with a merge commit — `gh pr merge --merge`.** Squash and rebase
  are off (`--squash` fails; do not offer it) except the three
  cms-platform-managed repos (`cms-platform`, `adamdaniel.ai`,
  `jodidaniel.com`), kept for Decap publishing. Squash strands commits a
  lockfile pins by sha (`cannot resolve ref`).
- **A closing keyword before `#N` or an issue/PR URL, any repo, closes it,
  PRs too**, from a PR body or any commit message; backticks don't help,
  and linked issues won't show it. To close: `Closes #N`, not
  `For #N`; else omit it. After merging, check what should stay open is.
- **Before a PR, `git log origin/<base>..HEAD --oneline` lists only this
  task's commits.** A reusable worktree (`.claude/worktrees/<name>/`) carries
  stale WIP, once a commit that *deleted* files the task edits. Anything
  extra: `git checkout -b <new> origin/<base>` and redo the work.
- **One worktree per independent coding session**, pre-authorized: reuse it
  on resume, not per turn; edit, build, test there, leaving other checkouts
  untouched. If creation fails, resolve or explain before using the shared
  checkout. No git: a separate copy. Read-only tasks and requested
  global-settings changes use targets directly.
