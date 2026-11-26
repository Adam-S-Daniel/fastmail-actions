#!/usr/bin/env python3
"""privacy-comment-scan.py - say whether an issue or comment holds a denylisted term.

The privacy-comment-alert workflow runs this on an issue or comment event. It
reads the event payload from $GITHUB_EVENT_PATH, scans the text the event
carries against the denylist, and prints exactly ONE word:

  skipped       the text's author is not trusted (see below); nothing was scanned
  match         a pattern matched the text
  clean         nothing matched
  no-denylist   PRIVACY_DENYLIST is unset or holds no pattern (a new repo)
  error         the scan could not run (the reason goes to stderr as a class
                name only, never text from the payload or a pattern)

Nothing else reaches stdout: not the text, not the pattern, not its number, not
even a count. The workflow's log is public on a public repo, so the answer has
to be as small as the log can safely hold. The exit status is 0 for all four
words; the workflow reads the word.

Only text written by a TRUSTED author is scanned: the author_association on the
event's comment, issue or review is OWNER, MEMBER or COLLABORATOR, or its user
is a Bot. On a public repo anyone can open an issue, and a log that said
"match" or "clean" for their text would let them test guesses against the
denylist. The threat this covers is the owner's own agents posting a term; an
outsider can post anything anyway. The workflow also keeps its log and step
graph identical for match and clean, so the word is never visible to anyone.

What is scanned, by event (GITHUB_EVENT_NAME):

  issues                       issue.title and issue.body
  issue_comment                comment.body (not issue.body: the issue was
                               scanned when it was opened or edited)
  pull_request_review_comment  comment.body
  pull_request_review          review.body

Patterns come from the PRIVACY_DENYLIST environment variable, in the format
and with the case-insensitive rule of privacy-denylist.py. That script's own
load_patterns is used when it sits beside this file (the sync delivers both to
.githooks/) or in the template layout; the fallback below is the same format
for a repo that lacks it.
"""

import importlib.util
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # the shared loader must not leave a __pycache__ in .githooks/

FIELDS = {
    "issues": (("issue", "title"), ("issue", "body")),
    "issue_comment": (("comment", "body"),),
    "pull_request_review_comment": (("comment", "body"),),
    "pull_request_review": (("review", "body"),),
}

_HERE = Path(__file__).resolve().parent
_SHARED = (
    _HERE / "privacy-denylist.py",
    _HERE.parent / "agent-checks" / "privacy-denylist.py",
)


def _fallback_load_patterns(environ):
    """privacy-denylist.py's env-variable format, for when it is not beside us."""
    raw = environ.get("PRIVACY_DENYLIST")
    if not raw or not raw.strip():
        return None
    lines = [line.strip() for line in raw.replace("\r\n", "\n").split("\n")]
    entries = [line for line in lines if line and not line.startswith("#")]
    if not entries:
        return None
    # re.error quotes the pattern; the caller reports the class name only.
    return [re.compile(entry, re.IGNORECASE) for entry in entries]


def _load_patterns(environ):
    for path in _SHARED:
        if not path.is_file():
            continue
        spec = importlib.util.spec_from_file_location("privacy_denylist", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # Only the environment variable: no file lookup on a CI runner.
        return module.load_patterns(
            {"PRIVACY_DENYLIST": environ.get("PRIVACY_DENYLIST", "")}
        )
    return _fallback_load_patterns(environ)


TRUSTED_ASSOCIATIONS = ("OWNER", "MEMBER", "COLLABORATOR")
AUTHOR_NODE = {
    "issues": "issue",
    "issue_comment": "comment",
    "pull_request_review_comment": "comment",
    "pull_request_review": "review",
}


def _trusted(event_name, event):
    """True when the text's author is the owner's side: a member-ish
    association, or a Bot account. A missing field is not trusted."""
    node = event.get(AUTHOR_NODE.get(event_name, ""))
    if not isinstance(node, dict):
        return False
    if node.get("author_association") in TRUSTED_ASSOCIATIONS:
        return True
    user = node.get("user")
    return isinstance(user, dict) and user.get("type") == "Bot"


def _texts(event_name, event):
    paths = FIELDS.get(event_name)
    if paths is None:
        raise ValueError("unsupported event")
    for first, second in paths:
        node = event.get(first)
        value = node.get(second) if isinstance(node, dict) else None
        if isinstance(value, str):
            yield value


def scan(environ):
    """The one word to print."""
    patterns = _load_patterns(environ)
    if patterns is None:
        return "no-denylist"
    path = environ.get("GITHUB_EVENT_PATH")
    if not path:
        raise ValueError("no event path")
    with open(path, encoding="utf-8") as handle:
        event = json.load(handle)
    event_name = environ.get("GITHUB_EVENT_NAME", "")
    texts = list(_texts(event_name, event))  # an unsupported event is an error
    if not _trusted(event_name, event):
        return "skipped"
    for text in texts:
        # Line by line, like privacy-denylist.py, so `^term$` means the same here.
        for line in text.splitlines():
            line = line.rstrip("\r")
            if any(pattern.search(line) for pattern in patterns):
                return "match"
    return "clean"


def main():
    try:
        word = scan(os.environ)
    except Exception as exc:  # noqa: BLE001 - every failure reads as "error", never as a match
        print(f"privacy-comment-scan: {type(exc).__name__}", file=sys.stderr)
        word = "error"
    print(word)
    return 0


if __name__ == "__main__":
    sys.exit(main())
