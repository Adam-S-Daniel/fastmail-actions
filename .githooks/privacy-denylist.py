#!/usr/bin/env python3
"""privacy-denylist.py - refuse a denylisted personal detail in ref names and commits.

The agent-checks runner (.githooks/agent-checks) calls this from its pre-push
event, and a CI-mode check can call it the same way. It reads the pushed ref
names and, for each commit it is given, the message and the author and
committer identity, and reports where a denylisted pattern matches.

A scanner that prints what it looks for would publish exactly the detail it
protects, so the list never appears in a repository, and this script never
prints it back: on a match it prints the PLACE and the pattern NUMBER only,
never the matched text and never the pattern.

Where the denylist comes from, first match wins:

  PRIVACY_DENYLIST       newline-separated regular expressions (a CI secret)
  --denylist-file PATH   a file holding the same thing
  PRIVACY_DENYLIST_FILE  the same, from the environment
  ~/.config/privacy-denylist.txt

One pattern per line. Blank lines and lines starting with `#` are ignored.
Patterns are Python regular expressions matched CASE-INSENSITIVELY; a pattern
that needs case says so inline with `(?-i:...)`. The format is the one
adam-agentskills' scripts/check_privacy_denylist.py defines.

Usage:
  privacy-denylist.py [--repo PATH] [--ref NAME]... [--commits-stdin]
                      [--diff BASE HEAD] [--event-path PATH]
                      [--denylist-file PATH]

  --ref NAME        a ref name to check (refs/heads/ and refs/tags/ prefixes
                    are dropped first); repeatable
  --commits-stdin   read commit ids, one per line, from standard input and
                    check each one's message and identity
  --diff BASE HEAD  scan the lines ADDED between BASE and HEAD (the diff from
                    their merge base, so lines that landed on BASE's branch do
                    not count), by new-file line number. A BASE that is empty,
                    all zeros or not in this clone scans HEAD's own diff
                    against its parent instead. Binary files are skipped.
  --event-path PATH a GitHub event payload; scans pull_request.title and
                    pull_request.body. A payload with no pull_request is
                    ignored.

Output, on a match (stdout):
  FAILED: <n> denylisted match(es). ...
    branch name: pattern #N
    <sha12>:message:<line>: pattern #N
    <sha12>:identity:<line>: pattern #N      (1 author name, 2 author email,
                                              3 committer name, 4 committer email)
    <path>:<line>: pattern #N                (a line added by --diff)
    <path withheld>: pattern #N              (an added or renamed path matches)
    PR title:1: pattern #N                   (--event-path)
    PR body:<line>: pattern #N

Exit status: 0 clean; 1 a match; 2 the check could not run (an unreadable file,
an invalid pattern, git failing); 3 no denylist is configured, so nothing was
checked (the caller decides what that means; locally it is not a failure).
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Iterator, List, Mapping, Optional, Sequence, Tuple

ENV_PATTERNS = "PRIVACY_DENYLIST"
ENV_FILE = "PRIVACY_DENYLIST_FILE"
DEFAULT_FILE = Path(".config") / "privacy-denylist.txt"

EXIT_CLEAN = 0
EXIT_MATCH = 1
EXIT_ERROR = 2
EXIT_NO_DENYLIST = 3

# A match is (where, pattern index). `where` is already formatted for output.
Match = Tuple[str, int]

_SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")


class CheckError(Exception):
    """The check could not run. The message never contains a pattern."""


def _read_denylist(environ: Mapping[str, str], file_arg: Optional[str]) -> Optional[str]:
    """The raw denylist text, or None when no source exists."""
    raw = environ.get(ENV_PATTERNS)
    if raw and raw.strip():
        return raw
    path_text = file_arg or environ.get(ENV_FILE)
    if path_text:
        path = Path(path_text)
    else:
        home = environ.get("HOME")
        if not home:
            return None
        path = Path(home) / DEFAULT_FILE
    if not path.is_file():
        return None
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise CheckError(
            f"the denylist file could not be read ({type(exc).__name__})"
        ) from None


def load_patterns(
    environ: Mapping[str, str], file_arg: Optional[str] = None
) -> Optional[List["re.Pattern[str]"]]:
    """The compiled denylist, or None when none is configured.

    An invalid pattern raises CheckError naming its INDEX only.
    """
    raw = _read_denylist(environ, file_arg)
    if raw is None:
        return None
    lines = [line.strip() for line in raw.replace("\r\n", "\n").split("\n")]
    entries = [line for line in lines if line and not line.startswith("#")]
    if not entries:
        return None
    compiled = []
    for index, pattern in enumerate(entries, start=1):
        try:
            compiled.append(re.compile(pattern, re.IGNORECASE))
        except re.error:
            # `from None`: the re.error message quotes the pattern.
            raise CheckError(f"pattern #{index} is not a valid regular expression") from None
    return compiled


def scan_text(text: str, patterns: Sequence["re.Pattern[str]"], where: str) -> Iterator[Match]:
    """Every (where:line, pattern index) for a pattern matching a line of text."""
    for number, line in enumerate(text.splitlines(), start=1):
        for index, pattern in enumerate(patterns, start=1):
            if pattern.search(line):
                yield (f"{where}:{number}", index)


def scan_ref_name(ref: str, patterns: Sequence["re.Pattern[str]"]) -> List[Match]:
    """A ref name is public the moment it is pushed; report it by kind only."""
    if ref.startswith("refs/heads/"):
        name, label = ref[len("refs/heads/"):], "branch name"
    elif ref.startswith("refs/tags/"):
        name, label = ref[len("refs/tags/"):], "tag name"
    else:
        name, label = ref, "ref name"
    return [(label, index) for index, pattern in enumerate(patterns, start=1)
            if pattern.search(name)]


def _git(repo: Path, *args: str) -> bytes:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
    except OSError as exc:
        raise CheckError(f"git could not be run ({type(exc).__name__})") from None
    if proc.returncode != 0:
        # git's stderr can echo a ref; keep the message to the command.
        raise CheckError(f"`git {args[0]}` failed (exit {proc.returncode})")
    return proc.stdout


def scan_commit(repo: Path, sha: str, patterns: Sequence["re.Pattern[str]"]) -> List[Match]:
    """A commit's message and identity (author name, author email, committer
    name, committer email, as identity lines 1 to 4)."""
    if not _SHA_RE.match(sha):
        raise CheckError("a commit id is not a hex object name")
    short = sha[:12]
    found: List[Match] = []
    message = _git(repo, "log", "-1", "--format=%B", sha).decode("utf-8", "replace")
    found.extend(scan_text(message, patterns, f"{short}:message"))
    identity = _git(repo, "log", "-1", "--format=%an%n%ae%n%cn%n%ce", sha)
    found.extend(scan_text(identity.decode("utf-8", "replace"), patterns, f"{short}:identity"))
    return found

_HUNK_RE = re.compile(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")
_ZERO_RE = re.compile(r"^0+$")


def _git_ok(repo: Path, *args: str) -> bool:
    try:
        proc = subprocess.run(
            ["git", "-C", str(repo), *args],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )
    except OSError:
        return False
    return proc.returncode == 0


def _diff_start(repo: Path, base: str, head: str) -> str:
    """The commit (or empty tree) the range's added lines are read against. A
    BASE this clone does not have (empty, all zeros, a force-pushed-away
    commit) falls back to HEAD against its parent, or the empty tree for a root
    commit."""
    if not _SHA_RE.match(head) and head != "HEAD" and not head.startswith("refs/"):
        raise CheckError("the diff head is not a commit")
    if base and not _ZERO_RE.match(base) and _SHA_RE.match(base) \
            and _git_ok(repo, "cat-file", "-e", f"{base}^{{commit}}"):
        start = base
        merge_base = subprocess.run(
            ["git", "-C", str(repo), "merge-base", base, head],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
        )
        if merge_base.returncode == 0 and merge_base.stdout.strip():
            start = merge_base.stdout.decode().strip()
    elif _git_ok(repo, "rev-parse", "--verify", "--quiet", f"{head}^"):
        start = f"{head}^"
    else:
        start = _git(repo, "hash-object", "-t", "tree", "/dev/null").decode().strip()
    return start


# -M on purpose: a pure rename of an old file adds no lines, so it must not
# re-flag the file's existing content; a rename with edits reports only the
# edited (added) lines.
_DIFF_FLAGS = ["-c", "core.quotepath=false", "diff", "--no-color", "--no-ext-diff", "-M"]


def _diff_text(repo: Path, base: str, head: str) -> bytes:
    """`git diff -U0` of what BASE..HEAD adds."""
    return _git(repo, *_DIFF_FLAGS, "-U0", _diff_start(repo, base, head), head, "--")


def _added_paths(repo: Path, base: str, head: str) -> List[str]:
    """Paths the range adds or renames to, empty and binary files included
    (they have no added lines for the line scan to read)."""
    raw = _git(repo, *_DIFF_FLAGS, "--name-status", "-z", "--diff-filter=ACR",
               _diff_start(repo, base, head), head, "--")
    fields = raw.decode("utf-8", "replace").split("\0")
    paths: List[str] = []
    i = 0
    while i < len(fields) and fields[i]:
        width = 3 if fields[i][0] in "RC" else 2  # status, [old path,] new path
        paths.append(fields[i + width - 1] if i + width - 1 < len(fields) else "")
        i += width
    return paths


def scan_diff(repo: Path, base: str, head: str,
              patterns: Sequence["re.Pattern[str]"]) -> List[Match]:
    """Every pattern match on a line the diff adds, as (path:new line, index).

    The diff is read by its hunk headers' line counts, so an added line that
    happens to read `+++ b/x` is content, not a file header. A path that
    itself holds a denylisted term is shown as `<path withheld>`."""
    found: List[Match] = []
    # A path is public the moment it is pushed: a matching one is a finding of
    # its own, and its text is never printed.
    for added in _added_paths(repo, base, head):
        for index, pattern in enumerate(patterns, start=1):
            if pattern.search(added):
                found.append(("<path withheld>", index))
    path: Optional[str] = None
    old_left = new_left = new_no = 0
    for raw in _diff_text(repo, base, head).split(b"\n"):
        line = raw.decode("utf-8", "replace")
        if old_left > 0 or new_left > 0:
            if line.startswith("+"):
                new_left -= 1
                text = line[1:].rstrip("\r")  # CRLF files: `$` must still anchor
                for index, pattern in enumerate(patterns, start=1):
                    if pattern.search(text):
                        found.append((f"{_shown(path, patterns)}:{new_no}", index))
                new_no += 1
            elif line.startswith("-"):
                old_left -= 1
            continue
        if line.startswith("diff --git "):
            path = None
        elif line.startswith("+++ "):
            name = line[4:].split("\t", 1)[0]
            path = None if name == "/dev/null" else (name[2:] if name[:2] == "b/" else name)
        else:
            hunk = _HUNK_RE.match(line)
            if hunk:
                old_left = int(hunk.group(1)) if hunk.group(1) is not None else 1
                new_no = int(hunk.group(2))
                new_left = int(hunk.group(3)) if hunk.group(3) is not None else 1
    return found


def _shown(path: Optional[str], patterns: Sequence["re.Pattern[str]"]) -> str:
    if path is None:
        return "?"
    if any(pattern.search(path) for pattern in patterns):
        return "<path withheld>"
    return path


def scan_event(path: Path, patterns: Sequence["re.Pattern[str]"]) -> List[Match]:
    """The pull request title and body of a GitHub event payload."""
    try:
        event = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise CheckError(f"the event file could not be read ({type(exc).__name__})") from None
    pull = event.get("pull_request") if isinstance(event, dict) else None
    if not isinstance(pull, dict):
        return []
    found: List[Match] = []
    for key, where in (("title", "PR title"), ("body", "PR body")):
        text = pull.get(key)
        if isinstance(text, str):
            found.extend(scan_text(text, patterns, where))
    return found


def main(
    argv: Optional[Sequence[str]] = None,
    environ: Optional[Mapping[str, str]] = None,
    stdin: Optional[Sequence[str]] = None,
) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n", 1)[0])
    parser.add_argument("--repo", default=".", help="repository to read commits from")
    parser.add_argument("--ref", action="append", default=[], metavar="NAME",
                        help="a ref name to check (repeatable)")
    parser.add_argument("--commits-stdin", action="store_true",
                        help="read commit ids, one per line, from stdin")
    parser.add_argument("--diff", nargs=2, metavar=("BASE", "HEAD"),
                        help="scan the lines added between BASE and HEAD")
    parser.add_argument("--event-path", metavar="PATH",
                        help="a GitHub event payload; scan its PR title and body")
    parser.add_argument("--denylist-file", metavar="PATH", help="the denylist file")
    args = parser.parse_args(argv)
    environ = os.environ if environ is None else environ

    try:
        patterns = load_patterns(environ, args.denylist_file)
    except CheckError as exc:
        print(f"ERROR: privacy denylist: {exc}", file=sys.stderr)
        return EXIT_ERROR
    if patterns is None:
        return EXIT_NO_DENYLIST

    found: List[Match] = []
    try:
        for ref in args.ref:
            found.extend(scan_ref_name(ref, patterns))
        if args.event_path:
            found.extend(scan_event(Path(args.event_path), patterns))
        if args.diff:
            found.extend(scan_diff(Path(args.repo), args.diff[0], args.diff[1], patterns))
        if args.commits_stdin:
            lines = sys.stdin.read().splitlines() if stdin is None else list(stdin)
            for sha in (line.strip() for line in lines):
                if sha:
                    found.extend(scan_commit(Path(args.repo), sha, patterns))
    except CheckError as exc:
        print(f"ERROR: privacy denylist: {exc}", file=sys.stderr)
        return EXIT_ERROR

    if found:
        print(f"FAILED: {len(found)} denylisted match(es). Matched text is not shown; "
              "the pattern number counts the denylist's patterns from 1, skipping comment and blank lines.")
        for where, index in found:
            print(f"  {where}: pattern #{index}")
        return EXIT_MATCH
    print(f"OK: no denylisted terms ({len(patterns)} pattern(s)).")
    return EXIT_CLEAN


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # noqa: BLE001 - any crash must read as "could not run", never as a match
        print(f"ERROR: privacy denylist: {type(exc).__name__}", file=sys.stderr)
        sys.exit(EXIT_ERROR)
