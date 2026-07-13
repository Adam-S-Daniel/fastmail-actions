# fastmail-actions

GitHub Actions that manage **Fastmail sending identities** ("From" addresses)
over the [JMAP](https://jmap.io/) API with a Fastmail API token. Run them from
the Actions tab (or `gh workflow run`) — no browser, no local setup.

They are the CI-side counterpart to the `fastmail-identities` skills in
[agentskills](https://github.com/Adam-S-Daniel/agentskills): those skills are now
thin wrappers that dispatch the workflows here.

| Workflow | What it does |
|---|---|
| **Add From address** (`add-from-address.yml`) | Add one or more given addresses as selectable From identities. |
| **Add received-from addresses** (`add-received-from-addresses.yml`) | Discover alias addresses you actually correspond through and add those. |
| **Tests** (`tests.yml`) | Runs the Pester suite on Linux in mock mode (CI). |

## Privacy — the report is emailed, never logged

The report contains email addresses (yours and your correspondents') and other
personal data. **This repo is public, and so are its Actions run logs**, so the
workflows never print the report. Instead each run **emails the report to the
account, from the account**, over JMAP `EmailSubmission` (the same submission
capability used to add identities). The run log shows only a one-line
confirmation. Workflow inputs (addresses, display name) are read from the event
payload and `::add-mask::`ed, so they never appear in the log either.

You receive the results in your inbox; the public log and job metadata reveal
nothing about your discovered addresses, contacts, or mailbox.

**Note on the `add-from-address` input.** The one place a specific address you
choose is submitted is the `addresses` dispatch input of `add-from-address`.
GitHub does **not** render `workflow_dispatch` input values on the public run
page or expose them via the runs API (verified), and the run log is masked — so
this is not a public surface in practice. Still, treat any address you *type* as
your own to disclose; the `add-received-from-addresses` workflow takes no address
input at all (candidates come from the API and only ever reach the emailed
report), so it never puts an address on any GitHub surface. Set
`FASTMAIL_REPORT_TO` only to an address **you control** — the report contains
personal data.

## whatif (dry run) — the default

Both action workflows take a **`whatif`** boolean input, **default `true`**.

- **`whatif = true`** — makes no changes. Emails a report of the **pre-existing**
  From addresses and the ones that **would be added**.
- **`whatif = false`** — makes the changes, then emails a report of what was
  **already present** and what was **newly added**.

## Setup — the `FASTMAIL_API_TOKEN` secret

The workflows read the token from the repository secret **`FASTMAIL_API_TOKEN`**.
You must create it once (this repo ships no token, and the value is never
committed):

1. In Fastmail: **Settings → Privacy & Security → Integrations → API tokens →
   New API token**, granting **both** of these scopes:
   - **Mail** (read-write) — to read your identities, Sent mailbox, and messages.
   - **Email Submission** — this is what backs the JMAP `submission` capability,
     which owns `Identity/get` and `Identity/set`. **Mail scope alone is not
     enough**: without Email Submission the API returns
     `403 … Disallowed capabilities … urn:ietf:params:jmap:submission`.
2. Store it as a repository secret — either in the GitHub UI
   (**Settings → Secrets and variables → Actions → New repository secret**,
   name `FASTMAIL_API_TOKEN`), or with the CLI:

   ```sh
   gh secret set FASTMAIL_API_TOKEN --repo Adam-S-Daniel/fastmail-actions
   # paste the token when prompted (it is not echoed)
   ```

Use a tightly-scoped, rotatable token (Mail + Email Submission only). The scripts
read the token from the environment only and never print or log it.

### Report routing (where the email goes)

Two optional secrets control the report email; both default to an existing
identity if unset. Because they hold addresses, store them as **secrets** (masked
in logs), not as plaintext inputs or variables:

| Secret | Purpose | Default |
|---|---|---|
| `FASTMAIL_REPORT_FROM` | From address of the report email — **must be an existing sending identity** on the account | first existing identity |
| `FASTMAIL_REPORT_TO` | Where the report is delivered | same as From |

```sh
gh secret set FASTMAIL_REPORT_FROM --repo Adam-S-Daniel/fastmail-actions
gh secret set FASTMAIL_REPORT_TO   --repo Adam-S-Daniel/fastmail-actions
```

Bootstrap note: if you want reports sent from a brand-new address, add it first
(run `add-from-address` for that address), then set `FASTMAIL_REPORT_FROM` to it.

## Running a workflow

From the **Actions** tab, pick the workflow → **Run workflow**, fill in the
inputs, and leave **whatif** on for a preview first. **The result arrives as an
email** (to `FASTMAIL_REPORT_TO`), not in the run log. Or from the CLI:

```sh
# Preview which From addresses would be added
gh workflow run add-from-address.yml --repo Adam-S-Daniel/fastmail-actions \
  -f addresses="new-alias@example.com another@example.com" -f whatif=true

# Actually add them
gh workflow run add-from-address.yml --repo Adam-S-Daniel/fastmail-actions \
  -f addresses="new-alias@example.com" -f whatif=false

# Discover alias addresses worth sending from (preview, then apply)
gh workflow run add-received-from-addresses.yml --repo Adam-S-Daniel/fastmail-actions -f whatif=true
gh workflow run add-received-from-addresses.yml --repo Adam-S-Daniel/fastmail-actions -f whatif=false
```

### Inputs

`add-from-address.yml`

| Input | Required | Default | Notes |
|---|---|---|---|
| `addresses` | yes | — | Space- or comma-separated address(es). |
| `name` | no | — | Display name; defaults to an existing identity's name. |
| `whatif` | yes | `true` | Dry run. |

`add-received-from-addresses.yml`

| Input | Required | Default | Notes |
|---|---|---|---|
| `name` | no | — | Display name; defaults to an existing identity's name. |
| `max` | no | — | Scan only the newest N messages (quick sample). |
| `min_date` | no | 730 days ago | Only consider messages sent/received on or after this date (`YYYY-MM-DD`). |
| `whatif` | yes | `true` | Dry run. |

## Repository layout

```
.github/workflows/   one workflow per action, plus the Pester CI workflow
scripts/             PowerShell (pwsh) — cross-platform, run on ubuntu-latest
  FastmailJmap.psm1  shared JMAP transport + discovery logic + reporting
  Add-FromAddress.ps1
  Add-ReceivedFromAddresses.ps1
tests/               Pester tests (*.Tests.ps1)
mocks/               fake JMAP account (session.json + fixture.json)
act/                 secrets template for local `act` runs
```

Everything is PowerShell 7 (`pwsh`), cross-platform, and the workflows run on
`ubuntu-latest`.

## How the mock mode works

Setting the env var **`FASTMAIL_MOCK_DIR`** to a directory containing
`session.json` + `fixture.json` swaps the real HTTP transport for an in-memory
fake JMAP server (`Invoke-JmapMock` in `FastmailJmap.psm1`). Mock responses are
round-tripped through JSON, so their shape is identical to a real
`Invoke-RestMethod` result — the scripts cannot tell the difference. This is what
lets both Pester and `act` exercise the real scripts end-to-end without a token.

## Local testing

**Pester (fast — no Docker, no token):**

```sh
pwsh ./test-local.ps1        # or: make test
```

Runs the whole suite (pure discovery logic + mock-mode integration + the two
entry scripts) against the fixture in `mocks/`.

**act (runs the actual workflow YAML in Docker):**

`act` is worth it here because the scripts have a real mock mode. [act](https://github.com/nektos/act)
sets `ACT=true`, which the workflows use to turn on `FASTMAIL_MOCK_DIR`, so the
whole workflow — inputs, pwsh steps, reporting — runs end-to-end against the mock
JMAP fixture with **no Fastmail token**. `.actrc` wires the runner image and a
dummy secret file (`act/secrets.example`).

```sh
pwsh ./test-local.ps1 -Act                         # all workflows,  or: make act
pwsh ./test-local.ps1 -Act -Job add-from-address   # a single one
```

Requires Docker and `act` (`gh extension install nektos/gh-act`,
`winget install nektos.act`, or `brew install act`).

## Security & privacy notes

- **No personal data in logs.** Reports are emailed, not printed. Dispatch inputs
  are read from the event payload (not string-interpolated into a `run:` block,
  which would echo them) and `::add-mask::`ed. API error messages are reduced to
  an HTTP status + JMAP error type, never a response body (which can quote an
  address).
- **Mock fixture uses only reserved `example.*` domains** — never a real address —
  so CI logs of the mock-mode tests reveal nothing.
- Actions are pinned to full-length commit SHAs with dated version comments.
- `permissions: contents: read` — the workflows need no write scopes; the
  `GITHUB_TOKEN` cannot push, comment, or alter the repo.
- The session GET disallows redirects and refuses a non-HTTPS `apiUrl`, so the
  bearer token can't be forwarded to another host.
- The Pester CI runs on `pull_request`; enable **"require approval for all
  outside collaborators"** in Actions settings so fork PRs can't run unreviewed.
- Commits use the GitHub `…@users.noreply.github.com` identity — no real address
  in commit metadata.
- The token lives only in the `FASTMAIL_API_TOKEN` secret; report addresses in
  `FASTMAIL_REPORT_FROM` / `FASTMAIL_REPORT_TO` secrets (masked). None are echoed,
  logged, or committed.
