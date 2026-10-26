#!/usr/bin/env bash
# agent-checks-guard: a Claude Code PreToolUse hook that refuses the easy ways
# to skip or switch off the fleet's commit-time git hooks (ADR 0021), and the
# deletion of a remote persistent/* branch.
#
# Refuses, with a message saying what to do instead:
#   - `git commit` or `git push` with --no-verify, or `git commit -n`;
#   - git run with hook config overridden: `-c core.hooksPath=...`,
#     `-c hook.<name>...`, `-c includeIf...`, or GIT_CONFIG_* variables;
#   - `git config` writes to core.hooksPath, hook.* or includeIf.*;
#   - deleting, moving or editing .githooks/ or the installed agent-hooks.inc,
#     by a shell command or by an Edit/Write tool call;
#   - deleting a persistent/* branch on a remote: `git push <remote> --delete`
#     or `-d` naming one, a `:persistent/...` refspec, or
#     `gh api -X DELETE .../git/refs/heads/persistent/...`.
#
# This stops habit, not intent: a determined agent can still get around a
# string check. The required agent-checks CI check is the enforcement.
#
# Exit 2 with a message on stderr blocks the tool call. Anything else lets it
# run, including every failure of this script itself (no python3, input it
# cannot parse): a broken guard must never stop work.
#
# Managed by _agent-guidance (templates/agent-checks/). The sync overwrites
# this file in every fleet repo, so change it there, not here.

command -v python3 >/dev/null 2>&1 || exit 0

python3 -c '
import json, os, re, shlex, sys

try:
    event = json.load(sys.stdin)
except Exception:
    sys.exit(0)

tool = event.get("tool_name") or ""
tool_input = event.get("tool_input") or {}

AFTER = ("Fix what the check reported instead. If the check itself is wrong, "
         "say so to Adam. CI runs the same checks, so skipping the hook only "
         "moves the failure later.")


def block(what, after=AFTER):
    sys.stderr.write("agent-checks-guard: refused: " + what + ". " + after + "\n")
    sys.exit(2)


PERSISTENT_AFTER = ("persistent/* branches outlive their pull requests and hold data "
                    "(results, accumulated state), and a private repo has no ruleset to "
                    "stop the delete. If it must go, ask Adam.")
PERSISTENT_REF = re.compile(r"^(refs/)?(heads/)?persistent/")
PERSISTENT_API = re.compile(r"(^|/)repos/[^/]+/[^/]+/git/refs/heads/persistent/")
PUSH_ARG_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}


def block_persistent(name):
    block("deleting the remote branch " + name, PERSISTENT_AFTER)


def check_gh_api(args):
    method, endpoints, i = "GET", [], 0
    while i < len(args):
        a = args[i]
        if a in ("-X", "--method") and i + 1 < len(args):
            method = args[i + 1]
            i += 2
            continue
        if a.startswith("--method="):
            method = a.split("=", 1)[1]
        elif a.startswith("-X") and len(a) > 2:
            method = a[2:]
        elif not a.startswith("-"):
            endpoints.append(a)
        i += 1
    if method.upper() != "DELETE":
        return
    for e in endpoints:
        e = re.sub(r"%2[fF]", "/", e)
        if PERSISTENT_API.search(e):
            block_persistent(e.split("/git/refs/heads/", 1)[1])


def check_push(args):
    delete, positional, i = False, [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            positional.extend(args[i + 1:])
            break
        if a in PUSH_ARG_OPTS:
            i += 2
            continue
        if a == "--delete" or (a.startswith("-") and not a.startswith("--") and "d" in a[1:]):
            delete = True
        elif not a.startswith("-"):
            positional.append(a)
        i += 1
    for spec in positional[1:]:
        spec = spec.lstrip("+")
        if delete and ":" not in spec:
            dst = spec
        elif spec.startswith(":"):
            dst = spec[1:]
        else:
            continue
        if PERSISTENT_REF.match(dst):
            block_persistent(dst)


def protected(path):
    p = path.replace("\\", "/")
    return ("/.githooks/" in "/" + p or p.endswith("/.githooks")
            or p == ".githooks" or p.endswith("agent-hooks.inc"))


if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    path = str(tool_input.get("file_path") or tool_input.get("notebook_path") or "")
    if path and protected(path):
        block(path + " holds the fleet git hooks, which _agent-guidance manages")
    sys.exit(0)

if tool != "Bash":
    sys.exit(0)

command = str(tool_input.get("command") or "")

# Heredoc bodies are data (a commit message that mentions --no-verify, a file
# being written), not commands: drop them before splitting.
lines, out, delim = command.split("\n"), [], None
for line in lines:
    if delim is not None:
        if line.strip() == delim:
            delim = None
        continue
    out.append(line)
    m = re.search(r"<<-?\s*([\"\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1", line)
    if m:
        delim = m.group(2)
text = " ; ".join(out)

try:
    lex = shlex.shlex(text, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    tokens = list(lex)
except ValueError:
    sys.exit(0)

SEPARATORS = {";", "&&", "||", "|", "&", "(", ")", "{", "}", ";;", "|&"}
commands, current = [], []
for tok in tokens:
    if tok in SEPARATORS:
        if current:
            commands.append(current)
        current = []
    else:
        current.append(tok)
if current:
    commands.append(current)

HOOK_KEY = re.compile(r"^(core\.hookspath|hook\.|includeif\.)", re.I)
GIT_ENV = re.compile(r"^GIT_CONFIG_(GLOBAL|SYSTEM|NOSYSTEM|COUNT|PARAMETERS|KEY_\d+|VALUE_\d+)=")
CONFIG_READS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "-l",
                "--list", "get", "list", "--show-origin", "--show-scope"}
COMMIT_ARG_OPTS = set("mFCctS")

for words in commands:
    env = []
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        env.append(words.pop(0))
    if words and words[0] == "env":
        words.pop(0)
        while words and (words[0].startswith("-") or "=" in words[0]):
            env.append(words.pop(0))
    if not words:
        continue
    prog = os.path.basename(words[0])

    # Redirection into a protected path, whatever the program.
    for i, w in enumerate(words):
        if w in (">", ">>", ">|") and i + 1 < len(words) and protected(words[i + 1]):
            block("writing to " + words[i + 1])

    if prog in ("rm", "mv", "truncate", "chmod", "unlink", "shred"):
        for w in words[1:]:
            if protected(w):
                block(prog + " on " + w)
    if prog == "sed" and any(w.startswith("-i") or w == "--in-place" for w in words[1:]):
        for w in words[1:]:
            if protected(w):
                block("editing " + w + " in place")

    if prog == "gh" and len(words) > 1 and words[1] == "api":
        check_gh_api(words[2:])
        continue

    if prog != "git":
        continue

    # Global options before the subcommand.
    i, overrides = 1, []
    while i < len(words) and words[i].startswith("-"):
        w = words[i]
        if w in ("-c", "--config-env") and i + 1 < len(words):
            overrides.append(words[i + 1])
            i += 2
            continue
        if w.startswith("--config-env="):
            overrides.append(w.split("=", 1)[1])
        if w in ("-C", "--git-dir", "--work-tree", "--namespace") and i + 1 < len(words):
            i += 2
            continue
        i += 1
    sub = words[i] if i < len(words) else ""
    args = words[i + 1:]

    if sub == "push":
        check_push(args)

    if sub == "config":
        keys = [a for a in args if HOOK_KEY.match(a)]
        if keys and not any(a in CONFIG_READS for a in args):
            block("git config changes " + keys[0] + ", which controls whether the fleet git hooks run")
        continue

    if sub not in ("commit", "push", "merge", "rebase", "cherry-pick", "am", "revert"):
        continue

    for o in overrides:
        if HOOK_KEY.match(o):
            block("git -c " + o + " overrides the fleet git hooks")
    for e in env:
        if GIT_ENV.match(e):
            block(e.split("=", 1)[0] + " swaps the git config the fleet hooks are installed in")

    for a in args:
        if a == "--":
            break
        if a == "--no-verify":
            block("git " + sub + " --no-verify skips the fleet git hooks")
    if sub == "commit":
        skip_next = False
        for a in args:
            if skip_next:
                skip_next = False
                continue
            if a == "--":
                break
            if a.startswith("-") and not a.startswith("--") and len(a) > 1:
                for ch in a[1:]:
                    if ch == "n":
                        block("git commit -n skips the fleet git hooks")
                    if ch in COMMIT_ARG_OPTS:
                        skip_next = a.endswith(ch)
                        break

sys.exit(0)
'
rc=$?
[ "$rc" -eq 2 ] && exit 2
exit 0
