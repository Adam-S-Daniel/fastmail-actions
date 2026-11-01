<!-- BEGIN MANAGED SECTION — DO NOT EDIT ABOVE "## Repo-specific additions" -->
<!-- Source: _agent-guidance -->
<!-- Sections: none -->
<!-- Mode: stub -->

# AGENTS.md

> **Managed by [`_agent-guidance`].**
> Edit only below the `## Repo-specific additions` header.
> Everything above it will be overwritten on the next sync.

guidance-marker: fleet-stub (transcript counts use this line; keep it)

## Fleet guidance is delivered once per session — not by this file

The account's full guidance — incidents, fleet policy, machine layout, the
traps that cost real outages — is installed into **user memory**
(`~/.claude/CLAUDE.md`) by the `fleet-memory` SessionStart hook, so it is
loaded **once per session** no matter how many repos are attached
([inlined per repo, it took 332.3k tokens](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/evidence/2026-08-29-guidance-inlined-in-every-repo.md)).

**Check the session-start verdict before you rely on it.** The hook prints one
line:

- `fleet-guidance: installed (v<id>, <n> bytes)` or `fleet-guidance: current` —
  the full guidance is in context. Use it.
- `fleet-guidance: DEGRADED — <reason>` — it is **not** in context. You have
  only what is below. Read `agents-md/base.md` in the `_agent-guidance`
  checkout (or on GitHub) before non-trivial work, and say in your reply that
  you were running degraded.
- `fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set)` — also not in context,
  but by the machine owner's deliberate choice, not a fault. User memory is
  GLOBAL on a durable machine, so the guidance would otherwise load in every
  unrelated project on that box; `FLEET_GUIDANCE_SKIP` opts out and removes any
  block an earlier session installed. Read `agents-md/base.md` the same way you
  would when degraded — just don't report it as a problem or try to "fix" it.

No verdict at all means the hook never ran — treat that as DEGRADED.

**Say what loaded, in your first reply to the user in a session.** The
installed guidance ends with a line `fleet-guidance check value: <8 hex>`.
Begin that reply with `fleet-guidance check: <the value>`, copied from that
line, or `fleet-guidance check: none` when no such line is in your context.
Never guess a value or copy one from anywhere else: the session's record
compares it with what actually loaded. Only in replies to the user — never in
commits, PR or issue text, files or prompts for other agents.

## Codex reads the same block, from `~/.codex/AGENTS.md`

The hook writes the same block there whenever `~/.codex` exists. Setup for
local Codex and Codex Cloud, and how to verify delivery:
[`docs/codex-cloud.md`](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/codex-cloud.md).

## The floor: rules that hold even when the guidance did not load

These are the ones with teeth. They are restated here, deliberately, because a
session that lost the guidance must not also lose these.

- **Branch protection is real.** Fleet repos are PR-only on their default
  branch; a direct push is rejected (GH013), even from the repo's own
  workflows. Never design a bot that pushes to a protected default branch.
- **Every `uses:` is pinned through `.github/workflows/actions.lock`: an
  exact tag, locked, checked by a required `gh actions-lock --verify`
  failing on any pin finding.** A repo not yet migrated keeps the legacy
  form, a full 40-character commit SHA with no trailing version comment,
  until its migration PR; never mix the two in one repo. Cross-repo
  reusable workflows take a full SHA either way. The one carve-out is a ref
  into this account's own `cms-platform`, which stays on its release tag.
- **Never commit secrets or `.env` files, and never print personal data to a
  CI log** — logs, artifacts and git history on a public repo are public.
- **A successful `git push` does not mean your commit exists.** A refused
  pre-commit hook still lets the push report success. Verify with
  `git merge-base --is-ancestor <sha> origin/<branch>` — it is the only check
  that names both the commit and the ref.
- **"The watch finished" is not "CI passed."** Read the parsed conclusions;
  never infer pass/fail from a watch command's exit code.
- **A GitHub 404 means "not authorized", not "not there."** Never report a
  repo, PR or branch as gone on a 404 alone.
- **The fleet spans TWO owners** — `Adam-S-Daniel` and `jodidaniel`. A query
  scoped to one returns a plausible, complete-shaped, wrong answer.
- **Anything you name gets its link** — what you hand over, what you are
  waiting on, and what you cite as already done.
- **Merge with a merge commit** (`gh pr merge --merge`), except in the three
  cms-platform-managed repos (`cms-platform`, `adamdaniel.ai`,
  `jodidaniel.com`), which squash; do not amend published commits or
  force-push shared branches.
- **Keep this file under 32 KiB.** Codex truncates project instructions at
  that byte silently; the sync warns and the drift report flags
  `codex-truncated`.

<!-- END MANAGED SECTION -->
## Repo-specific additions

<!-- Add your repo-specific agent guidance below this line -->

### Action pins

Workflows name third-party actions by release tag; [`.github/workflows/actions.lock`](.github/workflows/actions.lock) locks each tag to an exact commit, and the runner runs the locked commit even when it disagrees with the tag. The `pester` job's "Verify action lockfile" step is the shared action [`Adam-S-Daniel/verify-actions-lock`](https://github.com/Adam-S-Daniel/verify-actions-lock). It runs `gh actions-lock --verify` only when a PR touches workflow dependencies, and fails on any finding except `cooldown-config-ignored` (dependabot.yml's cooldown `exclude`, which the tool ignores). It is not the only guard: the runner rejects forged pins, and GitHub's Require lockfile policy is on. Write the exact tag by hand, regenerate with `gh actions-lock --no-narrow`, and commit both files; review an `actions.lock` diff as you would a SHA pin. A stale or moved pin is fixed with `gh actions-lock --accept-moved`; review the diff. A `reachability-unknown` failure means the GitHub API was unreachable: re-run. Cross-repo reusable workflows (`jobs.<id>.uses`) are not locked, so they take a full commit SHA (`Adam-S-Daniel/cms-platform` refs excepted); a test enforces it. Fleet rule: [ADR 0024](https://github.com/Adam-S-Daniel/_agent-guidance/blob/main/docs/decisions/0024-actions-pin-through-lockfiles.md).
