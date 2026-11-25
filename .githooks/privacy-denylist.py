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
                      [--denylist-file PATH]

  --ref NAME        a ref name to check (refs/heads/ and refs/tags/ prefixes
                    are dropped first); repeatable
  --commits-stdin   read commit ids, one per line, from standard input and
                    check each one's message and identity

Output, on a match (stdout):
  FAILED: <n> denylisted match(es). ...
    branch name: pattern #N
    <sha12>:message:<line>: pattern #N
    <sha12>:identity:<line>: pattern #N      (1 author name, 2 author email,
                                              3 committer name, 4 committer email)

Exit status: 0 clean; 1 a match; 2 the check could not run (an unreadable file,
an invalid pattern, git failing); 3 no denylist is configured, so nothing was
checked (the caller decides what that means; locally it is not a failure).
"""

import argparse
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
