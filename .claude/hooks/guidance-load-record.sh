#!/usr/bin/env bash
# guidance-load-record.sh — one line per session: did Claude Code load the FULL
# fleet guidance, or only the repo stub?
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
#    "registry_sha":null,"uploaded":null}
# `session` is a sha256 prefix of the session id, never the id. `surface` and
# `cli` are the transcript's own `entrypoint` and `version`. `repos` counts the
# distinct directories holding a Project-type AGENTS.md or CLAUDE.md (a
# `<repo>/.claude/CLAUDE.md` counts as `<repo>`). `guidance_version` is the
# 8-hex id fleet-memory.sh wrote into user memory's CLAUDE.md. `registry_sha`
# is always null for now: skills-bootstrap.sh's install record
# (~/.claude/skills/.skills-bootstrap-installed.json) stores each skill's
# name, registry URL, bundle and digest, but no commit, so there is nothing to
# read it from. `uploaded` is true or false when an upload was tried, null when
# it was not. No paths, names, titles or file content are ever recorded.
#
# UPLOAD (cloud only, optional)
# -----------------------------
# A cloud container's state dies with it, so when the session is remote
# (CLAUDE_CODE_REMOTE=true or CLAUDE_CODE_REMOTE_SESSION_ID set) the same line
# (without `uploaded`) is appended to events/<YYYY-MM>/cloud-guidance.jsonl on
# branch persistent/usage-events of Adam-S-Daniel/adam-agentskills-private,
# through the contents API. A 409 or 422 on the write (someone else appended
# first) re-reads the file and retries once. Two credentials, in order:
#
# 1. The session's own. A hosted session's agent proxy REPLACES any
#    Authorization header sent to api.github.com with the session's GitHub
#    credential, which reaches only the repos attached to the session, and it
#    refuses /app/* paths outright (measured 2026-10-31: "Bearer garbage" got
#    200 on the private repo; an App JWT got 401 "could not be decoded"). So
#    the hook first asks GET /repos/<repo> with no Authorization header, and
#    writes that way when the answer is 200 with permissions.push true, which
#    is the case whenever the private repo is attached.
# 2. A GitHub App, where no proxy rewrites the header: when
#    USAGE_WRITER_APP_CLIENT_ID and USAGE_WRITER_APP_PEM (the PEM text, or that
#    text base64-encoded) are set, an installation token minted from that App,
#    scoped to that one repo with contents: write. The JWT and token reach curl
# through `--config -` on stdin, never argv; the PEM is written to a 0600 file
# in a private temp dir for openssl and removed. No token, PEM or response
# body is ever printed. Every call has a 10-second cap, inside a 15-second
# overall budget, under the 20-second hook timeout.
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
# Test seams: GUIDANCE_RECORD_NOW (an ISO 8601 UTC time, e.g.
# 2026-10-31T12:00:00Z) replaces the clock; GUIDANCE_RECORD_API (default
# https://api.github.com) replaces the API base URL.

exec 1>/dev/null 2>/dev/null

command -v python3 >/dev/null 2>&1 || exit 0

GUIDANCE_HOOK_INPUT="$(cat 2>/dev/null)" || GUIDANCE_HOOK_INPUT=""
export GUIDANCE_HOOK_INPUT

python3 -I -S - <<'PY' || true
import base64
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

REPO = "Adam-S-Daniel/adam-agentskills-private"
BRANCH = "persistent/usage-events"
FULL = ("guidance-marker: fleet-full", "## Working in these repos")
STUB = ("guidance-marker: fleet-stub", "Fleet guidance is delivered once per session")
ISO = "%Y-%m-%dT%H:%M:%SZ"
START = time.monotonic()
BUDGET = 15.0


def now():
    raw = os.environ.get("GUIDANCE_RECORD_NOW", "")
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


def read_transcript(path):
    """(instruction files, entrypoint, cli version, assistant responses)."""
    files, surface, cli, assistant = None, None, None, set()
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
            elif kind == "attachment":
                att = entry.get("attachment")
                if isinstance(att, dict) and att.get("type") == "instructions":
                    listed = att.get("files")
                    files = files or []
                    if isinstance(listed, list):
                        files += [f for f in listed if isinstance(f, dict)]
    return files, surface, cli, len(assistant)


def classify(files):
    texts = [f.get("content") for f in files if isinstance(f.get("content"), str)]
    if any(sig in t for t in texts for sig in FULL):
        return "full"
    if any(sig in t for t in texts for sig in STUB):
        return "stub-only"
    return "neither"


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


# ── upload ──────────────────────────────────────────────────────────────────

def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def remaining():
    return BUDGET - (time.monotonic() - START)


def api(work, method, url, bearer, body=None):
    """(status, parsed JSON or None). The bearer, if any, reaches curl on stdin
    only; None sends no Authorization header."""
    cap = min(10.0, remaining())
    if cap < 1:
        return 0, None
    out = os.path.join(work, "response")
    args = ["curl", "-sS", "--max-time", str(int(cap)), "-X", method,
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
        'header = "User-Agent: guidance-load-record"\n')
    try:
        done = subprocess.run(args, input=config, capture_output=True, text=True, timeout=cap + 1)
        status = int(done.stdout.strip() or 0)
    except (OSError, ValueError, subprocess.SubprocessError):
        return 0, None
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


def app_jwt(work, client_id, pem, at):
    key = os.path.join(work, "key.pem")
    fd = os.open(key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(pem if pem.endswith("\n") else pem + "\n")
    try:
        head = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}, separators=(",", ":")).encode())
        body = b64url(json.dumps({"iat": at - 60, "exp": at + 540, "iss": client_id},
                                 separators=(",", ":")).encode())
        signed = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key],
                                input=("%s.%s" % (head, body)).encode("ascii"),
                                capture_output=True, timeout=5)
        if signed.returncode != 0 or not signed.stdout:
            return None
        return "%s.%s.%s" % (head, body, b64url(signed.stdout))
    finally:
        os.unlink(key)


def append(work, base, token, line, when):
    path = "events/%s/cloud-guidance.jsonl" % when.strftime("%Y-%m")
    url = "%s/repos/%s/contents/%s" % (base, REPO, path)
    for _attempt in range(2):
        status, doc = api(work, "GET", "%s?ref=%s" % (url, BRANCH), token)
        if status == 200 and isinstance(doc, dict) and doc.get("encoding") == "base64" \
                and isinstance(doc.get("sha"), str):
            try:
                old = base64.b64decode(doc.get("content") or "")
            except ValueError:
                return False
            sha = doc["sha"]
        elif status == 404:
            old, sha = b"", None
        else:
            return False
        if old and not old.endswith(b"\n"):
            old += b"\n"
        body = {"message": "guidance-load event", "branch": BRANCH,
                "content": base64.b64encode(old + line.encode("utf-8") + b"\n").decode("ascii")}
        if sha:
            body["sha"] = sha
        status, _doc = api(work, "PUT", url, token, body)
        if status in (200, 201):
            return True
        if status not in (409, 422):
            return False
    return False


def app_token(work, base, when):
    client_id = os.environ.get("USAGE_WRITER_APP_CLIENT_ID", "")
    pem = os.environ.get("USAGE_WRITER_APP_PEM", "")
    if not client_id or not pem or shutil.which("openssl") is None:
        return None
    if "-----BEGIN" not in pem:
        # An environment-variable field may not hold a multi-line value, so
        # the key may also be given base64-encoded.
        try:
            pem = base64.b64decode("".join(pem.split()), validate=True).decode("ascii")
        except ValueError:
            return None
    jwt = app_jwt(work, client_id, pem, int(when.timestamp()))
    if not jwt:
        return None
    status, doc = api(work, "GET", "%s/repos/%s/installation" % (base, REPO), jwt)
    inst = doc.get("id") if status == 200 and isinstance(doc, dict) else None
    if not isinstance(inst, int):
        return None
    status, doc = api(work, "POST", "%s/app/installations/%d/access_tokens" % (base, inst), jwt,
                      {"repositories": [REPO.split("/", 1)[1]], "permissions": {"contents": "write"}})
    token = doc.get("token") if status == 201 and isinstance(doc, dict) else None
    return token if isinstance(token, str) and token else None


def upload(line, when):
    base = (os.environ.get("GUIDANCE_RECORD_API") or "https://api.github.com").rstrip("/")
    if shutil.which("curl") is None:
        return False
    work = tempfile.mkdtemp(prefix="guidance-record.")
    try:
        status, doc = api(work, "GET", "%s/repos/%s" % (base, REPO), None)
        perms = doc.get("permissions") if status == 200 and isinstance(doc, dict) else None
        if isinstance(perms, dict) and perms.get("push") is True:
            return append(work, base, None, line, when)
        token = app_token(work, base, when)
        return append(work, base, token, line, when) if token else False
    except Exception:
        return False
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ── main ────────────────────────────────────────────────────────────────────

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
    flag = os.path.join(states, "done", digest)
    if os.path.exists(flag):
        return
    try:
        files, surface, cli, responses = read_transcript(transcript)
    except OSError:
        return
    if files is None:
        if responses < 3:
            return
        state, repos = "unknown", 0
    else:
        state, repos = classify(files), repo_count(files)

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
        "surface": surface,
        "remote": remote,
        "cli": cli,
        "state": state,
        "repos": repos,
        "guidance_version": guidance_version(),
        "registry_sha": None,
    }
    line = json.dumps(record, separators=(",", ":"))
    uploaded = None
    if remote:
        uploaded = upload(line, when)
    record["uploaded"] = uploaded
    fd = os.open(os.path.join(states, "sessions.jsonl"), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(record, separators=(",", ":")) + "\n")


try:
    main()
except Exception:
    pass
PY
exit 0
