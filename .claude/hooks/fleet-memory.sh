#!/usr/bin/env bash
# fleet-memory.sh — deliver the fleet's managed guidance ONCE per session.
#
# WHY THIS EXISTS
# ---------------
# The managed guidance used to be inlined into every repo's AGENTS.md, which
# Claude Code imports from that repo's CLAUDE.md. A session with N repos
# attached therefore loaded N identical copies. Measured 2026-08-29 on a hosted
# multi-repo session: 37 memory files, 332.3k tokens — a third of a 1M window —
# almost all of it ONE ~52 kB managed block repeated 19 times.
#
# User-level memory (~/.claude/CLAUDE.md) is read ONCE per session no matter how
# many repos are attached. That is where the fleet-wide block belongs; each repo
# keeps only what is genuinely its own, plus a small stub.
#
# THE THREE MEASUREMENTS THIS DESIGN RESTS ON
# -------------------------------------------
# Local CLI 2.1.251, tool-free single-turn probes, baseline context 34.5k:
#
#   1. An `@import` inlines ONLY when the target resolves INSIDE the project
#      tree. A nested in-tree import works (53,441 tokens, canary retrieved);
#      `@~/.claude/...` and out-of-tree absolute paths silently load NOTHING
#      (34,4xx, canary absent) — no error, no warning. So "one shared file that
#      every repo imports" is NOT available, which is why the content is
#      delivered to USER memory instead of imported from a shared path.
#   2. A SessionStart hook runs BEFORE memory is assembled. With no
#      ~/.claude/CLAUDE.md at launch, this hook wrote one and the SAME session
#      read it (53,439 tokens, canary retrieved). That is what makes the first
#      session in a fresh container correct rather than one session late.
#   3. The hosted harness does the same. Verified in a cloud session on
#      _agent-guidance@claude/agents-md-redundancy-uvw9am: the canary was in
#      context at session start, attributed to
#      "Contents of /root/.claude/CLAUDE.md (user's private global instructions
#      for all projects)". Local-only evidence would not have settled this,
#      because the hosted harness assembles memory itself.
#
# WHAT IT WRITES
# --------------
# A MARKED BLOCK, never the whole file, to TWO surfaces — one per agent CLI
# that reads a global instructions file:
#
#   ~/.claude/CLAUDE.md   (or $CLAUDE_CONFIG_DIR/CLAUDE.md) — Claude Code's
#                         user memory. Always.
#   ~/.codex/AGENTS.md    (or $CODEX_HOME/AGENTS.md) — Codex's global USER
#                         instructions. A nonempty AGENTS.override.md takes
#                         precedence in normal mode. Normal mode writes Codex
#                         only when its home already exists; explicit Codex
#                         Cloud mode creates the home during setup.
#
# The Codex destination is the GLOBAL one on purpose. Codex reads the AGENTS.md
# chain from the project root down to cwd under a running byte budget,
# `project_doc_max_bytes`, default 32768 — and a file that does not fit is CUT
# at that byte with only a `tracing::warn!("project doc exceeds remaining
# budget; truncating")` in `codex-rs/core/src/agents_md.rs` that no ordinary
# session ever sees (codex-cli 0.154.0, measured 2026-09-14 on cms-platform:
# `codex debug prompt-input` rendered a 55,788-byte AGENTS.md (a
# feature-branch checkout; `main`'s copy was 71,794 bytes) as exactly
# 32,768 bytes, ending mid-heading). Putting ~50 kB of fleet guidance into a
# repo's own AGENTS.md would therefore silently evict that repo's own
# additions. The global file is loaded by a different path —
# `codex-rs/codex-home/src/instructions/mod.rs`, as USER instructions — and is
# NOT counted against that budget, which is why the guidance goes there while
# the repo stub stays the floor inside the repo. See
# docs/decisions/0012-codex-gets-the-guidance-as-user-instructions.md.
#
# A developer's own global instructions are theirs; everything outside the
# markers is preserved. Normal mode orders deliveries by the payload's last
# commit time (or its mtime when dirty) so an older checkout cannot replace a
# newer version. The `fleet-guidance-delivered` marker records that integer
# epoch beside the version in normal-mode blocks. A tie favors this checkout;
# the same hash only refreshes an older stamp. Replacements are atomic and
# follow destination symlinks.
#
# CODEX CLOUD MODE
# ----------------
# `--codex-cloud` is called directly from environment setup and maintenance.
# It exits before the legacy hook path below, targets Codex only, selects a
# nonempty AGENTS.override.md when present, persists its verdict inside the
# managed block, and returns nonzero on a delivery failure. It uses Python's
# byte-oriented and atomic file operations so content outside an existing
# block is unchanged and a failed replacement never truncates the destination.
#
# STDIN AND STDOUT
# ----------------
# With no arguments Claude Code runs this as a SessionStart hook; so does Codex,
# through a user-level entry registered once per machine by
# `scripts/register-codex-hook.sh`. With `--workspace <dir>`, Codex can start
# from a parent of fleet repos: the freshest immediate child's payload takes
# the normal delivery path, and a second line lists repo-local AGENTS.md files
# that Codex did not load from that parent. `--codex-cloud` remains the explicit
# setup mode. Codex passes the hook event as one JSON
# object on stdin — this script never reads stdin, which is part of what makes
# one file correct for both harnesses — and adds a command hook's plain-text
# stdout to the session as developer context. Normal mode emits one verdict
# line; workspace mode adds the repo list when one exists.
#
# In its normal hook mode it always exits 0. A guidance delivery that breaks
# the session is worse than
# one that degrades, and the repo stub is the floor: every repo still carries
# the load-bearing rules inline, so a DEGRADED session is diminished, not blind.
# The verdict line below is what keeps that degradation VISIBLE rather than
# silent — the failure mode this hook most needs to avoid is working quietly
# until the day it doesn't. A failure at ONE destination never stops the other:
# the run finishes every destination it can and then reports DEGRADED naming
# the one that failed.
set -uo pipefail

# Observation is optional and never participates in delivery decisions. The
# embedded helper ships with this hook; sync needs no additional artifact.
: <<'FLEET_RECEIPT_PY'
import errno
import hashlib
import json
import os
import stat
import sys
import time

RECEIPT_LIMIT = 1048576


def receipt_source(path, begin, end, directory_fd=None):
    # Read only a validated delivered file; hash its unique managed block.
    options = {} if directory_fd is None else {"dir_fd": directory_fd}
    info = os.stat(path, follow_symlinks=False, **options)
    if not stat.S_ISREG(info.st_mode):
        raise OSError("unsafe receipt source")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, **options)
    try:
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
                info.st_uid != os.geteuid() or info.st_size > 4194304):
            raise OSError("unsafe receipt source")
        remaining = info.st_size
        pieces = []
        while remaining:
            piece = os.read(fd, min(remaining, 65536))
            if not piece:
                raise OSError("short receipt source")
            pieces.append(piece)
            remaining -= len(piece)
        raw = b"".join(pieces)
    finally:
        os.close(fd)
    offset = 0
    start = stop = None
    for line in raw.splitlines(keepends=True):
        if line.rstrip(b"\r\n") == begin.encode():
            if start is not None:
                raise ValueError("ambiguous receipt block")
            start = offset
        if line.rstrip(b"\r\n") == end.encode():
            if start is None or stop is not None:
                raise ValueError("ambiguous receipt block")
            stop = offset + len(line)
        offset += len(line)
    if start is None or stop is None:
        raise ValueError("missing receipt block")
    block = raw[start:stop]
    return hashlib.sha256(block).hexdigest(), len(block)


class ReceiptUnsupported(Exception):
    pass


def receipt_capabilities():
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK", "geteuid", "fpathconf")
    # Check platform support by name: syscall fault injectors may wrap os.open.
    supported = {function.__name__ for function in getattr(os, "supports_dir_fd", ())}
    if any(not hasattr(os, name) for name in required) or not {"open", "stat"} <= supported:
        raise ReceiptUnsupported()
    if not any(function.__name__ == "stat" for function in
               getattr(os, "supports_follow_symlinks", ())):
        raise ReceiptUnsupported()


def receipt_platform(call, *args, **kwargs):
    # Unsupported descriptor primitives silently skip best-effort observation.
    try:
        return call(*args, **kwargs)
    except NotImplementedError:
        raise ReceiptUnsupported() from None


def receipt_directory(directory):
    receipt_capabilities()
    descriptors = []
    try:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK
        path = directory if os.path.isabs(directory) else os.path.join(os.getcwd(), directory)
        parent = receipt_platform(os.open, "/", flags)
        descriptors.append(parent)
        for component in path.split("/")[1:]:
            if component in ("", "."):
                continue
            if component == "..":
                raise OSError("unsafe receipt directory")
            try:
                parent = receipt_platform(os.open, component, flags, dir_fd=parent)
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOTDIR) and stat.S_ISLNK(
                        receipt_platform(os.stat, component, dir_fd=parent, follow_symlinks=False).st_mode):
                    raise ReceiptUnsupported() from None
                raise
            descriptors.append(parent)
        receipt_platform(os.fpathconf, parent, "PC_PIPE_BUF")
        return descriptors
    except BaseException:
        for fd in reversed(descriptors):
            os.close(fd)
        raise


def receipt_write(directory, mode, deliveries):
    # Validate support and every parent BEFORE optional clock or digest work.
    descriptors = receipt_directory(directory)
    try:
        record = {"ts": int(time.time()), "hook": "fleet-memory",
                  "load_reason": "delivery", "mode": mode, "deliveries": deliveries}
        line = (json.dumps(record, separators=(",", ":")) + "\n").encode()
        parent = descriptors[-1]
        try:
            target = receipt_platform(os.stat, "fleet-delivery.jsonl", dir_fd=parent,
                                      follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISREG(target.st_mode):
                raise OSError("unsafe receipt")
        fd = receipt_platform(os.open, "fleet-delivery.jsonl", os.O_WRONLY | os.O_APPEND |
                     os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=parent)
        descriptors.append(fd)
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid():
            raise OSError("unsafe receipt")
        if info.st_size >= RECEIPT_LIMIT:
            return
        if len(line) >= min(4096, receipt_platform(os.fpathconf, fd, "PC_PIPE_BUF")):
            raise OSError("oversized receipt")
        # One append syscall, no retries, read/modify/write, locks, or rotation.
        if os.write(fd, line) != len(line):
            raise OSError("short receipt write")
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def receipt_delivery(label, outcome, digest=None, count=0):
    return {"file_path": label, "memory_type": "User", "outcome": outcome,
            "sha256": digest, "bytes": count}


def receipt_worker(directory, mode, begin, end, *args):
    try:
        # Reject unsupported receipt paths before any optional digest work.
        descriptors = receipt_directory(directory)
        for fd in reversed(descriptors):
            os.close(fd)
        if mode not in ("hook", "workspace", "codex-cloud"):
            raise ValueError("invalid receipt mode")
        if len(args) not in (5, 10) or sum(len(os.fsencode(arg)) + 1 for arg in args) >= 4096:
            raise ValueError("invalid receipt metadata")
        deliveries = []
        for i in range(0, len(args), 5):
            label, outcome, source, digest, count = args[i:i + 5]
            if label not in ("none", "claude/CLAUDE.md", "codex/AGENTS.md", "codex/AGENTS.override.md"):
                raise ValueError("invalid receipt label")
            if outcome not in ("written", "installed", "current", "kept", "skipped", "degraded"):
                raise ValueError("invalid receipt outcome")
            count = int(count)
            if source:
                source_descriptors = receipt_directory(os.path.dirname(source))
                try:
                    digest, count = receipt_source(os.path.basename(source), begin, end,
                                                   source_descriptors[-1])
                finally:
                    for fd in reversed(source_descriptors):
                        os.close(fd)
            if digest and (len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest)):
                raise ValueError("invalid receipt digest")
            if count < 0 or count > 4194304 or bool(digest) != bool(count):
                raise ValueError("invalid receipt bytes")
            deliveries.append(receipt_delivery(label, outcome, digest or None, count))
        receipt_write(directory, mode, deliveries)
    except Exception:
        # Observation is detached, silent, and never controls delivery.
        pass


if __name__ == "__main__":
    receipt_worker(*sys.argv[1:])
FLEET_RECEIPT_PY
RECEIPT_MODE=hook
RECEIPT_ARGS=()
RECEIPT_BROKEN=0
RECEIPT_SOURCE=""
# shellcheck disable=SC2317  # invoked by EXIT traps, including early failures
receipt_flush() {
    [ "${FLEET_GUIDANCE_RECEIPT:-1}" != 0 ] || return 0
    if [ "$RECEIPT_BROKEN" -ne 0 ]; then RECEIPT_ARGS=(none degraded "" invalid 0)
    elif [ "${#RECEIPT_ARGS[@]}" -eq 0 ]; then RECEIPT_ARGS=(none degraded "" "" 0); fi
    local receipt_directory="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
    [ "$RECEIPT_MODE" != codex-cloud ] || receipt_directory="$CODEX_DEST_DIR"
    # Bash 3.2 and Git Bash support this detached launch. Every stream is closed
    # so the writer cannot retain caller output pipes or read hook events.
    # -S defers sitecustomize until after the alarm is armed. Restoring normal
    # site startup keeps the interpreter environment unchanged for observation.
    (python3 -S -c '
import _signal as signal
try:
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(5)
except (AttributeError, OSError, ValueError):
    # Platforms without a usable POSIX alarm skip optional observation.
    raise SystemExit(0)
import site
site.main()
import os, stat, sys
try:
    info = os.stat(sys.argv[1], follow_symlinks=False)
    if not stat.S_ISREG(info.st_mode):
        raise OSError("unsafe receipt helper")
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.geteuid() or info.st_size > 4194304:
            raise OSError("unsafe receipt helper")
        remaining, pieces = info.st_size, []
        while remaining:
            piece = os.read(fd, min(remaining, 65536))
            if not piece:
                raise OSError("short receipt helper")
            pieces.append(piece)
            remaining -= len(piece)
        source = b"".join(pieces).decode("utf-8")
    finally:
        os.close(fd)
    marker = ": <<" + chr(39) + "FLEET_RECEIPT_PY" + chr(39) + "\n"
    helper = source.split(marker, 1)[1].split("\nFLEET_RECEIPT_PY\n", 1)[0]
    namespace = {"__name__": "receipt"}
    exec(helper, namespace)
    namespace["receipt_worker"](*sys.argv[2:])
except Exception:
    pass
' "${BASH_SOURCE[0]}" "$receipt_directory" "$RECEIPT_MODE" \
        "${BEGIN_MARK:-}" "${END_MARK:-}" \
        "${RECEIPT_ARGS[@]}" </dev/null >/dev/null 2>&1 &) 2>/dev/null || :
    return 0
}
trap receipt_flush EXIT

CODEX_CLOUD=0
WORKSPACE_DIR=""
if [ "$#" -eq 0 ]; then
    :
elif [ "$#" -eq 1 ] && [ "$1" = --codex-cloud ]; then
    CODEX_CLOUD=1
    RECEIPT_MODE=codex-cloud
elif [ "$#" -eq 2 ] && [ "$1" = --workspace ] && [ -d "$2" ]; then
    WORKSPACE_DIR="$2"
    RECEIPT_MODE=workspace
else
    echo "fleet-guidance: DEGRADED — unknown argument or nonexistent workspace directory; expected no arguments, --codex-cloud, or --workspace <dir>"
    exit 2
fi

WORKSPACE_LINE=""
if [ -n "$WORKSPACE_DIR" ]; then
    # Set the collation for Bash's glob and string comparisons in this mode.
    # The normal and Cloud modes keep the caller's locale unchanged.
    LC_ALL=C
    export LC_ALL
    # A repo's own AGENTS.md is only loaded when Codex starts inside that
    # repo. Keep the inventory independent of payload delivery and opt-out.
    workspace_names=()
    for child in "$WORKSPACE_DIR"/* "$WORKSPACE_DIR"/.[!.]* "$WORKSPACE_DIR"/..?*; do
        if { [ -d "$child/.git" ] || [ -f "$child/.git" ]; } && [ -f "$child/AGENTS.md" ]; then
            workspace_names+=("$(basename "$child")")
        fi
    done
    if [ "${#workspace_names[@]}" -gt 0 ]; then
        sorted_names=()
        sorted_count=0
        for name in "${workspace_names[@]}"; do
            position=$sorted_count
            while [ "$position" -gt 0 ] && [[ "$name" < "${sorted_names[$((position - 1))]}" ]]; do
                sorted_names[position]="${sorted_names[$((position - 1))]}"
                position=$((position - 1))
            done
            sorted_names[position]="$name"
            sorted_count=$((sorted_count + 1))
        done
        workspace_list=""
        for name in "${sorted_names[@]}"; do
            workspace_list="${workspace_list:+$workspace_list, }$name"
        done
        WORKSPACE_LINE="fleet-workspace: $WORKSPACE_DIR is a multi-repo parent; this session loaded no repo's own AGENTS.md (Codex reads them only from the launch directory's git root down). Before working in a repo, read its AGENTS.md: $workspace_list"
    fi
fi
# shellcheck disable=SC2317  # reached through both EXIT traps below
workspace_notice() { [ -z "$WORKSPACE_LINE" ] || printf '%s\n' "$WORKSPACE_LINE"; }
trap 'workspace_notice; receipt_flush' EXIT

BEGIN_MARK='<!-- BEGIN FLEET GUIDANCE (managed by _agent-guidance) — DO NOT EDIT -->'
END_MARK='<!-- END FLEET GUIDANCE -->'

# Payload ships beside this hook, deliberately OUTSIDE any memory-file path
# (only CLAUDE.md / AGENTS.md are auto-loaded), so it costs zero always-on
# context in the repo that carries it.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || HOOK_DIR=""
PAYLOAD="${FLEET_GUIDANCE_PAYLOAD:-$HOOK_DIR/fleet-guidance.md}"
CODEX_DEST_DIR="${CODEX_HOME:-$HOME/.codex}"

# The payload's bytes are an exact copy of agents-md/base.md, so an ordering
# key cannot live inside them. Its last commit tells when this checkout
# received those bytes; a dirty or untracked payload uses its file mtime.
# One helper serves workspace selection and the normal installation path.
normalize_stamp() {
    # Decimal strings avoid octal interpretation and arithmetic overflow on
    # malformed or unusually large metadata.
    NORMAL_STAMP="$1"
    case "$NORMAL_STAMP" in ""|*[!0-9]*) NORMAL_STAMP=0; return ;; esac
    while [ "${#NORMAL_STAMP}" -gt 1 ] && [ "${NORMAL_STAMP:0:1}" = 0 ]; do
        NORMAL_STAMP="${NORMAL_STAMP:1}"
    done
}
payload_stamp() {
    local source="$1" source_dir source_name git_worktree status stamp=0
    source_dir="$(dirname "$source")"
    source_name="$(basename "$source")"
    if git_worktree="$(git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null)" &&
        [ "$git_worktree" = true ]; then
        if status="$(git -C "$source_dir" status --porcelain -- "$source_name" 2>/dev/null)"; then
            if [ -n "$status" ]; then
                stamp="$(stat -c %Y "$source" 2>/dev/null || stat -f %m "$source" 2>/dev/null)" || stamp=0
            else
                stamp="$(git -C "$source_dir" log -1 --format=%ct -- "$source_name" 2>/dev/null)" || stamp=0
            fi
        fi
    fi
    normalize_stamp "$stamp"
    PAYLOAD_STAMP="$NORMAL_STAMP"
}
stamp_ge() {
    [ "${#1}" -gt "${#2}" ] || {
        [ "${#1}" -eq "${#2}" ] && { [ "$1" = "$2" ] || [[ "$1" > "$2" ]]; }
    }
}
stamp_gt() { stamp_ge "$1" "$2" && [ "$1" != "$2" ]; }

if [ -n "$WORKSPACE_DIR" ]; then
    # Bash expands these paths in sorted order. Equal stamps keep the first.
    workspace_payload=""
    workspace_stamp=0
    for candidate in "$WORKSPACE_DIR"/*/.claude/hooks/fleet-guidance.md; do
        if [ ! -f "$candidate" ] || [ ! -r "$candidate" ] || [ ! -s "$candidate" ]; then
            continue
        fi
        payload_stamp "$candidate"
        if [ -z "$workspace_payload" ] || stamp_gt "$PAYLOAD_STAMP" "$workspace_stamp"; then
            workspace_payload="$candidate"
            workspace_stamp="$PAYLOAD_STAMP"
        fi
    done
    [ -z "$workspace_payload" ] || PAYLOAD="$workspace_payload"
fi

# One spelling policy serves both execution modes. Character classes keep the
# comparison case-insensitive without adding an external command to the
# shell-only legacy path.
case "${FLEET_GUIDANCE_SKIP:-}" in
    ""|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) FLEET_GUIDANCE_SKIP_ENABLED=0 ;;
    *) FLEET_GUIDANCE_SKIP_ENABLED=1 ;;
esac

if [ "$CODEX_CLOUD" -eq 1 ]; then
    cloud_result="$(python3 - \
        "$CODEX_DEST_DIR" "$PAYLOAD" "$BEGIN_MARK" "$END_MARK" \
        "$FLEET_GUIDANCE_SKIP_ENABLED" 2>/dev/null <<'PY'
import hashlib
import os
import pathlib
import stat
import sys
import tempfile

receipt_outcome = "degraded"
receipt_block = None
receipt_label = "none"


class Refusal(Exception):
    pass


def refuse(reason):
    raise Refusal(reason)


def marker_span(raw, begin, end):
    begins = []
    ends = []
    offset = 0
    for line in raw.splitlines(keepends=True):
        bare = line.rstrip(b"\r\n")
        if bare == begin:
            begins.append(offset)
        if bare == end:
            ends.append(offset + len(line))
        offset += len(line)
    if raw.count(begin) != len(begins) or raw.count(end) != len(ends):
        refuse("effective global instructions have malformed fleet-guidance markers")
    if not begins and not ends:
        return None
    if len(begins) != 1 or len(ends) != 1 or begins[0] >= ends[0]:
        refuse("effective global instructions have malformed fleet-guidance markers")
    return begins[0], ends[0]


def regular_readable(path, label):
    try:
        info = path.lstat()
    except OSError:
        refuse(f"could not inspect {label}")
    if not stat.S_ISREG(info.st_mode) or not os.access(path, os.R_OK):
        refuse(f"{label} is not a readable regular file")
    return info


try:
    codex_home = pathlib.Path(sys.argv[1])
    payload_path = pathlib.Path(sys.argv[2])
    begin = sys.argv[3].encode()
    end = sys.argv[4].encode()
    skip = sys.argv[5] == "1"

    payload = b""
    if not skip:
        try:
            payload = payload_path.read_bytes()
        except OSError:
            refuse("fleet-guidance payload is missing or unreadable")
        if not payload:
            refuse("fleet-guidance payload is empty")
        if begin in payload or end in payload or any(
            line.startswith(b"fleet-guidance:") for line in payload.splitlines()
        ):
            refuse("fleet-guidance payload contains a reserved marker or verdict")

    try:
        codex_home.mkdir(parents=True, exist_ok=True)
    except OSError:
        refuse("could not create Codex home")
    if not codex_home.is_dir():
        refuse("Codex home is not a directory")

    override = codex_home / "AGENTS.override.md"
    agents = codex_home / "AGENTS.md"
    if os.path.lexists(override):
        override_info = regular_readable(override, "AGENTS.override.md")
        target = override if override_info.st_size > 0 else agents
    else:
        target = agents
    label = "~/.codex/AGENTS.override.md" if target == override else "~/.codex/AGENTS.md"
    receipt_label = "codex/AGENTS.override.md" if target == override else "codex/AGENTS.md"

    original = b""
    original_mode = None
    if os.path.lexists(target):
        target_info = regular_readable(target, "effective global instructions")
        original_mode = stat.S_IMODE(target_info.st_mode)
        try:
            original = target.read_bytes()
        except OSError:
            refuse("could not read effective global instructions")

    span = marker_span(original, begin, end)
    if skip:
        body = (
            b"fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set) "
            + "— Codex Cloud setup and maintenance".encode()
            + b"\n"
        )
        verdict = f"fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set) — persisted in {label}"
    else:
        version = hashlib.sha256(payload).hexdigest()[:8]
        payload_body = payload if payload.endswith(b"\n") else payload + b"\n"
        persisted = (
            f"fleet-guidance: installed (v{version}, {len(payload)} bytes) "
            "— Codex Cloud setup and maintenance"
        ).encode()
        body = (
            f"<!-- fleet-guidance-version: {version} -->\n".encode()
            + persisted
            + b"\n"
            + payload_body
        )
    block = begin + b"\n" + body + end + b"\n"

    if span is None:
        separator = b"" if not original or original.endswith(b"\n") else b"\n"
        candidate = original + separator + block
    else:
        candidate = original[:span[0]] + block + original[span[1]:]

    changed = candidate != original
    if changed:
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix=".fleet-guidance-", dir=target.parent)
            if original_mode is not None:
                os.fchmod(fd, original_mode)
            with os.fdopen(fd, "wb") as stream:
                stream.write(candidate)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
            temporary = None
        except OSError:
            refuse("could not write effective global instructions")
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass

    receipt_outcome = "skipped" if skip else "installed" if changed else "current"
    if changed and not skip:
        receipt_block = block
    if skip:
        print(verdict)
    elif changed:
        print(f"fleet-guidance: installed (v{version}, {len(payload)} bytes) -> {label}")
    else:
        print(f"fleet-guidance: current (v{version}, {len(payload)} bytes) — {label}")
except Refusal as exc:
    print(f"fleet-guidance: DEGRADED — {exc}")
    raise SystemExit(1)
except Exception:
    print("fleet-guidance: DEGRADED — unexpected Cloud setup failure")
    raise SystemExit(1)
finally:
    if os.environ.get("FLEET_GUIDANCE_RECEIPT", "1") != "0":
        try:
            digest = hashlib.sha256(receipt_block).hexdigest() if receipt_block is not None else ""
            count = len(receipt_block) if receipt_block is not None else 0
            # Private metadata is stripped before any verdict reaches stdout.
            print("fleet-receipt-meta:" + "|".join((receipt_label, receipt_outcome, digest, str(count))))
        except Exception:
            print("fleet-receipt-meta:broken")
PY
)"
    cloud_status=$?
    if [[ "$cloud_result" == *$'\n'fleet-receipt-meta:* ]]; then
        cloud_meta="${cloud_result##*$'\n'fleet-receipt-meta:}"
        cloud_result="${cloud_result%$'\n'fleet-receipt-meta:*}"
        if [ "$cloud_meta" = broken ]; then RECEIPT_BROKEN=1
        else
            IFS='|' read -r receipt_label receipt_outcome receipt_digest receipt_bytes <<< "$cloud_meta"
            RECEIPT_ARGS=("$receipt_label" "$receipt_outcome" "" "$receipt_digest" "$receipt_bytes")
        fi
    fi
    if [ -z "$cloud_result" ]; then
        cloud_result="fleet-guidance: DEGRADED — Python 3 is unavailable for Codex Cloud setup"
        cloud_status=1
    fi
    printf '%s\n' "$cloud_result"
    exit "$cloud_status"
fi

# ── Destinations ───────────────────────────────────────────────────────────
#
# The LABELS are the canonical `~/…` spellings rather than the resolved paths:
# they are what the verdict names, and a test overriding CLAUDE_CONFIG_DIR or
# CODEX_HOME should not change the sentence an operator reads. Every FAILURE
# message names the resolved path instead, because those have to be actionable.
CLAUDE_DEST_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_DEST="$CLAUDE_DEST_DIR/CLAUDE.md"
CODEX_DEST="$CODEX_DEST_DIR/AGENTS.md"
CODEX_OVERRIDE="$CODEX_DEST_DIR/AGENTS.override.md"
# shellcheck disable=SC2088  # the tilde is LITERAL here on purpose: these two
# are prose shown to a human, never paths anything opens. The paths are the
# four lines above.
CLAUDE_LABEL="~/.claude/CLAUDE.md"
# shellcheck disable=SC2088
CODEX_LABEL="~/.codex/AGENTS.md"
# shellcheck disable=SC2088
CODEX_OVERRIDE_LABEL="~/.codex/AGENTS.override.md"

# Claude Code is always in play — its config dir is created if absent, as it
# always was. Codex is in play only when its home ALREADY EXISTS: creating
# ~/.codex on a machine that has never run Codex would manufacture config for a
# tool that is not installed, and the empty directory would then read as
# "Codex is set up here" to everything that probes for it.
DEST_PATHS=("$CLAUDE_DEST")
DEST_LABELS=("$CLAUDE_LABEL")
if [ -d "$CODEX_DEST_DIR" ]; then
    if [ -e "$CODEX_OVERRIDE" ] || [ -L "$CODEX_OVERRIDE" ]; then
        if [ -f "$CODEX_OVERRIDE" ] && [ -r "$CODEX_OVERRIDE" ] && [ -s "$CODEX_OVERRIDE" ]; then
            DEST_PATHS+=("$CODEX_OVERRIDE")
            DEST_LABELS+=("$CODEX_OVERRIDE_LABEL")
        elif [ ! -f "$CODEX_OVERRIDE" ] || [ ! -r "$CODEX_OVERRIDE" ]; then
            # Still visit it: an invalid override must report a failure, not
            # silently fall back to AGENTS.md.
            DEST_PATHS+=("$CODEX_OVERRIDE")
            DEST_LABELS+=("$CODEX_OVERRIDE_LABEL")
        else
            DEST_PATHS+=("$CODEX_DEST")
            DEST_LABELS+=("$CODEX_LABEL")
        fi
    else
        DEST_PATHS+=("$CODEX_DEST")
        DEST_LABELS+=("$CODEX_LABEL")
    fi
fi

# Joined once, for the verdict. Only destinations that were in play appear, so
# a machine without Codex reads exactly the line it read before this hook
# learned about Codex at all.
dest_list() {
    local out="" l
    for l in "${DEST_LABELS[@]}"; do out="${out:+$out, }$l"; done
    printf '%s' "$out"
}

FAILURES=""
record_failure() { FAILURES="${FAILURES:+$FAILURES; }$1"; }

TMP_FILES=()
# shellcheck disable=SC2317  # reached through the EXIT trap below, not by a call
cleanup_tmp() {
    workspace_notice
    receipt_flush
    [ "${#TMP_FILES[@]}" -eq 0 ] && return 0
    local t
    for t in "${TMP_FILES[@]}"; do rm -f "$t"; done
    return 0
}
trap cleanup_tmp EXIT

new_tmp() {
    TMP_PATH="$(mktemp "$1/.fleet-guidance.XXXXXX" 2>/dev/null)" || return 1
    TMP_FILES+=("$TMP_PATH")
}

# Resolve the file itself before replacement. `mv` onto a symlink would replace
# the link, whereas the agent still reads its target. The manual path is for
# systems without readlink -f; the hop limit also refuses cycles.
resolve_target() {
    local path="$1" next parent hops=0
    RESOLVED_DEST=""
    if [ -L "$path" ] && [ ! -e "$path" ]; then return 1; fi
    if RESOLVED_DEST="$(readlink -f -- "$path" 2>/dev/null)" && [ -n "$RESOLVED_DEST" ]; then
        return 0
    fi
    while :; do
        parent="$(cd -P "$(dirname "$path")" 2>/dev/null && pwd)" || return 1
        path="$parent/$(basename "$path")"
        [ -L "$path" ] || { RESOLVED_DEST="$path"; return 0; }
        hops=$((hops + 1))
        [ "$hops" -le 40 ] || return 1
        next="$(readlink "$path" 2>/dev/null)" || return 1
        case "$next" in /*) path="$next" ;; *) path="$parent/$next" ;; esac
    done
}

replace_file() {
    local source="$1" dest="$2" mode
    mode="$(stat -c %a "$dest" 2>/dev/null || stat -f %Lp "$dest" 2>/dev/null)"
    if [ -n "$mode" ]; then chmod "$mode" "$source" 2>/dev/null || :; fi
    mv -f "$source" "$dest" 2>/dev/null
}

# A fault that leaves NOTHING deliverable anywhere — no payload, no hook
# directory to find one in. Nothing per-destination belongs here: those are
# recorded and reported together at the end, so one broken surface cannot cost
# the others their delivery.
degraded() {
    echo "fleet-guidance: DEGRADED — $1. Repo stub only; read the fleet guidance in _agent-guidance/agents-md/base.md before non-trivial work."
    exit 0
}

# Write $2 with $1's managed block stripped out and everything else verbatim.
# Returns non-zero with the reason in STRIP_ERR; the caller decides what that
# costs — one destination, never the run.
#
# NEVER OVERWRITE A FILE WHOSE CURRENT CONTENTS COULD NOT BE READ. On a durable
# machine ~/.claude/CLAUDE.md is the developer's own global memory — and
# ~/.codex/AGENTS.md their own global Codex instructions — and this hook is a
# guest in both. An earlier draft fell back to an EMPTY strip result when the
# read failed, then appended the block to that emptiness and copied it over the
# top — so a file that was writable but not readable (mode 0200, a mount quirk,
# an ACL) was silently REPLACED by the fleet block alone, and the verdict still
# said `installed`. Measured: a personal CLAUDE.md destroyed, with a success
# line. Every unreadable-or-unparseable shape degrades instead.
strip_managed_block() {
    local dest="$1" out="$2"
    STRIP_ERR=""
    if [ ! -e "$dest" ]; then : > "$out"; return 0; fi
    if [ ! -f "$dest" ]; then
        STRIP_ERR="$dest exists but is not a regular file — refusing to replace it"
        return 1
    fi
    if [ ! -r "$dest" ]; then
        STRIP_ERR="$dest exists but is not readable — refusing to overwrite content I cannot preserve"
        return 1
    fi

    TMP_FILES+=("$out.raw")
    if ! BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" awk '
        BEGIN { b = ENVIRON["BEGIN_MARK"]; e = ENVIRON["END_MARK"]; skip = 0 }
        index($0, b) == 1 { skip = 1; next }
        index($0, e) == 1 { skip = 0; next }
        !skip { print }
    ' "$dest" > "$out.raw" 2>/dev/null; then
        rm -f "$out.raw"
        STRIP_ERR="could not read or parse $dest — refusing to overwrite content I cannot preserve"
        return 1
    fi

    # Drop trailing blank lines so repeated runs cannot grow the file, and so a
    # file whose ONLY content was the block collapses to empty rather than
    # accumulating a blank line per run.
    local kept; kept="$(cat "$out.raw" 2>/dev/null)"
    if [ -n "$kept" ]; then printf '%s\n' "$kept" > "$out"; else : > "$out"; fi
    rm -f "$out.raw"
    return 0
}

# ── Opt-out ────────────────────────────────────────────────────────────────
#
# FLEET_GUIDANCE_SKIP exists because user memory is GLOBAL on a durable
# machine. ~/.claude/CLAUDE.md is read in EVERY Claude session on that box, and
# ~/.codex/AGENTS.md in every Codex session in every project on it, so once a
# fleet repo has been opened once, the guidance rides along into unrelated
# projects too. That is a fair trade for some machines and not others, and it
# is the developer's call, not this hook's. ONE flag governs BOTH surfaces,
# because the reason to opt out is the same reason on each.
#
# It REMOVES an already-installed block rather than merely declining to write
# one. Skipping the write alone would leave a block installed by an earlier
# session sitting in the file and still loading — an opt-out that does not opt
# you out, which is worse than none because it looks like it worked.
#
# `0`, `false`, `no` and `off` are honoured as OFF, case-insensitively. Treating
# any non-empty value as ON would make `FLEET_GUIDANCE_SKIP=0` mean "skip", and
# a flag whose disabled spelling enables it is a trap worth two lines of code
# to avoid.
case "$FLEET_GUIDANCE_SKIP_ENABLED" in
    0) ;;
    1)
        removed=""      # destinations a block was actually removed from
        present=0       # destinations that exist at all
        SKIP_PATHS=("$CLAUDE_DEST")
        SKIP_LABELS=("$CLAUDE_LABEL")
        if [ -d "$CODEX_DEST_DIR" ]; then
            SKIP_PATHS+=("$CODEX_DEST")
            SKIP_LABELS+=("$CODEX_LABEL")
            if [ -e "$CODEX_OVERRIDE" ] || [ -L "$CODEX_OVERRIDE" ]; then
                SKIP_PATHS+=("$CODEX_OVERRIDE")
                SKIP_LABELS+=("$CODEX_OVERRIDE_LABEL")
            fi
        fi
        for i in "${!SKIP_PATHS[@]}"; do
            dest="${SKIP_PATHS[$i]}"; label="${SKIP_LABELS[$i]}"
            [ -e "$dest" ] || [ -L "$dest" ] || continue
            present=$((present + 1))
            if ! resolve_target "$dest"; then
                record_failure "could not resolve $dest"
                continue
            fi
            target="$RESOLVED_DEST"
            new_tmp "$(dirname "$target")" || { record_failure "mktemp failed for $dest"; continue; }
            tmp="$TMP_PATH"
            if ! strip_managed_block "$target" "$tmp"; then
                record_failure "$STRIP_ERR"
                continue
            fi
            if cmp -s "$tmp" "$target" 2>/dev/null; then
                continue                      # nothing of ours in there
            elif replace_file "$tmp" "$target"; then
                removed="${removed:+$removed, }$label"
            else
                record_failure "FLEET_GUIDANCE_SKIP is set but $dest could not be rewritten to remove the managed block"
            fi
        done

        if [ -n "$FAILURES" ]; then
            echo "fleet-guidance: DEGRADED — $FAILURES. FLEET_GUIDANCE_SKIP is set, so the managed block may still be loading there."
        elif [ -n "$removed" ]; then
            echo "fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set) — removed the managed block from $removed; your own content is untouched"
        elif [ "$present" -gt 0 ]; then
            echo "fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set) — no managed block present"
        else
            echo "fleet-guidance: skipped (FLEET_GUIDANCE_SKIP set)"
        fi
        RECEIPT_ARGS=(none skipped "" "" 0)
        [ -z "$FAILURES" ] || RECEIPT_ARGS=(none degraded "" "" 0)
        exit 0
        ;;
esac

[ -n "$HOOK_DIR" ] || degraded "cannot resolve hook directory"
[ -r "$PAYLOAD" ]  || degraded "no readable payload at $PAYLOAD"
[ -s "$PAYLOAD" ]  || degraded "payload at $PAYLOAD is empty"

# Short content id, so the verdict names WHICH guidance landed. Any of these
# three digest tools may be absent; a missing one is cosmetic, never fatal.
version="$( { sha256sum "$PAYLOAD" 2>/dev/null || shasum -a 256 "$PAYLOAD" 2>/dev/null || openssl dgst -sha256 "$PAYLOAD" 2>/dev/null; } \
            | tr ' ' '\n' | grep -oE '^[0-9a-f]{64}$' | head -1 )"
version="${version:0:8}"
[ -n "$version" ] || version="unknown"

bytes="$(wc -c < "$PAYLOAD" 2>/dev/null | tr -d ' ')"

# See docs/decisions/0016-the-freshest-delivery-wins-the-shared-global-block.md.
payload_stamp "$PAYLOAD"
delivered="$PAYLOAD_STAMP"

# Read metadata from inside the managed block only. A developer's own prose
# may mention either marker text without being delivery metadata.
read_installed_metadata() {
    local dest="$1" raw
    raw="$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
        $0 == b { inside=1; next }
        $0 == e { inside=0 }
        inside && /^<!-- fleet-guidance-version: / && !v { v=$0 }
        inside && /^<!-- fleet-guidance-delivered: / && !d { d=$0 }
        END { print v; print d }
    ' "$dest" 2>/dev/null)" || raw=""
    existing_version="${raw%%$'\n'*}"
    existing_delivered="${raw#*$'\n'}"
    if [[ "$existing_version" == '<!-- fleet-guidance-version: '*" -->" ]]; then
        existing_version="${existing_version#<!-- fleet-guidance-version: }"
        existing_version="${existing_version% -->}"
    else existing_version=""; fi
    [[ "$existing_version" =~ ^[0-9a-f]{8}$ ]] || existing_version=""
    if [[ "$existing_delivered" == '<!-- fleet-guidance-delivered: '*" -->" ]]; then
        existing_delivered="${existing_delivered#<!-- fleet-guidance-delivered: }"
        existing_delivered="${existing_delivered% -->}"
    else existing_delivered=""; fi
    normalize_stamp "$existing_delivered"
    existing_delivered="$NORMAL_STAMP"
}

# On a same-content upgrade, change only the ordering metadata. Retain the
# block's position and its payload, including a personal suffix after it.
update_stamp_only() {
    local source="$1" out="$2" line ending inside=0 inserted=0
    # shellcheck disable=SC2002  # the pipe lets pipefail detect a source read error
    cat "$source" | {
        while :; do
            if IFS= read -r line; then ending=$'\n';
            else ending=""; [ -n "$line" ] || break; fi
            if [ "$line" = "$BEGIN_MARK" ]; then inside=1; fi
            if [ "$inside" -eq 1 ] && [[ "$line" == '<!-- fleet-guidance-delivered: '* ]]; then
                continue
            fi
            printf '%s%s' "$line" "$ending" || return 1
            if [ "$inside" -eq 1 ] && [ "$inserted" -eq 0 ] && [[ "$line" == '<!-- fleet-guidance-version: '* ]]; then
                printf '<!-- fleet-guidance-delivered: %s -->\n' "$delivered" || return 1
                inserted=1
            fi
            if [ "$line" = "$END_MARK" ]; then inside=0; fi
        done
        [ "$inserted" -eq 1 ]
    } > "$out"
}

# Install the block at ONE destination. Sets INSTALL_STATE to `written`,
# `current` (including a stamp-only refresh), or `kept`; on failure records
# the reason and returns non-zero, having
# changed nothing at that destination.
install_to() {
    local dest="$1" label="$2" tmp dir target
    INSTALL_STATE=""
    RECEIPT_SOURCE=""

    # The parent directory: created for Claude Code exactly as it always was,
    # and a no-op for Codex, whose directory had to exist for this destination
    # to be in play at all.
    dir="$(dirname "$dest")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        record_failure "cannot create $dir"
        return 1
    fi

    if ! resolve_target "$dest"; then
        record_failure "could not resolve $dest"
        return 1
    fi
    target="$RESOLVED_DEST"
    if [ "$dest" = "$CODEX_OVERRIDE" ] && { [ ! -f "$target" ] || [ ! -r "$target" ]; }; then
        record_failure "$dest is not a readable regular file"
        return 1
    fi
    if [ -e "$target" ]; then
        if [ ! -f "$target" ] || [ ! -r "$target" ]; then
            if [ ! -f "$target" ]; then
                record_failure "$target exists but is not a regular file — refusing to replace it"
            else
                record_failure "$target exists but is not readable — refusing to overwrite content I cannot preserve"
            fi
            return 1
        fi
        read_installed_metadata "$target"
        if [ "$existing_version" = "$version" ]; then
            if ! stamp_gt "$delivered" "$existing_delivered"; then
                INSTALL_STATE="current"
                return 0
            fi
            dir="$(dirname "$target")"
            new_tmp "$dir" || { record_failure "mktemp failed for $dest"; return 1; }
            tmp="$TMP_PATH"
            if ! update_stamp_only "$target" "$tmp"; then
                record_failure "could not update delivery stamp in $dest"
                return 1
            fi
            if replace_file "$tmp" "$target"; then
                INSTALL_STATE="current"
                RECEIPT_SOURCE="$target"
                return 0
            fi
            record_failure "could not write $dest"
            return 1
        fi
        if ! stamp_ge "$delivered" "$existing_delivered"; then
            INSTALL_STATE="kept"
            KEPT="${KEPT:+$KEPT, }v${existing_version:-unknown} at $label"
            return 0
        fi
    fi

    dir="$(dirname "$target")"
    new_tmp "$dir" || { record_failure "mktemp failed for $dest"; return 1; }
    tmp="$TMP_PATH"

    if ! strip_managed_block "$target" "$tmp"; then
        record_failure "$STRIP_ERR"
        return 1
    fi
    [ -s "$tmp" ] && printf '\n' >> "$tmp"

    {
        printf '%s\n' "$BEGIN_MARK" &&
        printf '<!-- fleet-guidance-version: %s -->\n' "$version" &&
        printf '<!-- fleet-guidance-delivered: %s -->\n' "$delivered" &&
        cat "$PAYLOAD" &&
        printf '%s\n' "$END_MARK"
    } >> "$tmp" 2>/dev/null || {
        record_failure "could not assemble the guidance block for $dest"
        return 1
    }

    if cmp -s "$tmp" "$target" 2>/dev/null; then
        INSTALL_STATE="current"
        return 0
    fi

    if replace_file "$tmp" "$target"; then
        INSTALL_STATE="written"
        RECEIPT_SOURCE="$target"
        return 0
    fi

    record_failure "could not write $dest"
    return 1
}

wrote=0
KEPT=""
local_labels=""
for i in "${!DEST_PATHS[@]}"; do
    dest="${DEST_PATHS[$i]}"; label="${DEST_LABELS[$i]}"
    receipt_label="${label#\~/\.}"
    if ! install_to "$dest" "$label"; then
        RECEIPT_ARGS+=("$receipt_label" degraded "" "" 0)
        continue
    fi
    RECEIPT_ARGS+=("$receipt_label" "$INSTALL_STATE" "$RECEIPT_SOURCE" "" 0)
    case "$INSTALL_STATE" in
        written)
            wrote=$((wrote + 1))
            local_labels="${local_labels:+$local_labels, }$label"
            ;;
        current) local_labels="${local_labels:+$local_labels, }$label" ;;
    esac
done

# ── Verdict ────────────────────────────────────────────────────────────────
#
# ONE line, with the same three prefixes the repo stub and the tests key on.
# Any destination that failed makes the whole run DEGRADED even when another
# succeeded: a session holding the guidance in Claude Code and not in Codex is
# running on the stub alone in one of its two harnesses, and it has to be able
# to see that. An installed arrow names only destinations carrying the local
# version; a kept suffix names each destination retaining newer guidance.
if [ -n "$FAILURES" ]; then
    echo "fleet-guidance: DEGRADED — $FAILURES. Repo stub only there; read the fleet guidance in _agent-guidance/agents-md/base.md before non-trivial work."
else
    if [ "$wrote" -gt 0 ]; then
        verdict="fleet-guidance: installed (v$version, ${bytes} bytes) -> $local_labels"
    else
        verdict="fleet-guidance: current (v$version, ${bytes} bytes) — $(dest_list)"
    fi
    if [ -n "$KEPT" ]; then
        verdict="$verdict; kept newer $KEPT — this checkout's payload is older, pull it to refresh"
    fi
    echo "$verdict"
fi
exit 0
