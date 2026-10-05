# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

Only what is **specific to this account and learned the hard way**; depth
lives in each repo's `docs/` and the skills registry. Delivered once per
session to BOTH `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, so a rule for
every agent goes here, not in `~/.claude/AGENTS.md` (one tool only). Keep it
under 25 KiB; Codex silently cuts a full-mode AGENTS.md at 32 KiB.

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
- **A lint or check that reasons about code SHAPE** (which functions or
  `test()` blocks exist, what sits inside what, a call's arguments) **parses
  a real AST, never a regex or line scan** — regex cannot see a template-literal
  variable. Use `acorn`/`acorn-walk` for JS, `yaml` for YAML; regex only for a lexical token.
- Writing that goes out under Adam's name: invoke the
  `adam-writing-style` skill.

## Anything you name gets its link

Any noun the reader might open gets its URL in the same sentence:
**what you hand over** (jodidaniel.com#176: three turns of "waiting on a
human approval", no location), **what YOU are waiting on** (every time you
name it), **what you cite as DONE** (2026-08-29: "documented in the issue, the
changelog" — no links).

- **Link the surface that decides, not its parent.** A required environment
  review lives on its job page, `.../actions/runs/<run_id>/job/<job_id>`, not
  the PR; resolve the run `waiting` on the CURRENT head. With two surfaces
  (the regression gate: Actions and `/admin/reviews/`), give both and say
  which you verified.
- **A link is not a description** — one clause of identification travels with
  it. A bare `repo#123` autolinks only inside that repo; elsewhere, full URL.
- **No URL? Say so** — "No link — local task `abc123`, output at `/tmp/…`".
- **Stop naming it once it stops blocking** — cancel the check-in on a merged PR or finished run, and say so.

## Finding your unknowns

Ambiguities surface *during* implementation. Before: name what you don't
know, preferring a code reference to prose. During: surface departures
and edge cases. After: explain what changed and why it is correct. Durable
findings go in the repo, not agent memory: a fleet rule in
`_agent-guidance`'s `agents-md/base.md`, a repo fact below
`## Repo-specific additions`, a procedure in the skills registry. A note in
`~/.claude/projects/*/memory/` is a POINTER: `metadata.home` names that copy as
`<owner>/<repo>:<path>`, the memory-home Stop hook blocks a session that wrote
one without it, and a `type: user` note about the person is exempt. The
**`finding-unknowns`** skill is the full workflow: use it on unfamiliar code,
a new domain or subjective criteria.

## Workstation layout

- Clones live under Windows
  `D:\repos\<github-owner-or-org>\<repo>` (never `C:\Users\<user>\...`),
  WSL `~/repos/<repo>`.

## Security

- Validate anything crossing a trust boundary — user input, API responses,
  file contents.
- Never build SQL, shell commands or HTML by concatenating untrusted data:
  parameterized queries, shell arrays, context-aware escaping.
- Never commit secrets, credentials or `.env` files.
- Never disable TLS verification, authentication or CSRF protection.

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

## Network allowlists live in `_agent-guidance/docs/reference/`

Two egress allowlists, reference copies with a `.CHANGELOG.md` sidecar;
nothing loads them. Add a changelog entry when you change one.

- `network-allowlist-claude-environments.txt` — in force for the Claude
  Code cloud environment `My Whitelist`; the dialog at claude.ai/code is
  authoritative.
- `network-allowlist-github-runners.txt` — proposed for CI; unenforceable
  on a standard runner (roadmap #821 closed).

Traps: `*.example.com` does **not** match the apex `example.com`; the "also
include default list…" checkbox adds ~200 domains.

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
- PR + auto-merge is not a sanctioned bot-write path, bar skills-evals' roster
  PR (repo-settings ADR 0003); cms-platform-managed repos use it by design.
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

## Two GitHub connectors, and which one you are holding

`get_me` cannot tell the two GitHub MCP servers apart; establish which you
hold before writing.

- **`mcp__github__*` — session-provisioned**, not in `ListConnectors`. The
  only one with Actions tools (`actions_*`), job logs (`get_job_logs`),
  auto-merge and review-thread resolution. Reach: the attached repos.
- **`mcp__github-mcp__*` — the claude.ai org connector `github-mcp`**, listed
  by `ListConnectors`. A strict subset: same reads and
  PR/issue/merge/push/delete writes; no Actions, job logs, auto-merge or
  review threads. Reach: a GitHub App allowlist INDEPENDENT of the
  attached repos. **Probe for it by connector NAME, never a remembered
  prefix** (`mcp__b26ebb34-…__*` until 2026-08-28). It CAN check a PR —
  `pull_request_read` with `method: "get_check_runs"` and `"get_status"`;
  read BOTH (#83: `get_status` `pending` while every check run was green) —
  but cannot dispatch or read a workflow RUN, and a merge under it is
  synchronous (no `enable_pr_auto_merge`).
- **Fewer tools is not less dangerous.** Both merge, push and delete; the
  subset's reach cannot be inferred from the session's repo list (2026-08-19:
  `github-mcp` 404s on private `repo-settings`).

Prefer `mcp__github__`; use `github-mcp` only when the other cannot see a
repo, say so, and name the connector in each verification.

## A GitHub 404 means "not authorized", not "not there"

GitHub answers 404, not 403, to a caller not allowed to know a private repo
exists, so every 404 is ambiguous: gone, or invisible to that credential.

- **Probe the repo, not the object.** If `GET /repos/<owner>/<repo>/pulls`
  404s too, the repo is invisible (a scope gap); if only the object does, it
  is gone.
- **Try the other connector first** (2026-08-19: a mid-session MCP reconnect
  brought up a server blind to a private repo the other read;
  `add_repo` "already attached" is session scope).
- **Git is a separate credential path:** `git ls-remote origin '<ref>'` asks
  "does this branch exist", `git merge-base --is-ancestor <sha> origin/main`
  "was it merged"; neither touches the API.
- Never report a repo, PR or branch gone on a 404 alone; say which
  credential could not see it and what you checked with.

## The fleet spans TWO owners, and a scoped search will not say so

`Adam-S-Daniel` and `jodidaniel`, both in `SYNC_OWNERS` (_agent-guidance's
`sync.yml` and sibling workflows): enumerate it, never hardcode one. A
query scoped to one owner returns a plausible, complete-shaped, wrong
result (2026-08-25: a `user:Adam-S-Daniel` search "proved" jodidaniel.com
had no `skills.lock`).

- **Prefer the fleet's registries** (`repos.yml`, `fleet.yml`,
  `cron_coverage.fleet`) to a search index; a zero result is weak
  evidence. **To ask whether repo X has file Y, ask the repo**
  (`git ls-remote`, the contents API).
- **Your session's reach is not the fleet's shape** — it is per-session and
  may miss an owner; "I cannot see it" and "it does not exist" differ.
- **The DENOMINATOR is the part that lies.** Enumerating local checkouts
  errs both ways (2026-08-29: three DELETED repos counted, a live consumer
  missed — `ALL PROPAGATED` over 17 of 18, false GREEN; issue #37). Take it
  from a registry or the remote, never the disk, and say which.

## "The watch finished" is not "CI passed"

Never read pass/fail off a watch command's exit code: in `cmd | tail` `$?` is
`tail`'s, a backgrounded watch reports that pipeline code, and `tail -N`
hides FAILURE lines.

- Capture the real code with `${PIPESTATUS[0]}`, or don't pipe the watch.
- After any CI watch, query the conclusions and report the parsed result:

  ```bash
  gh pr view <n> --repo <owner>/<repo> --json statusCheckRollup --jq \
    '.statusCheckRollup[] | (.conclusion // .state) as $c
     | select($c != null and $c != "SUCCESS" and $c != "NEUTRAL")
     | "\(.name // .context): \($c)"'
  ```

  A check run carries `.conclusion`, a legacy status `.state`; filter on one
  and the other reads clean. "Watch done" means "now verify".
- **A pipe into `grep -q` is a race.** `grep -q` exits at the first match, so
  past the 64 KiB pipe buffer the writer dies 141 and `pipefail` reads a
  present marker as absent (issue #81; 20 trials per size: 48 kB 0/20,
  95 kB 18/20). Feed data as an argument or here-string —
  `grep -qxF -- "$m" <<<"$s"`.
  A size-dependent bug needs trials, not a probe; say how many.
  `$( ... || true )` is safe by accident — say so where you find it.
- **`gh api ... --jq` on an HTTP error prints the raw error body to stdout**,
  so `|| true` captures it. Discard explicitly:
  `out=$(gh api ... --jq '.foo') || out=""`.

## A successful `git push` does not mean your commit exists

A pre-commit hook that refuses the commit does not stop the push: `git push`
pushes the base commit and prints an ordinary success. The
fleet's `secrets-scan` guard (cms-platform's `dev-hooks-sync.yml`) FAILS
CLOSED without `gitleaks` on `PATH`, which a fresh container lacks
(2026-08-25, adamdaniel.ai).

- **Verify the commit, not the push:** `git log --oneline -1` shows your
  message and `git status --short` is clean, or `git rev-parse HEAD` differs
  from `git rev-parse origin/<base>`.
- **`&&`-chain commit into push**; a newline or `;` lets a refused commit
  become a pushed branch.
- **Install the tool; skip the bypass.** `SKIP_SECRETS_SCAN=1` is for
  emergencies; the binary is one `curl` away.
- **A push can carry the WRONG ref while both checks pass.**
  `git push -u origin <name>` pushes the LOCAL branch of that name, maybe
  not the one you are on (2026-08-29: the commit landed on `main` and
  the push updated a stale local branch). The only check naming commit AND
  remote branch: `git merge-base --is-ancestor <sha> origin/<branch>`, after
  every push.

## Dependency updates

Dependabot `cooldown`: `default-days: 7` (cms-platform `exclude`d, #424);
`semver-major-days: 30` where supported (not `github-actions`, #133). Version
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
  any rule runs (cms-platform#260).

## Pinning GitHub Actions

**Every `uses:` is pinned to a full 40-character commit SHA** — workflows,
composite actions and reusable-workflow refs alike; never a tag, branch or
abbreviated SHA.

- **A pin carries NO trailing version comment.** Nothing maintains it, so it
  lies (2026-08-20: Dependabot left stale comments beside moved SHAs in
  GHA-bench#52 and skills-evals #38/#39/#40). Resolve one with
  `git ls-remote <url> | grep <sha>`.
- **Wait 7 days after a third-party release**, else pin the previous.
- **Dereference annotated tags.** `gh api .../git/ref/tags/<tag>` with
  `.object.type == "tag"` gives the tag object's SHA, which fails at runtime;
  use `git ls-remote <url> 'refs/tags/<tag>^{}'`.
- **The one carve-out: a ref into this account's own `cms-platform` stays on
  its release tag, in both shapes** — reusable workflow
  `Adam-S-Daniel/cms-platform/.github/workflows/<x>.yml@v0.1.88` and composite
  action `Adam-S-Daniel/cms-platform/.github/actions/<x>@v0.1.88` —
  because `check-platform-pin-consistency.js` asserts each equals
  `platform.lock`'s `platform_ref`.
- `./local/path` and `docker://` refs have nothing to pin.

`sha_pinning_required: true` (`repo-settings`' `fleet.yml`; `cms-platform`'s
`repo-settings.yml`) governs actions only, so a tag in a *third-party*
reusable-workflow ref is for review to catch.

## A test that can signal can kill every session

2026-10-04: a skills-evals test ([#250](https://github.com/Adam-S-Daniel/skills-evals/pull/250))
mocked `Popen`; cleanup's `os.killpg(proc.pid, SIGKILL)` hit the mock.
`MagicMock` converts to the int `1` and `killpg(1, sig)` is `kill(-1, sig)`:
every user process died.

- **Code that signals refuses any pid or group but an `int` > 1**, before the
  call.
- **A test that mocks a spawn patches every signal call** the code can reach.
- **A sandboxed 137 with no OOM is a finding.** Never escalate out
  (`require_escalated`, `dangerouslyDisableSandbox`); it contained the
  kill. Find what sent the signal.
- **A session that dies mid-verifier is evidence against it.** After a
  restart, find what killed it (journal, 137, `dmesg`) before re-running:
  resumed agents re-running the suite made one kill fifteen (2026-10-04).
- **Run spawning or signaling suites in a PID namespace:**
  `unshare --user --map-current-user --pid --fork --mount-proc -- <cmd>`.

## Subagent delegation (model routing)

- Don't write code in the orchestrating session: delegate to a subagent or
  child session on a cheaper model — the cheapest capable tier for
  exactly-specified edits, a mid tier for a clear spec; escalate rather than
  ship a wrong diff on anything subtle. The orchestrator keeps root cause,
  architecture, the spec (files, exact changes, house style, test command) and
  diff review. A child that skips this
  file (Explore/Plan or `omitClaudeMd` agents, SDK harnesses with
  `settingSources: []`) needs constraints in its prompt.
- Delegated work is done when a verifier exits 0: name the exact
  command, run LAST (a trailing `echo $?` hides the tool's code), and
  require its code back. "Cannot run it" is BLOCKED; a count off-spec,
  stop-and-report; a self-contradicting report ("2 failed",
  "exit 0"), re-run it. **Prove the verifier can fail first:**
  `python3 test_foo.py` with no `__main__` block exits 0 having asserted
  nothing (2026-08-22). Name the RUNNER (`python3 -m pytest <paths> -q`),
  never the file, and require the test COUNT beside the exit code.
- **A working subagent OWNS the tree — do not commit or push under it.** A
  push mid-flight plus its `git commit --amend` diverges a published branch
  (2026-08-22; recover by reset and a fresh commit, never force-push), and its
  `git checkout -- <file>` discards your edits. Wait for a clean `git status`
  plus a recorded result; decline a stop hook's "commit and push" nudge.
- **A subagent that has REPORTED can still be holding the tree**: its
  BACKGROUND CHILDREN are not reaped (2026-08-29: an orphan test loop turned
  a 999/0 tree into 985/14). Look for descendants before trusting a long run
  (`ps -eo pid,etimes,cmd | grep '[y]our-command'`); `md5sum` inputs before
  and after (differ → not evidence); prefer a per-run output path; kill
  orphans, and say so.
- **A subagent that goes quiet is not working — check activity, not the
  clock.** Its transcript's mtime is the signal; fix the staleness threshold
  and the fallback in advance.
- **A live-test prompt states the credential boundary** — which
  `HOME`/profile, what it may read, and that it must not copy real
  credentials to pass. Supply a throwaway one or run
  unauthenticated; else it's the operator's call.
- **A scratch tree can still reach production.** `cp -a` copies
  `.git/config`, so a copy inherits `origin`; but `git remote remove origin`
  in a `git worktree` strips the PARENT's remote. Run `/adam-coding-anywhere:disarm-inherited-reach`
  before disarming.

## Skills ecosystem

- The registry is `Adam-S-Daniel/adam-agentskills`: plugins
  `adam-anything-anywhere`, `adam-coding-anywhere`,
  `adam-coding-local`, `adam-non-coding-local`; invoke
  `/<plugin>:<skill>`; `setup.sh` sets up a machine.
- **A `git push` failing in EVERY repo**: retired sync-skills hook targets a
  deleted script; `setup.sh --owner-machine` removes it.
- Cloud/ephemeral sessions get no plugins from repo-declared settings
  (registry ADR 0001): the repo's `skills.lock` and `skills-bootstrap`
  SessionStart hook install the bundles, digest-verified; read the
  `skills:` verdict at start.
- **Adoption is opt-in and double-keyed:** an entry in `_agent-guidance`'s
  `repos.yml` AND a `skills.lock` the repo committed itself (the sync never
  writes one). Bundles cost always-on context, so a repo may be deliberately
  out — check for `skills.lock`, don't guess.
- **Terminals load the claude.ai account's skills** as `/<name>` (or
  `/anthropic-skills:<name>` if taken); `setup.sh` opts a machine out
  (`syncClaudeAiSkills: false`), cloud can't (registry ADR 0010).
- New reusable skills graduate into the registry (sensitive ones in
  `adam-agentskills-private`); a long skill splits across files.

## Two setup gaps you may close, and must not nag about

No repo can commit either; both are silent when missing. **Detect first;
say nothing when the check passes.** Once per session, not as a greeting, not only for skills work.

**Cloud (claude.ai) — PROMPT, never act.** Resolve `$project` first:
`$CLAUDE_PROJECT_DIR` when set (**unset** in `remote_mobile`), else the
nearest ancestor of the cwd holding more than one repo checkout; an empty
value probes `/` and silently suppresses the prompt.
Prompt only when all four hold:

1. hosted — entrypoint `remote*`/`claude_in_slack`/`claude-in-slack`/
   `claude-in-teams`, **or** `$CLAUDE_CODE_REMOTE_SESSION_ID` is set;
2. multi-repo — `$project` has no `skills.lock` but a child does;
3. `$project/.claude/settings.json` does not already register a
   `skills-bootstrap` SessionStart hook;
4. some child ships `.claude/hooks/skills-bootstrap.sh`.

Then say it once, naming the snippet's home (adam-agentskills'
`docs/multi-repo-delivery.md`; do not paraphrase it), and drop it.

**Durable machine — ACT, then one line.** `claude plugin marketplace list
--json` returns `[]` when nothing is configured: absent → `claude plugin
marketplace add Adam-S-Daniel/adam-agentskills` and install the plugins wanted;
marketplace behind → `claude plugin marketplace update adam-agentskills`;
install behind → below; both current → silence.
Use CLI ≥ 2.1.280 for recorded commits (older updates kept stale SHAs).
After refreshing the clone (`installLocation`), compare each `gitCommitSha`
in `~/.claude/plugins/installed_plugins.json` with `git -C <clone> rev-parse HEAD`:
equal is current, different needs inspection, missing is unknown. Locate the
bundle via `installPath`; a marketplace refresh does not update it.
The clone is `--depth 1`, so ancestry/count checks may exit 128.
Try `claude plugin update`, then recheck; if still stale, uninstall/reinstall
(registry ADR 0009's version-gate case). Updates load next session. Neither
belongs in a repo's `AGENTS.md`.

## Git practices

- Concise commit messages that explain *why*; one logical change per commit.
  Never amend published commits or force-push shared branches.
- **Merge with a merge commit — `gh pr merge --merge`.** Squash and rebase
  are off (`--squash` fails; do not offer it) except the three
  cms-platform-managed repos (`cms-platform`, `adamdaniel.ai`,
  `jodidaniel.com`), kept for Decap publishing. Squash strands commits a
  lockfile pins by sha (2026-08-15: `cannot resolve ref`).
- **A closing keyword before `#N` or an issue/PR URL, any repo, closes it,
  PRs too**, from a PR body or any commit message; backticks don't help,
  and linked issues won't show it (cms-platform#283 via `78617e1`,
  _agent-guidance#136 by cms-platform#434). To close: `Closes #N`, not
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
