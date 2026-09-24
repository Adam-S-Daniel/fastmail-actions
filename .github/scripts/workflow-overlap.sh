#!/usr/bin/env bash
#
# workflow-overlap.sh <base-ref> <head-ref>   (run inside a git repo)
#
# Answers one question: since <base-ref> and <head-ref> diverged, has
# <base-ref> changed a .github/workflows/* file that <head-ref> ALSO
# changes, while <head-ref> is still behind <base-ref>? That is the exact
# shape that leaves GITHUB_TOKEN unable to merge a Dependabot PR: GitHub
# merges a behind branch by synthesizing a 3-way merge commit, and any file
# both sides touched gets a NEW blob for that merge even when the two edits
# don't conflict textually. GITHUB_TOKEN can never hold the `workflows`
# permission, so GitHub refuses to let it write that synthesized workflow
# blob -- reporting mergeStateStatus=BLOCKED -- and `gh pr update-branch`
# hits the identical refusal, because it too asks GITHUB_TOKEN to write a
# merge commit containing that blob.
#
# This is what blocked fastmail-actions#20 daily, 2026-09-17..22: its head
# (ce8ede4) and the already-merged #21 both edited
# .github/workflows/tests.yml. It cleared only once Dependabot rebased #20
# onto main, after which the merge's workflow blobs equalled the PR head's
# and GITHUB_TOKEN could write them. See
# https://github.com/Adam-S-Daniel/fastmail-actions/issues/24.
#
# Output: the overlapping workflow paths, one per line, sorted. Empty
# (nothing printed) when there's no overlap, or when <head-ref> already
# contains <base-ref> -- a merge in that case writes no blob <head-ref>
# doesn't already have, so there's nothing to name. Exit 0 in both cases.
#
# Any git failure (an unresolvable ref, or no common ancestor at all) prints
# a message to stderr and exits 2; stdout is never written to in that case.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: workflow-overlap.sh <base-ref> <head-ref>" >&2
  exit 2
fi

base_ref="$1"
head_ref="$2"

# <head-ref> already has everything <base-ref> has -- e.g. already rebased
# or merged. A merge would synthesize no new blob for any file, workflow or
# otherwise, so there's no overlap left to warn about.
if git merge-base --is-ancestor "$base_ref" "$head_ref" 2>/dev/null; then
  exit 0
fi

if ! mb=$(git merge-base "$base_ref" "$head_ref" 2>/dev/null); then
  echo "workflow-overlap.sh: no merge base between '${base_ref}' and '${head_ref}'" >&2
  exit 2
fi

if ! base_changed=$(git diff --name-only "$mb" "$base_ref" -- .github/workflows 2>/dev/null); then
  echo "workflow-overlap.sh: could not diff '${mb}'..'${base_ref}'" >&2
  exit 2
fi

if ! head_changed=$(git diff --name-only "$mb" "$head_ref" -- .github/workflows 2>/dev/null); then
  echo "workflow-overlap.sh: could not diff '${mb}'..'${head_ref}'" >&2
  exit 2
fi

# printf '%s' (not <<<) so an empty variable produces zero bytes rather than
# a single blank line -- a here-string always appends a trailing newline,
# which would make `sort` emit one empty "line" and `comm -12` would then
# report a false match between two otherwise-empty sides.
comm -12 \
  <(printf '%s' "$base_changed" | sort) \
  <(printf '%s' "$head_changed" | sort)
