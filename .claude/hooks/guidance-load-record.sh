#!/usr/bin/env bash
# guidance-load-record.sh — one line per session: did Claude Code load the FULL
# fleet guidance, or only the repo stub? And, in cloud sessions only, one line
# per skill use naming the skill copy it loaded (phase 2, ADR 0036). Cloud
# lines go to one private destination per session: the private repo's branch
# (ADR 0036), or, when the S3 sink is configured, a private S3 bucket that the
# private repo ingests from (ADR 0037). Nowhere else.
#
# WHAT IT COUNTS
# --------------
# The full guidance (agents-md/base.md) reaches a session through user memory,
# installed by the fleet-memory SessionStart hook; each repo's AGENTS.md
# carries only the stub (agents-md/stub.md). Whether the first actually loaded
# is the question, and a session's transcript answers it: Claude Code (seen in
# 2.1.312) writes an entry
#   {"type":"attachment","attachment":{"type":"instructions","files":[
#     {"path":...,"type":"User"|"Project"|...,"content":"..."}]}}
# listing every memory file it loaded and its text, with HTML comments
# STRIPPED, so the `<!-- fleet-guidance-version -->` comment is not there.
# base.md and stub.md therefore each carry one visible line,
# `guidance-marker: fleet-full` and `guidance-marker: fleet-stub`, which
# scripts/check-fleet-guidance-mirror.js keeps unique. A session is
#   full       — some loaded file carries the fleet-full marker, or the legacy
#                signature `## Working in these repos` (base.md before the
#                marker existed);
#   stub-only  — otherwise, some file carries the fleet-stub marker or the
#                legacy `Fleet guidance is delivered once per session`;
#   neither    — the transcript lists instruction files, none of them either;
#   unknown    — three or more assistant responses and still no instructions
#                entry (an older CLI, or a format change).
#
# THE RECORD
# ----------
# One JSON line appended to
# ${XDG_STATE_HOME:-$HOME/.local/state}/fleet-guidance/sessions.jsonl:
#   {"v":1,"ts":"2026-10-31T12:00:00Z","kind":"guidance-load",
#    "session":"<16 hex>","surface":"cli","remote":false,"cli":"2.1.312",
#    "state":"full","repos":2,"guidance_version":"0123abcd",
#    "check_expected":true,"check_reported":"match",
#    "registry_sha":null,"sources":[{"registry":"<owner>/<repo>","ref":"<40 hex>"}],
#    "sources_dropped":0,"listing":"full","uploaded":null}
# `session` is a sha256 prefix of the session id, never the id. `surface` and
# `cli` are the transcript's own `entrypoint` and `version`, or null when the
# value is not one the private reader accepts (see SURFACE_RE and CLI_RE).
# `repos` counts the distinct directories holding a Project-type AGENTS.md or
# CLAUDE.md (a `<repo>/.claude/CLAUDE.md` counts as `<repo>`). `guidance_version` is the
# 8-hex id fleet-memory.sh wrote into user memory's CLAUDE.md. `check_expected`
# and `check_reported` are described under THE CHECK VALUE below.
# `registry_sha` is always null, kept for readers that look it up: one session
# can install from several registries, so `sources` holds them instead.
# `sources` lists the skills registries and commits skills-bootstrap.sh last
# installed from, read from the top-level `sources` list of its install record,
# $HOME/.claude/skills/.skills-bootstrap-installed.json. Only an entry whose
# `registry` is https://github.com/<owner>/<repo>[.git] and whose `ref` is 40
# lowercase hex is kept, as "<owner>/<repo>"; entries are deduped and sorted,
# and at most 16 kept. `sources_dropped` counts the entries rejected or past
# the cap. Both are null when the install record is missing, not a regular
# file, over 1 MiB, unreadable, or has no `sources` list (installs before
# _agent-guidance#398 had none). `uploaded` is true or false when an upload was
# tried, null when it was not. `listing` is optional: "full" or "truncated"
# when the transcript holds the session's first skill listing (an `attachment`
# of type skill_listing with isInitial true), "truncated" when a
# skill is listed by name alone, and absent (the key is omitted) when no such
# listing is found. Any skill, bare or namespaced, listed by name alone
# reads "truncated". Never "full" without that proof. Apart from registry owner/repo names, this
# record holds no paths, names, titles or file content. (Phase 2's lines, below,
# carry skill names, tool-use ids and digests, and go to the private store or
# the private bucket only.)
#
# THE CHECK VALUE
# ---------------
# A session can claim "full guidance loaded" without it being true. So the block
# fleet-memory.sh installs ends with a plain-text line
# `fleet-guidance check value: <8 hex>` that exists nowhere else (see CHECK
# VALUE in that hook), and the repo stub asks the session to begin its first
# reply to the user with `fleet-guidance check: <value>`, or
# `fleet-guidance check: none` when it saw no such line. Two fields compare the
# two, and neither holds a value string:
#   check_expected  true when some loaded User-type instruction file has a line
#                   matching ^fleet-guidance check value: ([0-9a-f]{8})$; false
#                   when none does; null when the state is `unknown`. Only User
#                   files count: a repo file cannot supply the expected value.
#   check_reported  the first `fleet-guidance check: (<8 hex>|none)` found in
#                   the assistant's text blocks, in transcript order:
#                   match     the hex equals the expected value;
#                   mismatch  a hex, and no expected value or a different one;
#                   none      the session said it saw no check line;
#                   absent    no report line in any assistant text so far.
# The transcript is read as parsed JSON, entry by entry, never searched as raw
# text. The record is written once, at the first Stop that has something to
# record, so `absent` means "not by then".
#
# UPLOAD (cloud only, optional)
# -----------------------------
# A cloud container's state dies with it, so when the session is remote
# (CLAUDE_CODE_REMOTE=true or CLAUDE_CODE_REMOTE_SESSION_ID set) the same line
# (without `uploaded`) is sent by ONE of two routes, chosen per session:
#   the S3 sink   when USAGE_SINK_BUCKET and USAGE_SINK_REGION are set with
#                 either USAGE_SINK_SIGNING=proxy (the agent proxy signs) or
#                 USAGE_SINK_ACCESS_KEY_ID and USAGE_SINK_SECRET_ACCESS_KEY
#                 (see S3 SINK below; no GitHub call at all);
#   the git route otherwise, as follows.
# The git route appends it to events/<YYYY-MM>/cloud-guidance.jsonl on
# branch persistent/usage-events of Adam-S-Daniel/adam-agentskills-private,
# by git push, using the session's own credential, as follows. A hosted
# session's cloud environment variables are readable by every session in that
# environment, so no write credential may live there that the proxy could hold
# instead.
#
# The session's own credential. A hosted session's agent proxy REPLACES any
#    Authorization header sent to api.github.com with the session's GitHub
#    credential, which reaches only the repos attached to the session, and it
#    refuses /app/* paths outright (measured 2026-10-31: "Bearer garbage" got
#    200 on the private repo; an App JWT got 401 "could not be decoded"). It
#    also refuses writes through the contents API (403 "Write access to this
#    GitHub API path is not permitted through this proxy") while allowing a
#    git push. So the hook first asks GET /repos/<repo> with no Authorization
#    header, and when the answer is 200 with permissions.push true (the
#    private repo is attached) it appends with git instead, by plumbing only:
#    a depth-1 `--no-checkout` clone of the branch into a private temp dir,
#    the tip's tree read into a private index (`read-tree`, so the commit keeps
#    every other file on the branch), `hash-object` and `update-index` for each
#    changed file, `write-tree`, `commit-tree`, one push. A file that exists
#    (`ls-tree`) and cannot be read (`cat-file`) aborts the upload rather than
#    being overwritten. A rejected push fetches the new tip, rebuilds on it and
#    pushes again until the deadline. When phase 2 has lines to send in the same
#    Stop, both files go in that one commit; if that commit does not land and
#    time remains, phase 1's file is tried again alone, so a phase-2 problem
#    never costs phase 1's once-per-session record.
# If the session's credential cannot push, the upload is recorded as not
# uploaded (False). There is no GitHub App fallback: the hosted agent proxy
# rewrites any Authorization header to api.github.com and refuses /app/*, so an
# App key never worked in a cloud session (measured 2026-10-31), the upload
# only runs in remote sessions, and keeping the code invited a GitHub App
# private key into a cloud environment variable. USAGE_WRITER_APP_* variables
# an old environment still holds are never read, and are removed from every
# subprocess's environment.
# No token or response
# body is ever printed. Every call has a 10-second cap, inside a 15-second
# overall budget, under the 20-second hook timeout. Every subprocess gets
# /dev/null for stdin and its own process group, which a timeout kills whole;
# git runs with credential.interactive=never and core.hooksPath=/dev/null, and
# keeps the machine's system and global config (the hosted proxy may rely on
# them; the integrator's cloud probe ran with them). The temp root is resolved
# once (a symlinked /tmp is fine) and the temp dir must resolve to a direct
# child of it, or the upload is refused; this user's guidance-record.* dirs
# left over 10 minutes ago are swept first.
#
# S3 SINK (ADR 0037)
# ------------------
# For sessions that do not have the private repo attached. Each upload is one
# HTTPS PUT per object to https://<bucket>.s3.<region>.amazonaws.com/<key>
# by the standard library alone (urllib; it honors HTTPS_PROXY and the system
# CA store), with headers If-None-Match: *, Content-Type: application/json and
# x-amz-content-sha256 (hex sha256 of the body). Two modes:
#   proxy   USAGE_SINK_BUCKET, USAGE_SINK_REGION and USAGE_SINK_SIGNING=proxy
#           (exactly that value; it wins when keys are also set). The agent
#           proxy holds the AWS key as a network secret (type AWS SigV4) and
#           signs the request for the virtual-hosted S3 host itself, so the
#           key never enters the session. The hook sends no Authorization and
#           no x-amz-date header; the proxy adds both.
#   static  all four of USAGE_SINK_BUCKET, _REGION, _ACCESS_KEY_ID and
#           _SECRET_ACCESS_KEY: the hook signs with AWS Signature Version 4
#           (hmac, hashlib), adding x-amz-date; every header is signed. A
#           fallback for a host without that proxy; never set it in a cloud
#           environment, whose variables every session there can read.
#   key   drop/<YYYY-MM-DD UTC of the send>/<32 lowercase hex of os.urandom>.json
#   body  {"v":1,"kind":"usage-drop","sent":"<YYYY-MM-DDTHH:MM:SSZ>",
#          "guidance":[<phase 1's line, if due>],"skills":[<phase 2's lines>]}
# exactly those keys. A `guidance` item is byte for byte the line the git route
# appends to cloud-guidance.jsonl (the record without `uploaded`); a `skills`
# item is byte for byte a phase-2 shard line. When phase 1 and phase 2 are both
# due they share an object; a body over 262144 bytes is split into several
# objects, phase 1's line in the first. Per object: 200 is sent (those lines
# leave the pending file; phase 1's `uploaded` is true); 412 (the key exists)
# retries once under a new random key; a 403 carrying S3's x-amz-request-id
# header is a definite no for the session, like the git route's (lines stay
# pending, no more tries this session), while a 403 without it (a proxy's
# refusal) is an ordinary failure; any other status, a redirect or no answer
# is a failure for the backoff. Running out of time after some objects landed
# retries next Stop without backoff. A malformed bucket name (dots included),
# region or key id counts as a definite no and sends nothing. The key's date
# and `sent` are checked to be ASCII digits before anything is sent. In a
# CLAUDE_CODE_REMOTE=true session a phase-1 line that did not land is held in
# <state dir>/cloud-skills/<sha256>.guidance.pending and sent again with phase
# 2's lines, under the same backoff, until it lands (the reader dedupes by
# session); `uploaded` in sessions.jsonl still tells only the first try. The
# writer key (either mode) can only add objects under drop/ and never overwrite one. The
# secret is read from the environment into memory only: never written to a
# file or printed, and every USAGE_SINK_* variable is removed from the
# environment of every subprocess (git, curl), whichever route
# runs. Each PUT
# has the same 10-second cap inside the same budgets as the git route (6 s when
# phase 2 uploads alone), enforced on the whole call, not only per read.
#
# CLOUD SKILL RECORDS (phase 2, ADR 0036)
# ---------------------------------------
# Only when CLAUDE_CODE_REMOTE=true (CLAUDE_CODE_REMOTE_SESSION_ID alone is not
# enough). Anywhere else nothing past that test runs: no file, no subprocess.
# On EVERY Stop, before phase 1's once-per-session return, it reads the
# transcript and this session's subagent transcripts
# (<transcript dir>/<session id>/subagents/*.jsonl) from a per-file watermark:
# complete lines only, entries whose sessionId is this session's, at most
# 32 MiB per file (a 32 MiB stretch with no newline is skipped), reset to 0
# when the file shrinks or is replaced. A use is a Skill tool_use (keyed on its
# id) or a typed slash command (keyed on the entry's uuid). Its loaded copy is
# the `Base directory for this skill: <path>` meta entry that links to it
# (sourceToolUseID, or parentUuid for a typed command). The watermark never
# passes a use that is not settled (no base directory, no tool result, no later
# assistant turn yet). Each copy is resolved as skills-evals' LoadedCopies
# does: where it lives, a 64-hex lock-kind digest (the #536 function, bound by
# a shared test vector) or one of eight null reasons, the registry and commit
# where known. A use whose timestamp does not parse is skipped, as the local
# census skips it. A typed command with no base directory is kept only for a
# built-in skill or a name skills-bootstrap.sh installed. Bounds per Stop: 50
# uses, 1.5 s parsing, 3 s hashing, 4 s in all; a use the hash budget did not
# reach holds the watermark. At most 2000 lines per session.
#
# Each use becomes one line in a local pending file, then, after phase 1, in
#   events/<YYYY-MM of the use>/cloud-skills/<session>.jsonl
# on the same private branch (no other destination; nothing reaches
# sessions.jsonl), with exactly these keys:
#   {"v":1,"id":"<tool_use id | entry uuid>","ts":"<use time, Z>","kind":"skill",
#    "surface":"cloud","session":"<16 hex, as phase 1>","cli":"<version>"|null,
#    "name":"<skill name>"|"invalid","base_kind":"<where the copy lives>",
#    "registry":"<owner>/<repo>"|null,"ref":"<40 hex>"|null,
#    "digest":"<64 hex>"|null,"digest_null_reason":"<reason>"|null}
# No path (the base directory is resolved and dropped), title, prompt,
# transcript text, cwd, machine name, raw session id, remote URL or credential
# is ever written. The upload uses the session's route: the S3 sink above, or
# the git path above with the session's own credential, and no App. On the git
# path a rejected push that runs out of time retries next Stop; on either, a
# network error, 5xx or timeout backs off 2 min, doubling to 64 min, and a
# definite no (git: 403, 404, or push false; S3: 403) stops uploads for the
# session.
# State lives in <state dir>/cloud-skills/ (0700, files 0600, opened with
# O_NOFOLLOW): the watermarks, the pending lines and a lock taken without
# waiting, never held across the network. A busy lock skips that Stop.
#
# ONCE PER SESSION, AND NEVER IN THE WAY
# --------------------------------------
# The hook runs on every Stop, so the common case is a fast exit: a done flag
# per session (named by the sha256 of the session id) under the state dir.
# The flag is claimed only once there is something to record: a transcript
# with no instructions entry yet exits and tries again next turn. It never
# blocks the session: it prints nothing to stdout, sends its errors nowhere
# and always exits 0. No python3 means no record.
#
# Test seams, each read only when GUIDANCE_RECORD_TEST=1 (a leaked value is
# ignored): GUIDANCE_RECORD_NOW (an ISO 8601 UTC time, e.g.
# 2026-10-31T12:00:00Z) replaces the clock, phase 2's backoff and the S3
# sink's x-amz-date included; GUIDANCE_RECORD_API (default https://api.github.com) replaces the API base
# URL; GUIDANCE_RECORD_GIT (default
# https://github.com/Adam-S-Daniel/adam-agentskills-private) replaces the git
# remote; USAGE_SINK_ENDPOINT (e.g. http://127.0.0.1:<port>) sends the S3
# sink's PUTs path style to <endpoint>/<bucket>/<key> instead of AWS, a test
# hook only. GUIDANCE_RECORD_TEST_SCALE, read only when GUIDANCE_RECORD_TEST=1,
# shrinks every time budget (the 15 s total, the 10 s call cap, phase 2's
# 4/1.5/3/6 s caps and the backoff) by a factor in (0, 1]; it never grows one.

exec 1>/dev/null 2>/dev/null

command -v python3 >/dev/null 2>&1 || exit 0

GUIDANCE_HOOK_INPUT="$(cat 2>/dev/null)" || GUIDANCE_HOOK_INPUT=""
export GUIDANCE_HOOK_INPUT

python3 -I -S - <<'PY' || true
import datetime
import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

REPO = "Adam-S-Daniel/adam-agentskills-private"
BRANCH = "persistent/usage-events"
FULL = ("guidance-marker: fleet-full", "## Working in these repos")
STUB = ("guidance-marker: fleet-stub", "Fleet guidance is delivered once per session")
CHECK_LINE = re.compile(r"^fleet-guidance check value: ([0-9a-f]{8})$", re.MULTILINE)
REPORT = re.compile(r"fleet-guidance check: ([0-9a-f]{8}|none)\b")
ISO = "%Y-%m-%dT%H:%M:%SZ"
SOURCE_REGISTRY = re.compile(
    r"https://github\.com/([A-Za-z0-9][A-Za-z0-9._-]*)/([A-Za-z0-9][A-Za-z0-9._-]*?)(\.git)?")
SOURCE_REF = re.compile(r"[0-9a-f]{40}")
MAX_SOURCES = 16
MAX_INSTALL_RECORD = 1 << 20
START = time.monotonic()


def seam(name):
    """A test seam's value: read only when GUIDANCE_RECORD_TEST=1 marks a test
    run, so a value leaked into a real session's environment is ignored."""
    return os.environ.get(name) if os.environ.get("GUIDANCE_RECORD_TEST") == "1" else None


def test_scale():
    """A factor in (0, 1] for every time budget below. Tests only: it is read
    only when GUIDANCE_RECORD_TEST=1 marks a test run, and it can only shrink
    the budgets, never grow them."""
    if os.environ.get("GUIDANCE_RECORD_TEST") != "1":
        return 1.0
    try:
        scale = float(os.environ.get("GUIDANCE_RECORD_TEST_SCALE") or "1")
    except ValueError:
        return 1.0
    return scale if 0.01 <= scale <= 1 else 1.0


SCALE = test_scale()
BUDGET = 15.0 * SCALE
CALL_CAP = 10.0 * SCALE         # one subprocess call at most
MIN_CALL = 1.0 * SCALE          # a call with less time left than this is skipped

# Phase 2 (see CLOUD SKILL RECORDS in the header).
CLOUD_DIR = "cloud-skills"
MAX_SCAN = 32 << 20             # bytes read from one transcript per Stop
MAX_SUBAGENT_FILES = 64
USES_PER_STOP = 50
SESSION_CAP = 2000              # events recorded per session; the rest only counted
COLLECT_BUDGET = 4.0 * SCALE    # seconds for all of collection
PARSE_BUDGET = 1.5 * SCALE      # seconds of it for parsing transcripts
HASH_BUDGET = 3.0 * SCALE       # seconds of it for walking and hashing skill copies
NET_BUDGET = 6.0 * SCALE        # seconds of network when phase 2 uploads alone
BACKOFF_BASE = 120 * SCALE
BACKOFF_CAP = 64 * 60 * SCALE
STALE_TEMP = 600                # a leftover guidance-record.* temp dir older than this is swept
MAX_STATE = 1 << 20
MAX_PENDING = 8 << 20
MAX_FILES = 2000                # the lock digest's caps (skills-evals harness/skill_digest.py)
MAX_BYTES = 50 << 20
ID_RE = re.compile(r"[A-Za-z0-9_-]{1,128}")
NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}(:[A-Za-z0-9][A-Za-z0-9._-]{0,127})?")
SKILL_DIR_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
CLI_RE = re.compile(r"[0-9][0-9A-Za-z.+-]{0,31}")
# The transcript's entrypoint, as skills-evals' ingest_usage_sink.py SURFACE_RE
# accepts it; CLI_RE is its census CLOUD_CLI_RE. A value outside either is sent
# as null on both routes, so the reader never rejects an object over it.
SURFACE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SHA_RE = re.compile(r"[0-9a-f]{40}")
DIGEST_RE = re.compile(r"[0-9a-f]{64}")
SUBAGENT_FILE_RE = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,199}\.jsonl")
OWNER_REPO_RE = re.compile(r"([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})")
GITHUB_REMOTE_RE = re.compile(
    r"(?:https://(?:[^@/\s]+@)?github\.com/|ssh://git@github\.com/|git@github\.com:)"
    r"([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?/?")
# The hosted session's local git proxy form, http://<user:token>@127.0.0.1:<port>/git/<owner>/<repo>.
PROXY_REMOTE_RE = re.compile(
    r"https?://(?:[^@/\s]+@)?(?:127\.0\.0\.1|localhost)(?::[0-9]{1,5})?/git/"
    r"([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?/?")
HTTPS_GITHUB_RE = re.compile(
    r"https://github\.com/([A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}?)(?:\.git)?")
COMMAND_NAME_RE = re.compile(r"<command-name>([^<]{0,200})</command-name>")
BASE_DIR_LINE = "Base directory for this skill: "
# Claude Code's built-in prompt skills, which write no base-directory message.
BUILTIN_SKILLS = frozenset({"schedule", "update-config", "loop", "simplify",
                            "artifact-design", "workflow-authoring"})
TS_FORMATS = ("%Y-%m-%dT%H:%M:%S.%fZ", "%Y-%m-%dT%H:%M:%SZ")
# The S3 sink (see S3 SINK in the header): all four set and non-empty choose it.
SINK_VARS = ("USAGE_SINK_BUCKET", "USAGE_SINK_REGION", "USAGE_SINK_ACCESS_KEY_ID",
             "USAGE_SINK_SECRET_ACCESS_KEY")
SINK_SIGNING_VAR = "USAGE_SINK_SIGNING"   # "proxy": the agent proxy signs, no key here
# Variable-name prefixes no subprocess may inherit (USAGE_WRITER_APP_ is retired).
SECRET_PREFIXES = ("USAGE_SINK_", "USAGE_WRITER_APP_")
SINK_MAX_OBJECT = 262144        # bytes in one object's body; more lines split into more objects
# ASCII digits only ([0-9], never \d, which also matches other scripts' digits).
SINK_KEY_RE = re.compile(r"drop/[0-9]{4}-[0-9]{2}-[0-9]{2}/[0-9a-f]{32}\.json")
SINK_SENT_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
# No dots: a dotted bucket name breaks the *.s3.<region>.amazonaws.com certificate.
SINK_BUCKET_RE = re.compile(r"[a-z0-9][a-z0-9-]{1,61}[a-z0-9]")
SINK_REGION_RE = re.compile(r"[a-z]{2}(?:-[a-z0-9]+){1,4}")
SINK_KEY_ID_RE = re.compile(r"[A-Z0-9]{16,128}")
# Inherited variables that would point git at some other repository or index.
GIT_LOCATION_VARS = frozenset({"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                               "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE"})


def now():
    raw = seam("GUIDANCE_RECORD_NOW") or ""
    if raw:
        try:
            return datetime.datetime.strptime(raw, ISO).replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            pass
    return datetime.datetime.now(datetime.timezone.utc)


def state_dir():
    base = os.environ.get("XDG_STATE_HOME") or ""
    if not base:
        home = os.environ.get("HOME") or ""
        if not home:
            return None
        base = os.path.join(home, ".local", "state")
    return os.path.join(base, "fleet-guidance")


def first_report(message):
    """The first check report in one assistant message's text blocks, or None."""
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return None
    for text in texts:
        found = REPORT.search(text) if isinstance(text, str) else None
        if found:
            return found.group(1)
    return None


_LISTED = re.compile(r"^- (?P<name>[^\s:]+(?::[^\s:]+)?)(?P<rest>.*)$")


def listing_state(entry):
    """"full" or "truncated" for the entry holding the session's first
    (isInitial) skill listing; None for any other entry. Claude Code cuts the
    listing to a character budget and lists the last skills by name alone; a
    plugin skill always has a description, so a namespaced name with none is
    that cut. Stricter than skills-evals' model_usage_census.listing_state: a
    BARE name with none counts as a cut too, because the registry bundles the
    skills-bootstrap hook installs in cloud sessions are listed by bare name,
    and a false "full" could let a used skill be removed."""
    att = entry.get("attachment")
    if not isinstance(att, dict) or att.get("type") != "skill_listing" \
            or att.get("isInitial") is not True:
        return None
    content = att.get("content")
    if not isinstance(content, str):
        return None
    for line in content.split("\n"):
        found = _LISTED.match(line)
        if found and not found.group("rest").lstrip(":").strip():
            return "truncated"
    return "full"


def read_transcript(path):
    """(instruction files, entrypoint, cli version, assistant responses, first
    check report: 8 hex, "none" or None, listing: "full", "truncated" or None
    when no initial skill listing is in the transcript)."""
    files, surface, cli, assistant, report, listing = None, None, None, set(), None, None
    with open(path, encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            try:
                entry = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(entry, dict):
                continue
            if surface is None and isinstance(entry.get("entrypoint"), str):
                surface = entry["entrypoint"]
            if cli is None and isinstance(entry.get("version"), str):
                cli = entry["version"]
            kind = entry.get("type")
            if kind == "assistant":
                message = entry.get("message")
                mid = message.get("id") if isinstance(message, dict) else None
                assistant.add(mid if isinstance(mid, str) else ("line", len(assistant)))
                if report is None:
                    report = first_report(message)
            elif kind == "attachment":
                att = entry.get("attachment")
                if listing is None:
                    listing = listing_state(entry)
                if isinstance(att, dict) and att.get("type") == "instructions":
                    listed = att.get("files")
                    files = files or []
                    if isinstance(listed, list):
                        files += [f for f in listed if isinstance(f, dict)]
    return files, surface, cli, len(assistant), report, listing


def classify(files):
    texts = [f.get("content") for f in files if isinstance(f.get("content"), str)]
    if any(sig in t for t in texts for sig in FULL):
        return "full"
    if any(sig in t for t in texts for sig in STUB):
        return "stub-only"
    return "neither"


def expected_check(files):
    """The check value in the first User-type instruction file that has one."""
    for f in files:
        content = f.get("content")
        if f.get("type") == "User" and isinstance(content, str):
            found = CHECK_LINE.search(content)
            if found:
                return found.group(1)
    return None


def check_outcome(expected, report):
    """The check_reported enum. Neither argument is ever recorded itself."""
    if report is None:
        return "absent"
    if report == "none":
        return "none"
    return "match" if expected is not None and report == expected else "mismatch"


def repo_count(files):
    dirs = set()
    for f in files:
        path = f.get("path")
        if f.get("type") != "Project" or not isinstance(path, str):
            continue
        if os.path.basename(path) not in ("AGENTS.md", "CLAUDE.md"):
            continue
        parent = os.path.dirname(path)
        if os.path.basename(parent) == ".claude":
            parent = os.path.dirname(parent)
        dirs.add(parent)
    return len(dirs)


def guidance_version():
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.environ.get("HOME") or "", ".claude")
    try:
        with open(os.path.join(config, "CLAUDE.md"), encoding="utf-8", errors="replace") as handle:
            for line in handle:
                m = re.fullmatch(r"<!-- fleet-guidance-version: ([0-9a-f]{8}) -->", line.rstrip("\r\n"))
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def registry_sources():
    """(sources, dropped) from skills-bootstrap.sh's install record, or
    (None, None) when it has no usable `sources` list. Never raises."""
    try:
        home = os.environ.get("HOME") or os.path.expanduser("~")
        path = os.path.join(home, ".claude", "skills", ".skills-bootstrap-installed.json")
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_INSTALL_RECORD:
            return None, None
        # O_NOFOLLOW and O_NONBLOCK: the path may have been swapped for a link
        # or a FIFO since the lstat; fstat confirms what was opened.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                return None, None
            raw = handle.read(MAX_INSTALL_RECORD + 1)
        if len(raw) > MAX_INSTALL_RECORD:
            return None, None
        doc = json.loads(raw.decode("utf-8"))
        listed = doc.get("sources") if isinstance(doc, dict) else None
        if not isinstance(listed, list):
            return None, None
        valid = set()
        rejected = 0
        for item in listed:
            registry = item.get("registry") if isinstance(item, dict) else None
            ref = item.get("ref") if isinstance(item, dict) else None
            found = SOURCE_REGISTRY.fullmatch(registry) if isinstance(registry, str) else None
            if found and isinstance(ref, str) and SOURCE_REF.fullmatch(ref):
                valid.add(("%s/%s" % (found.group(1), found.group(2)), ref))
            else:
                rejected += 1
        kept = sorted(valid)
        rejected += max(0, len(kept) - MAX_SOURCES)
        return [{"registry": r, "ref": c} for r, c in kept[:MAX_SOURCES]], rejected
    except Exception:
        return None, None


# ── subprocesses ────────────────────────────────────────────────────────────

def remaining():
    return BUDGET - (time.monotonic() - START)


def cap_for(deadline):
    """Seconds one call may take: at most 10, inside the overall budget and
    `deadline` (a time.monotonic() value, or None)."""
    cap = min(CALL_CAP, remaining())
    if deadline is not None:
        cap = min(cap, deadline - time.monotonic())
    return cap


def kill_group(pid):
    # Only a real child's own group: killpg(0) is this process's group, and a
    # pid of 1 or less was never a child.
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return
    try:
        os.killpg(pid, signal.SIGKILL)
    except OSError:
        pass


def run(args, cwd=None, env=None, data=None, cap=CALL_CAP):
    """(returncode, stdout bytes), or (None, b"") when it could not start or
    ran past `cap`. stdin is `data` or /dev/null, stderr is discarded. The
    child leads its own process group, so a timeout also kills what it
    spawned (git's remote helper), which would otherwise hold the pipe open."""
    # No subprocess ever sees the sink's variables, the secret among them,
    # nor a retired App credential an old environment may still hold.
    env = {k: v for k, v in (os.environ if env is None else env).items()
           if not k.startswith(SECRET_PREFIXES)}
    try:
        proc = subprocess.Popen(args, cwd=cwd, env=env,
                                stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                start_new_session=True)
    except (OSError, ValueError):
        return None, b""
    try:
        out, _err = proc.communicate(data, timeout=cap)
        return proc.returncode, out
    except subprocess.TimeoutExpired:
        kill_group(proc.pid)
        try:
            proc.communicate(timeout=MIN_CALL)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
        return None, b""
    except (OSError, ValueError):
        kill_group(proc.pid)
        return None, b""


def git_env(extra=None):
    env = {k: v for k, v in os.environ.items()
           if k not in GIT_LOCATION_VARS and not k.startswith(SECRET_PREFIXES)}
    env["GIT_TERMINAL_PROMPT"] = "0"
    if extra:
        env.update(extra)
    return env


def git_out(args, cwd=None, env=None, data=None, deadline=None):
    """(returncode, stdout bytes) of one hardened git call; returncode -1 when
    the budget left no time to run it, None when it failed to start or timed
    out. `env` adds variables (GIT_INDEX_FILE) to this call only."""
    cap = cap_for(deadline)
    if cap < MIN_CALL:
        return -1, b""
    return run(["git", "-c", "credential.interactive=never", "-c", "core.hooksPath=/dev/null",
                "-c", "core.fsmonitor=false"] + args,
               cwd=cwd, env=git_env(env), data=data, cap=cap)


def git(args, cwd=None, env=None, deadline=None):
    return git_out(args, cwd=cwd, env=env, deadline=deadline)[0] == 0


# ── upload ──────────────────────────────────────────────────────────────────

def api(work, method, url, bearer, body=None, deadline=None):
    """(status, parsed JSON or None). The bearer, if any, reaches curl on stdin
    only; None sends no Authorization header."""
    cap = cap_for(deadline)
    if cap < MIN_CALL:
        return 0, None
    out = os.path.join(work, "response")
    args = ["curl", "-sS", "--max-time", str(int(cap)) if SCALE == 1 else "%.2f" % cap, "-X", method,
            "-o", out, "-w", "%{http_code}", "--config", "-"]
    if body is not None:
        data = os.path.join(work, "request")
        with open(data, "w", encoding="utf-8") as handle:
            json.dump(body, handle)
        args += ["--data-binary", "@" + data]
    args.append(url)
    config = (
        ('header = "Authorization: Bearer %s"\n' % bearer if bearer else "") +
        'header = "Accept: application/vnd.github+json"\n'
        'header = "X-GitHub-Api-Version: 2022-11-28"\n'
        'header = "User-Agent: guidance-load-record"\n' +
        # The hosted proxy refuses a body without this (415, measured
        # 2026-10-31); GitHub itself does not need it.
        ('header = "Content-Type: application/json"\n' if body is not None else ""))
    code, stdout = run(args, data=config.encode("utf-8"), cap=cap + MIN_CALL)
    try:
        status = int(stdout.decode("ascii").strip() or 0) if code is not None else 0
    except (UnicodeError, ValueError):
        status = 0
    try:
        with open(out, encoding="utf-8") as handle:
            parsed = json.load(handle)
    except (OSError, ValueError):
        parsed = None
    try:
        os.unlink(out)
    except OSError:
        pass
    return status, parsed


def guidance_edit(line, when):
    """Phase 1's file and how to extend it."""
    def build(old):
        if old and not old.endswith(b"\n"):
            old += b"\n"
        return old + line.encode("utf-8") + b"\n"
    return "events/%s/cloud-guidance.jsonl" % when.strftime("%Y-%m"), build


def shard_edits(sid, lines):
    """Phase 2's shards, one per month of the events' own timestamps, and how
    to extend each with the lines whose id it does not hold yet."""
    by_month = {}
    for ident, month, text in lines:
        by_month.setdefault(month, []).append((ident, text))
    edits = []
    for month in sorted(by_month):
        def build(old, items=by_month[month]):
            have = set()
            for raw in old.split(b"\n"):
                try:
                    doc = json.loads(raw)
                except ValueError:
                    continue
                if isinstance(doc, dict) and isinstance(doc.get("id"), str):
                    have.add(doc["id"])
            add = []
            for ident, text in items:
                if ident not in have:
                    have.add(ident)
                    add.append(text)
            if not add:
                return None
            if old and not old.endswith(b"\n"):
                old += b"\n"
            return old + "".join(t + "\n" for t in add).encode("utf-8")
        edits.append(("events/%s/%s/%s.jsonl" % (month, CLOUD_DIR, sid), build))
    return edits


def git_identity(clone, deadline):
    code, out = git_out(["config", "user.email"], cwd=clone, deadline=deadline)
    if code == 0 and out.strip():
        return []
    return ["-c", "user.name=guidance-load-record",
            "-c", "user.email=guidance-load-record@users.noreply.github.com"]


def git_commit(work, edits, deadline, message, name="c"):
    """One commit carrying every edit, pushed to BRANCH: "ok", "race" (every
    push lost to another writer until the deadline), or "fail". Plumbing only:
    a depth-1 clone with no checkout, the tip's whole tree read into a private
    index, each file's new blob added to it, then write-tree and commit-tree."""
    remote = seam("GUIDANCE_RECORD_GIT") or "https://github.com/%s" % REPO
    clone = os.path.join(work, name)
    if not git(["clone", "-q", "--depth", "1", "--no-checkout", "--single-branch",
                "--branch", BRANCH, remote, clone], deadline=deadline):
        return "fail"
    index_path = os.path.join(work, name + ".index")
    index = {"GIT_INDEX_FILE": index_path}
    who = git_identity(clone, deadline)
    tip_ref, rejected = "HEAD", False

    def failed():
        # Out of time after losing a push is a lost race, not a failure.
        return "race" if rejected and cap_for(deadline) < MIN_CALL else "fail"

    while True:
        if cap_for(deadline) < MIN_CALL:
            return "race" if rejected else "fail"
        code, out = git_out(["rev-parse", "--verify", "-q", tip_ref + "^{commit}"], cwd=clone,
                            deadline=deadline)
        tip = out.decode("ascii", "replace").strip()
        if code != 0 or not SHA_RE.fullmatch(tip):
            return failed()
        try:
            os.unlink(index_path)
        except FileNotFoundError:
            pass
        # The tip's whole tree first: without it the commit would hold only
        # the files written below and delete every other file on the branch.
        if not git(["read-tree", tip], cwd=clone, env=index, deadline=deadline):
            return failed()
        changed = False
        for path, build in edits:
            code, listed = git_out(["ls-tree", "-z", tip, "--", path], cwd=clone, deadline=deadline)
            if code != 0:
                return failed()
            old = b""
            if listed:
                # The file exists: a read that fails must never be taken for
                # an empty file and overwritten.
                code, old = git_out(["cat-file", "blob", "%s:%s" % (tip, path)], cwd=clone,
                                    deadline=deadline)
                if code != 0:
                    return failed()
            new = build(old)
            if new is None or new == old:
                continue
            code, blob = git_out(["hash-object", "-w", "--stdin"], cwd=clone, data=new,
                                 deadline=deadline)
            blob = blob.decode("ascii", "replace").strip()
            if code != 0 or not SHA_RE.fullmatch(blob):
                return failed()
            if not git(["update-index", "--add", "--cacheinfo", "100644,%s,%s" % (blob, path)],
                       cwd=clone, env=index, deadline=deadline):
                return failed()
            changed = True
        if not changed:
            return "ok"
        code, tree = git_out(["write-tree"], cwd=clone, env=index, deadline=deadline)
        tree = tree.decode("ascii", "replace").strip()
        if code != 0 or not SHA_RE.fullmatch(tree):
            return failed()
        code, commit = git_out(who + ["commit-tree", tree, "-p", tip, "-m", message], cwd=clone,
                               deadline=deadline)
        commit = commit.decode("ascii", "replace").strip()
        if code != 0 or not SHA_RE.fullmatch(commit):
            return failed()
        code, out = git_out(["push", "--porcelain", "origin", "%s:refs/heads/%s" % (commit, BRANCH)],
                            cwd=clone, deadline=deadline)
        if code == 0:
            return "ok"
        # --porcelain marks a refused ref with "!"; a network error, a 5xx or a
        # timeout prints no ref line at all.
        if code is None or code < 0 or not any(l.startswith(b"!") for l in out.splitlines()):
            return failed()
        rejected = True
        if not git(["fetch", "-q", "--depth", "1", "origin", "refs/heads/" + BRANCH], cwd=clone,
                   deadline=deadline):
            return failed()
        tip_ref = "FETCH_HEAD"


def work_dir():
    """A private temp dir for one upload, or None. The temp root is resolved
    once (a symlinked /tmp, as on macOS, is fine), and the new dir must
    resolve to a direct child of it, or it is refused. First sweeps this
    user's own guidance-record.* dirs left over 10 minutes ago."""
    root = os.path.realpath(tempfile.gettempdir())
    try:
        uid, cutoff = os.getuid(), time.time() - STALE_TEMP
        with os.scandir(root) as entries:
            for entry in entries:
                if not entry.name.startswith("guidance-record."):
                    continue
                info = os.lstat(entry.path)
                if stat.S_ISDIR(info.st_mode) and info.st_uid == uid and info.st_mtime < cutoff:
                    shutil.rmtree(entry.path, ignore_errors=True)
    except OSError:
        pass
    work = tempfile.mkdtemp(prefix="guidance-record.", dir=root)
    if os.path.realpath(work) != os.path.join(root, os.path.basename(work)) or os.path.islink(work):
        try:
            os.rmdir(work)
        except OSError:
            pass
        return None
    return work


# ── S3 sink ─────────────────────────────────────────────────────────────────

def sink_config():
    """The S3 sink's configuration, or None (the git route). Mode "proxy":
    bucket and region set and USAGE_SINK_SIGNING exactly "proxy" (the agent
    proxy signs; no key is here); it wins over keys. Mode "static": all four
    of the other USAGE_SINK_* values set and non-empty. Read from the
    environment only, never stored."""
    values = [os.environ.get(name) or "" for name in SINK_VARS]
    if values[0] and values[1] and os.environ.get(SINK_SIGNING_VAR) == "proxy":
        return {"mode": "proxy", "bucket": values[0], "region": values[1]}
    if not all(values):
        return None
    cfg = dict(zip(("bucket", "region", "key_id", "secret"), values))
    cfg["mode"] = "static"
    return cfg


def sink_usable(cfg):
    if cfg["mode"] == "proxy":
        return bool(SINK_BUCKET_RE.fullmatch(cfg["bucket"]) and SINK_REGION_RE.fullmatch(cfg["region"]))
    return bool(SINK_BUCKET_RE.fullmatch(cfg["bucket"]) and SINK_REGION_RE.fullmatch(cfg["region"])
                and SINK_KEY_ID_RE.fullmatch(cfg["key_id"]))


def sigv4_authorization(method, path, query, headers, payload_hash, region, service, key_id, secret):
    """The AWS Signature Version 4 Authorization value. `headers` are the
    signed headers (host and x-amz-date among them), `path` the canonical,
    already URI-encoded path, `query` the canonical query string."""
    lower = {name.lower(): value for name, value in headers.items()}
    names = sorted(lower)
    canonical_headers = "".join("%s:%s\n" % (n, " ".join(str(lower[n]).split())) for n in names)
    signed = ";".join(names)
    canonical = "\n".join((method, path, query, canonical_headers, signed, payload_hash))
    stamp = lower["x-amz-date"]
    scope = "%s/%s/%s/aws4_request" % (stamp[:8], region, service)
    to_sign = "\n".join(("AWS4-HMAC-SHA256", stamp, scope,
                         hashlib.sha256(canonical.encode("utf-8")).hexdigest()))
    key = ("AWS4" + secret).encode("utf-8")
    for part in (stamp[:8], region, service, "aws4_request"):
        key = hmac.new(key, part.encode("utf-8"), hashlib.sha256).digest()
    signature = hmac.new(key, to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
    return "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
        key_id, scope, signed, signature)


def sink_body(sent, guidance, skills):
    """One object's body, built from the exact lines: `guidance` is phase 1's
    line as the git route appends it (or None), `skills` phase 2's lines."""
    return ('{"v":1,"kind":"usage-drop","sent":"%s","guidance":[%s],"skills":[%s]}'
            % (sent, guidance or "", ",".join(skills))).encode("utf-8")


def sink_batches(line, items):
    """[(guidance line or None, [(id, text)])], phase 1's line in the first,
    each body at most SINK_MAX_OBJECT bytes. A line too large for any object
    (none can be: every field is bounded) is left out and stays pending."""
    overhead = len(sink_body("2000-01-01T00:00:00Z", None, []))
    batches, head, current = [], line, []
    size = overhead + (len(line.encode("utf-8")) if line is not None else 0)
    for ident, _month, text in items:
        need = len(text.encode("utf-8")) + 1
        if overhead + need > SINK_MAX_OBJECT:
            continue
        if size + need > SINK_MAX_OBJECT and (current or head is not None):
            batches.append((head, current))
            head, current, size = None, [], overhead
        current.append((ident, text))
        size += need
    if current or head is not None:
        batches.append((head, current))
    return batches


def http_put(url, headers, body, cap):
    """The HTTP status of one PUT, or 0 for no answer (a network error, a
    timeout). A redirect is not followed. A 403 without S3's x-amz-request-id
    header (a proxy's refusal, say) is returned as 0, an ordinary failure, so
    only S3's own 403 stops the session's tries. The thread bounds the whole
    call, not only each socket read."""
    result = [0]

    def go():
        try:
            request = urllib.request.Request(url, data=body, method="PUT", headers=headers)
            with urllib.request.urlopen(request, timeout=cap) as response:
                result[0] = response.status
        except urllib.error.HTTPError as error:
            result[0] = error.code
            if error.code == 403 and not (error.headers and error.headers.get("x-amz-request-id")):
                result[0] = 0
            error.close()
        except Exception:
            result[0] = 0
    worker = threading.Thread(target=go, daemon=True)
    worker.start()
    worker.join(cap)
    return 0 if worker.is_alive() else result[0]


def sink_put(cfg, guidance, skills, deadline):
    """Send one object: 200, 403, 412 (twice), another status, 0 for no
    answer, or -1 when the budget left no time. A 412 (the key exists)
    gets one more try under a new random key."""
    status = -1
    for _attempt in range(2):
        cap = cap_for(deadline)
        if cap < MIN_CALL:
            return -1
        when = now()
        sent = when.strftime(ISO)
        key = "drop/%s/%s.json" % (when.strftime("%Y-%m-%d"), os.urandom(16).hex())
        if not (SINK_SENT_RE.fullmatch(sent) and SINK_KEY_RE.fullmatch(key)):
            return 0                 # a key or time the reader would refuse is never sent
        body = sink_body(sent, guidance, skills)
        endpoint = seam("USAGE_SINK_ENDPOINT")
        if endpoint:
            # Test hook only (path style against a local server).
            parts = urllib.parse.urlsplit(endpoint)
            if parts.scheme not in ("http", "https") or not parts.netloc:
                return 0
            host, path = parts.netloc, "%s/%s/%s" % (parts.path.rstrip("/"), cfg["bucket"], key)
            url = "%s://%s%s" % (parts.scheme, host, path)
        else:
            host, path = "%s.s3.%s.amazonaws.com" % (cfg["bucket"], cfg["region"]), "/" + key
            url = "https://" + host + path
        payload = hashlib.sha256(body).hexdigest()
        signed = {"content-type": "application/json", "host": host, "if-none-match": "*",
                  "x-amz-content-sha256": payload}
        if cfg["mode"] == "proxy":
            # The agent proxy signs and dates the request itself.
            headers = {k: v for k, v in signed.items() if k != "host"}
        else:
            signed["x-amz-date"] = when.strftime("%Y%m%dT%H%M%SZ")
            headers = {k: v for k, v in signed.items() if k != "host"}
            headers["authorization"] = sigv4_authorization(
                "PUT", path, "", signed, payload, cfg["region"], "s3", cfg["key_id"], cfg["secret"])
        status = http_put(url, headers, body, cap)
        if status != 412:
            return status
    return status


def sink_upload(cfg, line, cloud, snap, held=None):
    """The S3 route of upload(): phase 1's line (or, at a later Stop, the
    held copy of one that did not land) and phase 2's pending lines in as few
    objects as fit, phase 1's in the first. Same return value and pending,
    backoff and budget rules as the git route; in a CLAUDE_CODE_REMOTE=true
    session a phase-1 line that did not land is held and retried with them."""
    guidance = line if line is not None else held
    outcome, sent, uploaded = "fail", set(), False
    try:
        if line is None:
            deadline = time.monotonic() + min(NET_BUDGET, remaining() - MIN_CALL / 2)
        else:
            deadline = None
        if not sink_usable(cfg):
            outcome = "nocred"   # a malformed bucket, region or key id can never work
            return False if line is not None else None
        for head, items in sink_batches(guidance, snap or []):
            status = sink_put(cfg, head, [t for _i, t in items], deadline)
            if status == 200:
                sent.update(i for i, _t in items)
                uploaded = uploaded or head is not None
                continue
            if status == 403:
                outcome = "nocred"   # a definite no: stop S3 tries for the session
            elif status == -1 and sent:
                outcome = "race"     # out of time after progress: next Stop, no backoff
            else:
                outcome = "fail"
            break
        else:
            outcome = "ok"
        return uploaded if line is not None else None
    except Exception:
        return False if line is not None else None
    finally:
        if cloud is not None and (snap or guidance is not None):
            try:
                cloud.finish(outcome, snap or [], sent,
                             guidance=(guidance, uploaded) if guidance is not None else None)
            except Exception:
                pass


def upload(line, when, cloud=None):
    """Phase 1's `uploaded` for `line` (None when `line` is None). With
    `cloud` due, its pending lines go in the same commit as `line`, or alone.
    With the S3 sink configured, they go to it instead, and nothing to GitHub."""
    snap, held = None, None
    sink = sink_config()
    if cloud is not None:
        cloud.attempted = True
        snap = cloud.snapshot()
        if sink is not None and line is None:
            held = cloud.held_guidance()
    if line is None and not snap and held is None:
        return None
    if sink is not None:
        return sink_upload(sink, line, cloud, snap, held)
    outcome = "fail"
    work = None
    try:
        base = (seam("GUIDANCE_RECORD_API") or "https://api.github.com").rstrip("/")
        if line is None:
            deadline = time.monotonic() + min(NET_BUDGET, remaining() - MIN_CALL / 2)
        else:
            deadline = None
        if shutil.which("curl") is None:
            return False if line is not None else None
        work = work_dir()
        if work is None:
            return False if line is not None else None
        status, doc = api(work, "GET", "%s/repos/%s" % (base, REPO), None, deadline=deadline)
        perms = doc.get("permissions") if status == 200 and isinstance(doc, dict) else None
        if isinstance(perms, dict) and perms.get("push") is True:
            if shutil.which("git") is None:
                return False if line is not None else None
            edits = [guidance_edit(line, when)] if line is not None else []
            if snap:
                edits += shard_edits(cloud.sid, snap)
            message = {(True, False): "guidance-load event", (False, True): "cloud skill events",
                       (True, True): "guidance-load and cloud skill events"}[(line is not None, bool(snap))]
            outcome = git_commit(work, edits, deadline, message)
            if line is not None and snap and outcome != "ok" and cap_for(deadline) >= MIN_CALL:
                # A phase-2 problem (an unreadable shard, say) must not cost
                # phase 1's once-per-session record: try it again alone.
                return git_commit(work, [guidance_edit(line, when)], deadline,
                                  "guidance-load event", name="phase1") == "ok"
            return outcome == "ok" if line is not None else None
        if status in (403, 404) or (status == 200 and isinstance(doc, dict)):
            outcome = "nocred"       # a definite answer: this session cannot push there
        return False if line is not None else None
    except Exception:
        return False if line is not None else None
    finally:
        if work is not None:
            shutil.rmtree(work, ignore_errors=True)
        if snap:
            try:
                cloud.finish(outcome, snap)
            except Exception:
                pass


# ── phase 2: which skill copies a cloud session loaded ─────────────────────

class BudgetOut(Exception):
    """The hash budget ran out; the use is left for the next Stop."""


class Refused(Exception):
    """A symbolic link or a non-regular entry in a skill tree."""


class TooLarge(Exception):
    """A skill tree past MAX_FILES files or MAX_BYTES bytes."""


def epoch():
    return now().timestamp()


def parse_ts(raw):
    """An aware UTC datetime for a transcript or record timestamp, year
    2000-2100, else None."""
    if not isinstance(raw, str) or len(raw) > 40:
        return None
    for fmt in TS_FORMATS:
        try:
            when = datetime.datetime.strptime(raw, fmt)
        except ValueError:
            continue
        return when.replace(tzinfo=datetime.timezone.utc) if 2000 <= when.year <= 2100 else None
    return None


def read_small(path, limit):
    """A regular file's bytes, or None: no link, FIFO or device is followed or
    opened blocking, and nothing over `limit` bytes is returned."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    with os.fdopen(fd, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            return None
        data = handle.read(limit + 1)
    return data if len(data) <= limit else None


def load_json(path, limit=MAX_INSTALL_RECORD * 4):
    try:
        data = read_small(path, limit)
        return json.loads(data.decode("utf-8")) if data is not None else None
    except (OSError, ValueError, RecursionError):
        return None


def write_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
    os.replace(tmp, path)


def owner_repo(value):
    found = OWNER_REPO_RE.fullmatch(value) if isinstance(value, str) else None
    return value if found and found.group(2) not in (".", "..") else None


def base_dir_line(message):
    """The path after `Base directory for this skill: ` when that is the
    first line of the entry's text, else None."""
    content = message.get("content")
    if isinstance(content, list):
        first = content[0] if content else None
        content = first.get("text") if isinstance(first, dict) and first.get("type") == "text" else None
    if not isinstance(content, str):
        return None
    line = content.split("\n", 1)[0]
    return line[len(BASE_DIR_LINE):] or None if line.startswith(BASE_DIR_LINE) else None


def typed_command(message):
    """The slash command a user entry's own text typed, or None."""
    content = message.get("content")
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [i["text"] for i in content if isinstance(i, dict) and i.get("type") == "text"
                 and isinstance(i.get("text"), str)]
    else:
        return None
    for text in texts:
        found = COMMAND_NAME_RE.search(text)
        if found:
            return found.group(1)
    return None


def scan(path, mark, session, parse_end):
    """(settled uses, cutoff offset, (dev, ino)) for one transcript from its
    watermark, or None when it cannot be read. Only complete lines whose
    `sessionId` is this session's count; the cutoff never passes a use that
    is not settled yet (no base-directory message, no tool result, no later
    assistant turn)."""
    if time.monotonic() >= parse_end:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return None
        off = mark.get("off")
        off = off if isinstance(off, int) and off >= 0 else 0
        if [info.st_dev, info.st_ino] != [mark.get("dev"), mark.get("ino")] or info.st_size < off:
            off = 0                      # a new or truncated file starts over
        os.lseek(fd, off, os.SEEK_SET)
        chunks, got = [], 0
        while got < MAX_SCAN and time.monotonic() < parse_end:
            chunk = os.read(fd, min(1 << 20, MAX_SCAN - got))
            if not chunk:
                break
            chunks.append(chunk)
            got += len(chunk)
        data = b"".join(chunks)
    except OSError:
        return None
    finally:
        os.close(fd)
    ident = (info.st_dev, info.st_ino)
    end = data.rfind(b"\n")
    if end < 0:
        # A whole read with no newline is skipped, not retried forever.
        return [], off + len(data) if len(data) >= MAX_SCAN else off, ident
    uses, by_call, by_parent, results = [], {}, {}, set()
    last_assistant, pos, idx, limit = -1, 0, 0, end + 1
    while pos <= end:
        if time.monotonic() >= parse_end:
            limit = pos
            break
        nl = data.index(b"\n", pos)
        raw, start = data[pos:nl], off + pos
        pos, idx = nl + 1, idx + 1
        try:
            entry = json.loads(raw)
        except (ValueError, RecursionError):
            continue
        if not isinstance(entry, dict) or entry.get("sessionId") != session:
            continue
        kind, message = entry.get("type"), entry.get("message")
        if not isinstance(message, dict):
            continue
        if kind == "assistant":
            last_assistant = idx
            content = message.get("content")
            for item in content if isinstance(content, list) else ():
                if not (isinstance(item, dict) and item.get("type") == "tool_use"
                        and item.get("name") == "Skill"):
                    continue
                call, given = item.get("id"), item.get("input")
                name = given.get("skill") if isinstance(given, dict) else None
                if isinstance(call, str) and ID_RE.fullmatch(call) and call not in by_call \
                        and isinstance(name, str) and name:
                    use = {"id": call, "name": name, "typed": False, "idx": idx, "start": start,
                           "ts": entry.get("timestamp"), "cli": entry.get("version"), "base": None}
                    uses.append(use)
                    by_call[call] = use
        elif kind == "user":
            if entry.get("isMeta") is True:
                base = base_dir_line(message)
                if base is not None:
                    for table, key in ((by_call, entry.get("sourceToolUseID")),
                                       (by_parent, entry.get("parentUuid"))):
                        use = table.get(key) if isinstance(key, str) else None
                        if use is not None and use["base"] is None:
                            use["base"] = base
                continue
            content = message.get("content")
            for item in content if isinstance(content, list) else ():
                if isinstance(item, dict) and item.get("type") == "tool_result" \
                        and isinstance(item.get("tool_use_id"), str):
                    results.add(item["tool_use_id"])
            command, uuid = typed_command(message), entry.get("uuid")
            if command and isinstance(uuid, str) and ID_RE.fullmatch(uuid) and uuid not in by_parent:
                use = {"id": uuid, "name": command, "typed": True, "idx": idx, "start": start,
                       "ts": entry.get("timestamp"), "cli": entry.get("version"), "base": None}
                uses.append(use)
                by_parent[uuid] = use
    settled = []
    for use in uses:
        if use["base"] is not None or (not use["typed"] and use["id"] in results) \
                or last_assistant > use["idx"]:
            settled.append(use)
            continue
        return settled, use["start"], ident
    return settled, off + limit, ident


def path_shape(real):
    """(kind by path alone, the `.claude` directory, the marketplace)."""
    parts = real.split("/")
    if "local-agent-mode-sessions" in parts:
        return "account-plugin", None, None
    for index, part in enumerate(parts):
        if part != ".claude":
            continue
        claude, rest = "/".join(parts[:index + 1]) or "/", parts[index + 1:]
        if len(rest) == 7 and rest[:2] == ["plugins", "cache"] and rest[5] == "skills":
            return "plugin-cache", claude, rest[2]
        if len(rest) > 2 and rest[:2] == ["skills", "synced"]:
            return "account-sync", claude, None
        if len(rest) == 2 and rest[0] == "skills":
            return "user-skills", claude, None
    return "unknown", None, None


def check_budget(hash_end):
    if time.monotonic() >= hash_end:
        raise BudgetOut()


def latest_change(root, skip, hash_end):
    """The latest max(mtime, ctime) of `root` and everything under it, links
    not followed and `skip` left out."""
    def fail(error):
        raise error
    info = os.lstat(root)
    latest, count = max(info.st_mtime, info.st_ctime), 0
    for directory, subdirs, names in os.walk(root, followlinks=False, onerror=fail):
        check_budget(hash_end)
        for name in subdirs + names:
            path = os.path.join(directory, name)
            if path in skip:
                continue
            count += 1
            if count > 2 * MAX_FILES:
                raise TooLarge()
            info = os.lstat(path)
            latest = max(latest, info.st_mtime, info.st_ctime)
    return latest


def file_sha256(path, budget):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    digest = hashlib.sha256()
    with os.fdopen(fd, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise Refused()
        while True:
            chunk = handle.read(1 << 20)
            if not chunk:
                break
            budget[0] -= len(chunk)
            if budget[0] < 0:
                raise TooLarge()
            digest.update(chunk)
    return digest.hexdigest()


def lock_digest(root, skip, hash_end):
    """The lock-kind digest of the directory `root`, byte for byte skills-evals'
    harness/skill_digest.py `lock_digest` (adam-agentskills'
    generate_skills_lock.py `digest_skill_dir`): sha256 over sorted lines
    `<relpath>\\0<sha256 of the file>\\n`, one per regular file, `skip` left
    out. A link or any other non-regular entry is refused; the budget is
    checked before every file is opened."""
    if os.path.islink(root):
        raise Refused()
    top = os.path.realpath(root)
    if not os.path.isdir(top):
        raise NotADirectoryError(root)
    files = []

    def fail(error):
        raise error
    for directory, subdirs, names in os.walk(top, followlinks=False, onerror=fail):
        check_budget(hash_end)
        for name in subdirs + names:
            path = os.path.join(directory, name)
            mode = os.lstat(path).st_mode
            if stat.S_ISLNK(mode):
                raise Refused()
            if stat.S_ISDIR(mode):
                continue
            if not stat.S_ISREG(mode):
                raise Refused()
            if path in skip:
                continue
            files.append((os.path.relpath(path, top), path))
            if len(files) > MAX_FILES:
                raise TooLarge()
    budget, manifest = [MAX_BYTES], []
    for relpath, path in sorted(files, key=lambda f: f[0]):
        check_budget(hash_end)
        manifest.append("%s\0%s\n" % (relpath, file_sha256(path, budget)))
    return hashlib.sha256("".join(manifest).encode("utf-8")).hexdigest()


class Copies:
    """Resolves which copy each use loaded, a port of skills-evals'
    LoadedCopies (scripts/model_usage_census.py): each base directory is
    walked and hashed at most once per Stop."""

    def __init__(self):
        self.trees, self.toplevels, self.origins, self.json = {}, {}, {}, {}

    def resolve(self, name, base, when, hash_end):
        out = {"base_kind": "unknown", "registry": None, "ref": None, "digest": None,
               "digest_null_reason": None}
        bare = name.split(":", 1)[1] if name and ":" in name else name
        if not bare or not SKILL_DIR_RE.fullmatch(bare):
            return dict(out, digest_null_reason="bad-name")
        if base is None:
            if bare in BUILTIN_SKILLS:
                return dict(out, base_kind="builtin", digest_null_reason="builtin")
            return dict(out, digest_null_reason="no-base-dir")
        if not os.path.isabs(base) or "\0" in base:
            return dict(out, digest_null_reason="outside-known-roots")
        if "bundled-skills" in base.split("/"):
            return dict(out, base_kind="builtin", digest_null_reason="builtin")
        real = os.path.realpath(base)
        if os.path.basename(os.path.normpath(base)) != bare or os.path.basename(real) != bare:
            return dict(out, digest_null_reason="no-base-dir")
        kind, claude, marketplace = path_shape(real)
        if not os.path.isdir(real):
            return dict(out, base_kind=kind, digest_null_reason="gone")
        checkout = None
        if kind in ("user-skills", "unknown"):
            checkout = self.toplevel(real, hash_end)
            if checkout is not None:
                kind = "repo"
        if kind == "unknown":
            return dict(out, digest_null_reason="outside-known-roots")
        out["base_kind"] = kind
        if kind == "plugin-cache":
            out["registry"] = self.marketplace_repo(claude, marketplace)
            out["ref"] = self.install_ref(claude, os.path.dirname(os.path.dirname(real)))
        elif kind == "repo":
            out["registry"] = self.origin_repo(checkout, hash_end)
        tree = self.tree(real, checkout, hash_end)
        reason = tree.get("reason")
        if reason is None and tree["latest"] > when.timestamp():
            reason = "changed-since-load"
        if reason is None:
            reason = self.digest(tree, hash_end)
        if reason is not None:
            return dict(out, digest_null_reason=reason)
        out["digest"] = tree["digest"]
        if kind == "user-skills":
            out["registry"], out["ref"] = self.bootstrap_entry(claude, bare, tree["digest"])
        return out

    def tree(self, real, checkout, hash_end):
        if real not in self.trees:
            try:
                skip = self.ignored(checkout, hash_end) if checkout is not None else frozenset()
                self.trees[real] = {"path": real, "skip": skip,
                                    "latest": latest_change(real, skip, hash_end)}
            except TooLarge:
                self.trees[real] = {"reason": "too-large"}
            except OSError:
                self.trees[real] = {"reason": "gone"}
        return self.trees[real]

    @staticmethod
    def digest(tree, hash_end):
        if "digest" not in tree:
            try:
                tree["digest"] = lock_digest(tree["path"], tree["skip"], hash_end)
            except Refused:
                tree["reason"] = "refused-by-registry-rules"
            except TooLarge:
                tree["reason"] = "too-large"
            except (OSError, UnicodeError):
                tree["reason"] = "gone"
            if "reason" in tree:
                tree["digest"] = None
        return tree.get("reason")

    def toplevel(self, real, hash_end):
        if real not in self.toplevels:
            code, out = git_out(["-C", real, "rev-parse", "--show-toplevel"], deadline=hash_end)
            if code == -1:
                raise BudgetOut()
            top = out.decode("utf-8", "replace").strip() if code == 0 else ""
            self.toplevels[real] = os.path.realpath(top) if top else None
        return self.toplevels[real]

    def ignored(self, checkout, hash_end):
        """The untracked files git ignores under `checkout`, absolute: the
        generator's `ignored_paths`."""
        code, out = git_out(["-c", "core.autocrlf=false", "-c", "core.eol=lf", "-C", checkout,
                             "ls-files", "--others", "--ignored", "--exclude-standard", "-z"],
                            deadline=hash_end)
        if code == -1:
            raise BudgetOut()
        if code != 0:
            raise OSError("git ls-files failed")
        return frozenset(os.path.normpath(os.path.join(checkout, os.fsdecode(n)))
                         for n in out.split(b"\0") if n)

    def origin_repo(self, checkout, hash_end):
        """`owner/repo` of the checkout's origin (github.com, or the hosted
        session's local proxy form), else None. The URL itself is never kept."""
        if checkout not in self.origins:
            code, out = git_out(["-C", checkout, "config", "--get", "remote.origin.url"],
                                deadline=hash_end)
            if code == -1:
                raise BudgetOut()
            url = out.decode("utf-8", "replace").strip() if code == 0 else ""
            found = GITHUB_REMOTE_RE.fullmatch(url) or PROXY_REMOTE_RE.fullmatch(url)
            repo = "%s/%s" % (found.group(1), found.group(2)) if found else None
            self.origins[checkout] = owner_repo(repo)
        return self.origins[checkout]

    def load(self, path):
        if path not in self.json:
            self.json[path] = load_json(path)
        return self.json[path]

    def marketplace_repo(self, claude, marketplace):
        known = self.load(os.path.join(claude, "plugins", "known_marketplaces.json"))
        entry = known.get(marketplace) if isinstance(known, dict) else None
        source = entry.get("source") if isinstance(entry, dict) else None
        if isinstance(source, dict) and source.get("source") == "github":
            return owner_repo(source.get("repo"))
        return None

    def install_ref(self, claude, version_root):
        record = self.load(os.path.join(claude, "plugins", "installed_plugins.json"))
        plugins = record.get("plugins") if isinstance(record, dict) else None
        for installs in plugins.values() if isinstance(plugins, dict) else ():
            for entry in installs if isinstance(installs, list) else ():
                path = entry.get("installPath") if isinstance(entry, dict) else None
                if not isinstance(path, str) or os.path.realpath(path) != version_root:
                    continue
                sha = entry.get("gitCommitSha")
                return sha if isinstance(sha, str) and SHA_RE.fullmatch(sha) else None
        return None

    def installed(self, claude):
        record = self.load(os.path.join(claude, "skills", ".skills-bootstrap-installed.json"))
        listed = record.get("installed") if isinstance(record, dict) else None
        return [e for e in listed if isinstance(e, dict)] if isinstance(listed, list) else []

    def bootstrap_entry(self, claude, name, digest):
        """(registry, ref) from skills-bootstrap.sh's install record, only when
        its entry for `name` names this copy's digest."""
        for entry in self.installed(claude):
            if entry.get("name") != name:
                continue
            recorded, url, ref = entry.get("digest"), entry.get("registry"), entry.get("ref")
            if isinstance(recorded, str) and recorded.startswith("sha256:"):
                recorded = recorded[len("sha256:"):]
            if recorded != digest or not isinstance(url, str):
                return None, None
            found = HTTPS_GITHUB_RE.fullmatch(url)
            return (owner_repo(found.group(1)) if found else None,
                    ref if isinstance(ref, str) and SHA_RE.fullmatch(ref) else None)
        return None, None


class Cloud:
    """Phase 2's per-session state under <state>/cloud-skills/<sha256 of the
    session id>.{state.json,pending.jsonl,lock}."""

    def __init__(self, states, digest, session, transcript):
        self.sid = digest[:16]
        self.session, self.transcript = session, transcript
        self.dir = os.path.join(states, CLOUD_DIR)
        self.path = os.path.join(self.dir, digest)
        self.states = states
        self.attempted = False
        self.copies = Copies()

    def prepare(self):
        os.makedirs(self.states, exist_ok=True)
        try:
            os.mkdir(self.dir, 0o700)
        except FileExistsError:
            pass
        return self.safe()

    def safe(self):
        """The state dir is a real directory of this user's, not a link."""
        try:
            info = os.lstat(self.dir)
        except OSError:
            return False
        return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()

    def lock(self):
        """A held lock's descriptor, or None when another Stop holds it."""
        import fcntl
        fd = os.open(self.path + ".lock",
                     os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(fd)
            return None
        return fd

    def load_state(self):
        doc = load_json(self.path + ".state.json", MAX_STATE)
        doc = doc if isinstance(doc, dict) else {}
        st = {"files": {}, "seen": [], "fails": 0, "next_try": 0, "nocred": False, "n": 0,
              "overflow": 0}
        for key, kind in (("files", dict), ("seen", list), ("fails", int), ("next_try", (int, float)),
                          ("nocred", bool), ("n", int), ("overflow", int)):
            if isinstance(doc.get(key), kind) and not (kind is int and isinstance(doc[key], bool)):
                st[key] = doc[key]
        return st

    def save_state(self, st):
        st["seen"] = st["seen"][-2 * SESSION_CAP:]
        write_atomic(self.path + ".state.json", json.dumps(st, separators=(",", ":")).encode("utf-8"))

    def load_pending(self):
        """[(id, month, line)] from the pending file; malformed lines dropped."""
        data = read_small(self.path + ".pending.jsonl", MAX_PENDING) or b""
        out, ids = [], set()
        for raw in data.split(b"\n"):
            try:
                doc = json.loads(raw)
            except ValueError:
                continue
            ident = doc.get("id") if isinstance(doc, dict) else None
            when = parse_ts(doc.get("ts")) if isinstance(doc, dict) else None
            if isinstance(ident, str) and ID_RE.fullmatch(ident) and when and ident not in ids:
                ids.add(ident)
                out.append((ident, when.strftime("%Y-%m"), raw.decode("utf-8")))
        return out

    def save_pending(self, items):
        write_atomic(self.path + ".pending.jsonl", "".join(t + "\n" for _i, _m, t in items).encode("utf-8"))

    def files(self):
        """("main", transcript), then this session's subagent transcripts."""
        yield "main", self.transcript
        if not ID_RE.fullmatch(self.session):
            return
        sub = os.path.join(os.path.dirname(self.transcript), self.session, "subagents")
        try:
            names = sorted(n for n in os.listdir(sub) if SUBAGENT_FILE_RE.fullmatch(n))
        except OSError:
            return
        for name in names[:MAX_SUBAGENT_FILES]:
            yield "sub:" + name, os.path.join(sub, name)

    def allowlisted(self, bare):
        """A typed command counts without a base directory only when its name
        is one skills-bootstrap.sh installed (the cloud's skill allowlist)."""
        home = os.environ.get("HOME") or ""
        return bool(home) and any(e.get("name") == bare for e in
                                  self.copies.installed(os.path.join(home, ".claude")))

    def event(self, use, hash_end):
        """The shard line for one settled use, or None when it is not recorded."""
        raw = use["name"]
        name = raw[1:] if raw.startswith("/") else raw
        valid = NAME_RE.fullmatch(name) is not None
        when = parse_ts(use["ts"])
        if when is None:
            return None                  # undated: skipped, as the local census does
        copy = self.copies.resolve(name if valid else None, use["base"], when, hash_end)
        if use["typed"] and use["base"] is None:
            reason = copy["digest_null_reason"]
            bare = name.split(":", 1)[-1]
            # A typed command with no skill behind it (/clear, /help) is no use.
            if not (reason == "builtin" or (reason == "no-base-dir" and self.allowlisted(bare))):
                return None
        cli = use["cli"]
        doc = {"v": 1, "id": use["id"], "ts": when.strftime(ISO), "kind": "skill", "surface": "cloud",
               "session": self.sid,
               "cli": cli if isinstance(cli, str) and CLI_RE.fullmatch(cli) else None,
               "name": name if valid else "invalid"}
        doc.update(copy)
        return json.dumps(doc, separators=(",", ":"))

    def collect(self):
        """Record every newly settled use into the pending file. Never holds
        the lock across the network; a busy lock skips this Stop."""
        t0 = time.monotonic()
        collect_end = min(t0 + COLLECT_BUDGET, START + BUDGET - MIN_CALL)
        parse_end = min(t0 + PARSE_BUDGET, collect_end)
        if not self.prepare():
            return
        fd = self.lock()
        if fd is None:
            return
        try:
            st = self.load_state()
            seen, new, left, hash_end, stop = set(st["seen"]), [], USES_PER_STOP, None, False
            for key, path in self.files():
                if stop:
                    break
                mark = st["files"].get(key)
                found = scan(path, mark if isinstance(mark, dict) else {}, self.session, parse_end)
                if found is None:
                    continue
                uses, cutoff, ident = found
                for use in uses:
                    if use["id"] in seen:
                        continue
                    if left <= 0:
                        cutoff, stop = use["start"], True
                        break
                    if hash_end is None:
                        hash_end = min(time.monotonic() + HASH_BUDGET, collect_end)
                    try:
                        line = self.event(use, hash_end)
                    except BudgetOut:
                        cutoff, stop = use["start"], True
                        break
                    left -= 1
                    if line is None:
                        continue
                    if st["n"] >= SESSION_CAP:
                        st["overflow"] += 1
                        continue
                    st["n"] += 1
                    seen.add(use["id"])
                    st["seen"].append(use["id"])
                    new.append(line)
                st["files"][key] = {"off": cutoff, "dev": ident[0], "ino": ident[1]}
            if new:
                pending = self.load_pending()
                have = {i for i, _m, _t in pending}
                for line in new:
                    doc = json.loads(line)
                    if doc["id"] not in have:
                        have.add(doc["id"])
                        pending.append((doc["id"], parse_ts(doc["ts"]).strftime("%Y-%m"), line))
                self.save_pending(pending)
            self.save_state(st)
        finally:
            os.close(fd)

    def snapshot(self):
        """The pending lines to upload now, or None: nothing pending, a
        definite no-credential answer earlier, or still backing off."""
        if not self.safe():
            return None
        fd = self.lock()
        if fd is None:
            return None
        try:
            st = self.load_state()
            if st["nocred"] or (st["fails"] > 0 and epoch() < st["next_try"]):
                return None
            return self.load_pending() or None
        finally:
            os.close(fd)

    def held_guidance(self):
        """The S3 route's held phase-1 line, or None: none held, a definite
        no-credential answer earlier, or still backing off."""
        if not self.safe():
            return None
        fd = self.lock()
        if fd is None:
            return None
        try:
            st = self.load_state()
            if st["nocred"] or (st["fails"] > 0 and epoch() < st["next_try"]):
                return None
            data = read_small(self.path + ".guidance.pending", MAX_STATE)
            try:
                text = data.decode("utf-8").strip() if data else ""
                doc = json.loads(text) if text else None
            except ValueError:
                return None
            return text if isinstance(doc, dict) and doc.get("kind") == "guidance-load" else None
        finally:
            os.close(fd)

    def finish(self, outcome, snap, sent=None, guidance=None):
        """Under a fresh lock: drop the uploaded ids from pending and record
        the outcome. `sent`, when given, is the ids that landed (the S3 route
        can land some objects and not others); otherwise "ok" means all of
        `snap`. A busy lock leaves both; the next Stop re-uploads and the
        reader dedupes by id."""
        if not self.safe():
            return
        fd = self.lock()
        if fd is None:
            return
        try:
            st, t = self.load_state(), epoch()
            done = set(sent) if sent is not None else (
                {i for i, _m, _t in snap} if outcome == "ok" else set())
            if done:
                self.save_pending([p for p in self.load_pending() if p[0] not in done])
            if guidance is not None:
                # (phase-1 line, landed): hold it for the next Stop, or let it go.
                text, landed = guidance
                if landed:
                    try:
                        os.unlink(self.path + ".guidance.pending")
                    except FileNotFoundError:
                        pass
                else:
                    write_atomic(self.path + ".guidance.pending", (text + "\n").encode("utf-8"))
            if outcome == "ok":
                st["fails"], st["next_try"] = 0, 0
            elif outcome == "race":
                st["next_try"] = t
            elif outcome == "nocred":
                st["nocred"] = True
            else:
                st["fails"] = min(st["fails"] + 1, 30)
                st["next_try"] = t + min(BACKOFF_BASE * 2 ** (st["fails"] - 1), BACKOFF_CAP)
            self.save_state(st)
        finally:
            os.close(fd)


# ── main ────────────────────────────────────────────────────────────────────

def phase1(states, digest, transcript, cloud):
    flag = os.path.join(states, "done", digest)
    if os.path.exists(flag):
        return
    try:
        files, surface, cli, responses, report, listing = read_transcript(transcript)
    except OSError:
        return
    if files is None:
        if responses < 3:
            return
        state, repos, expected, check_expected = "unknown", 0, None, None
    else:
        state, repos = classify(files), repo_count(files)
        expected = expected_check(files)
        check_expected = expected is not None

    os.makedirs(os.path.dirname(flag), exist_ok=True)
    try:
        os.close(os.open(flag, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600))
    except FileExistsError:
        return

    when = now()
    remote = os.environ.get("CLAUDE_CODE_REMOTE") == "true" or bool(os.environ.get("CLAUDE_CODE_REMOTE_SESSION_ID"))
    record = {
        "v": 1,
        "ts": when.strftime(ISO),
        "kind": "guidance-load",
        "session": digest[:16],
        "surface": surface if isinstance(surface, str) and SURFACE_RE.fullmatch(surface) else None,
        "remote": remote,
        "cli": cli if isinstance(cli, str) and CLI_RE.fullmatch(cli) else None,
        "state": state,
        "repos": repos,
        "guidance_version": guidance_version(),
        "check_expected": check_expected,
        "check_reported": check_outcome(expected, report),
        "registry_sha": None,
    }
    record["sources"], record["sources_dropped"] = registry_sources()
    if listing is not None:
        record["listing"] = listing
    line = json.dumps(record, separators=(",", ":"))
    uploaded = None
    if remote:
        uploaded = upload(line, when, cloud)
    record["uploaded"] = uploaded
    fd = os.open(os.path.join(states, "sessions.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":")) + "\n")


def main():
    try:
        event = json.loads(os.environ.get("GUIDANCE_HOOK_INPUT") or "")
    except ValueError:
        return
    if not isinstance(event, dict) or event.get("hook_event_name", "Stop") != "Stop":
        return
    session, transcript = event.get("session_id"), event.get("transcript_path")
    if not isinstance(session, str) or not session or not isinstance(transcript, str):
        return
    states = state_dir()
    if states is None:
        return
    digest = hashlib.sha256(session.encode("utf-8")).hexdigest()
    # Phase 2 is cloud only, and only CLAUDE_CODE_REMOTE=true says so: a local
    # session reaches no phase-2 code past this test.
    cloud = None
    if os.environ.get("CLAUDE_CODE_REMOTE") == "true":
        try:
            cloud = Cloud(states, digest, session, transcript)
            cloud.collect()          # every Stop, before phase 1's once-per-session return
        except Exception:
            pass
    try:
        phase1(states, digest, transcript, cloud)
    except Exception:
        pass
    if cloud is not None and not cloud.attempted:
        try:
            upload(None, now(), cloud)
        except Exception:
            pass


# Tests load this source as a module (any other __name__) to call its helpers.
if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
PY
exit 0
