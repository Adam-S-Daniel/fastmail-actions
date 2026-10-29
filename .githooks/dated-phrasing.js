#!/usr/bin/env node
/*
 * dated-phrasing.js — the agent-checks WARNING pass over the Markdown agents
 * read as instructions. It never blocks: every outcome, an internal error
 * included, exits 0 (_agent-guidance ADR 0017: deterministic checks that grow
 * out of the prompt-audit sweep warn and never block).
 *
 * Managed by _agent-guidance (templates/agent-checks/). The sync overwrites
 * this file in every fleet repo, so change it there, not here.
 *
 * Why. AGENTS.md, CLAUDE.md and SKILL.md load into every session and are read
 * as the rule that holds now. A dated story ("on 2026-08-19 X broke") or a
 * phrase relative to a migration ("is now", "no longer", "moved to") is true
 * only for the reader who knew the before; it goes stale and costs context in
 * every session. History belongs in docs/evidence/ or git; the instruction
 * file states the present-tense rule (_agent-guidance#348, ADR 0018).
 *
 * Run by .githooks/agent-checks, which installs markdown-it and passes:
 *   node dated-phrasing.js --rev <rev|index> --modules <node_modules dir>
 *   node dated-phrasing.js --count-scope
 * with the NUL-separated path list on stdin. --count-scope prints how many of
 * the paths are in scope and needs no markdown-it, so the runner installs it
 * only when there is something to read.
 *
 * Scope (by path): every AGENTS.md, CLAUDE.md and SKILL.md, except under a
 * seed/ directory inside evals/ (frozen eval fixtures), and agents-md/**
 * (*.md). So .claude/hooks/fleet-guidance.md, a byte copy of _agent-guidance's
 * agents-md/base.md, is out of scope here and checked there. In an AGENTS.md,
 * everything before the `## Repo-specific additions` heading is the managed
 * half, also checked in _agent-guidance, so it is skipped too.
 *
 * Rules, in prose only (a real markdown-it parse; fenced and indented code,
 * inline code, HTML, block quotes, URLs and link text are exempt, the last
 * because a date in link text names an evidence file):
 *   - an ISO date, YYYY-MM-DD, that is a real calendar day;
 *   - the phrases in PHRASES, case-insensitive, whole words.
 *
 * Allowlist. Text that is right as written (a present-tense fact that happens
 * to use a listed phrase, a date that qualifies a measurement) is listed in
 * dated-phrasing-allowlist.txt beside this file (the fleet's) or in the repo's
 * own .agent-checks/dated-phrasing-allowlist.txt, one entry per line:
 *   <owner/repo> <path> :: <text>
 * An entry suppresses every hit in the Markdown block (paragraph, list item,
 * heading) whose raw source contains <text>, when the repo (origin's GitHub
 * owner/name; `*` matches any) and the path match. Whitespace runs compare as
 * one space, so a reflowed paragraph keeps its entry.
 *
 * Output: one line per hit, naming the path, the line and the matched phrase
 * only (never more of the file). Under GitHub Actions a `::warning` annotation
 * on stdout; elsewhere `agent-checks (warning): ...` on stderr.
 */
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { execFileSync } = require("node:child_process");

const TITLE = "dated-phrasing";
const ANNOTATE = process.env.GITHUB_ACTIONS === "true";
const FLEET_ALLOWLIST = path.join(__dirname, "dated-phrasing-allowlist.txt");
const REPO_ALLOWLIST = ".agent-checks/dated-phrasing-allowlist.txt";
const MARKER_HEADING = "Repo-specific additions";

const DATE = /\b(?:19|20)\d\d-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b/g;
const PHRASES = [
  /\bis now\b/gi,
  /\bare now\b/gi,
  /\bno longer\b/gi,
  /\bmoved to\b/gi,
  /\b(?:was|were|been) renamed\b|\brenamed (?:to|from)\b/gi,
  /\bformerly\b/gi,
  /\bpreviously\b/gi,
  /\buntil recently\b/gi,
  /\bany ?more\b(?! than\b)/gi,
  /\bwill also\b/gi,
  /\bas of\b/gi,
  /\brecently\b/gi,
  /\bused to be\b/gi,
];
const URL = /https?:\/\/\S+/g;

function inScope(rel) {
  // Eval fixture seeds are frozen copies of other repos, not guidance.
  if (rel.startsWith("evals/") && rel.includes("/seed/")) return false;
  const base = rel.slice(rel.lastIndexOf("/") + 1);
  if (base === "AGENTS.md" || base === "CLAUDE.md" || base === "SKILL.md") return true;
  return rel.startsWith("agents-md/") && rel.endsWith(".md");
}

// ── Output ───────────────────────────────────────────────────────────────────
// GitHub's workflow-command escaping: data and property values.
function escData(s) {
  return s.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
}
function escProp(s) {
  return escData(s).replace(/:/g, "%3A").replace(/,/g, "%2C");
}

function warn(message, file, line) {
  if (ANNOTATE) {
    const props = file ? `file=${escProp(file)},line=${line},title=${TITLE}` : `title=${TITLE}`;
    process.stdout.write(`::warning ${props}::${escData(message)}\n`);
  } else {
    process.stderr.write(`agent-checks (warning): ${file ? `${file}:${line}: ` : ""}${message}\n`);
  }
}

function hitMessage(hit) {
  const what = hit.date ? `a date in prose, "${hit.text}"` : `the phrase "${hit.text}"`;
  return `dated phrasing: ${what}. Instruction files load into every session and are read as the rule that holds now, ` +
    "so history (what changed, and when) goes stale here and belongs in docs/evidence/ or git. " +
    "Reword it as the present-tense rule; if it is right as written, add a line to " +
    `${REPO_ALLOWLIST} (format: the header of .githooks/dated-phrasing-allowlist.txt). Warning only.`;
}

// ── Inputs ───────────────────────────────────────────────────────────────────
function git(args) {
  return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"], maxBuffer: 64 << 20 });
}

// The blob for rel in the content being checked, or null when it has none.
function readBlob(rev, rel) {
  try {
    return git(["cat-file", "blob", rev === "index" ? `:${rel}` : `${rev}:${rel}`]);
  } catch {
    return null;
  }
}

// origin's GitHub "owner/name", or null for any other remote.
function originRepo() {
  let url;
  try {
    url = git(["remote", "get-url", "origin"]).trim();
  } catch {
    return null;
  }
  const m = /^(?:https:\/\/github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([A-Za-z0-9._-]+)\/([A-Za-z0-9._-]+?)(?:\.git)?\/?$/.exec(url);
  return m ? `${m[1]}/${m[2]}` : null;
}

const squash = (s) => s.replace(/\s+/g, " ");

// Parses one allowlist; a malformed line is reported and ignored.
function parseAllowlist(text, label) {
  const entries = [];
  text.split("\n").forEach((raw, i) => {
    const line = raw.replace(/\r$/, "").trim();
    if (!line || line.startsWith("#")) return;
    const sep = line.indexOf(" :: ");
    const head = sep < 0 ? [] : line.slice(0, sep).trim().split(/\s+/);
    const entryText = sep < 0 ? "" : squash(line.slice(sep + 4).trim());
    if (head.length !== 2 || !entryText) {
      warn(`${label}:${i + 1}: not an allowlist entry ("<owner/repo> <path> :: <text>"); ignored.`);
      return;
    }
    entries.push({ repo: head[0].toLowerCase(), path: head[1], text: entryText });
  });
  return entries;
}

// ── The scan ─────────────────────────────────────────────────────────────────
// Every listed match in one text token, overlaps folded into the longest
// ("until recently" is one hit, not two).
function matchText(content) {
  const text = content.replace(URL, (u) => " ".repeat(u.length));
  const found = [];
  for (const m of text.matchAll(DATE)) {
    const [y, mo, d] = m[0].split("-").map(Number);
    const day = new Date(Date.UTC(y, mo - 1, d));
    if (day.getUTCMonth() === mo - 1 && day.getUTCDate() === d) {
      found.push({ start: m.index, end: m.index + m[0].length, text: m[0], date: true });
    }
  }
  for (const re of PHRASES) {
    for (const m of text.matchAll(re)) found.push({ start: m.index, end: m.index + m[0].length, text: m[0], date: false });
  }
  found.sort((a, b) => a.start - b.start || b.end - a.end);
  const kept = [];
  for (const f of found) {
    if (kept.length && f.start < kept[kept.length - 1].end) continue;
    kept.push(f);
  }
  return kept;
}

// The hits in one file's source: [{ line, text, date, block }].
function scan(md, rel, src) {
  const lines = src.split("\n");
  const tokens = md.parse(src, {});
  let managedEnd = 0;
  if (rel === "AGENTS.md" || rel.endsWith("/AGENTS.md")) {
    for (let i = 0; i + 1 < tokens.length; i++) {
      const t = tokens[i];
      if (t.type === "heading_open" && t.tag === "h2" && t.markup === "##" && t.map &&
          tokens[i + 1].content.trim() === MARKER_HEADING) {
        managedEnd = t.map[0];
        break;
      }
    }
  }
  const hits = [];
  let quote = 0;
  let lastMap = null;
  for (const t of tokens) {
    if (t.type === "blockquote_open") quote++;
    else if (t.type === "blockquote_close") quote--;
    if (t.map) lastMap = t.map;
    if (t.type !== "inline" || quote) continue;
    const map = t.map || lastMap;
    if (!map || map[0] < managedEnd) continue;
    const block = squash(lines.slice(map[0], map[1]).join("\n"));
    let line = map[0] + 1;
    let inLink = 0;
    for (const c of t.children || []) {
      if (c.type === "softbreak" || c.type === "hardbreak") line++;
      else if (c.type === "link_open") inLink++;
      else if (c.type === "link_close") inLink--;
      else if (c.type === "html_inline") line += c.content.split("\n").length - 1;
      else if (c.type === "text" && !inLink) {
        for (const m of matchText(c.content)) hits.push({ line, text: m.text, date: m.date, block });
      }
    }
  }
  return hits;
}

function main(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--count-scope") opts.countScope = true;
    else if (argv[i] === "--rev") opts.rev = argv[++i];
    else if (argv[i] === "--modules") opts.modules = argv[++i];
  }
  const paths = fs.readFileSync(0).toString("utf8").split("\0").filter((p) => p && inScope(p));
  if (opts.countScope) {
    process.stdout.write(`${paths.length}\n`);
    return;
  }
  if (!paths.length) return;
  let MarkdownIt;
  try {
    MarkdownIt = require(path.join(path.resolve(opts.modules || ""), "markdown-it"));
  } catch {
    warn("dated-phrasing skipped: markdown-it could not be loaded, so nothing was checked.");
    return;
  }
  // html: true so raw HTML parses as html_block/html_inline tokens (exempt).
  const md = new MarkdownIt({ html: true });
  const repo = originRepo();
  const rev = opts.rev || "index";
  let allow = [];
  try {
    allow = parseAllowlist(fs.readFileSync(FLEET_ALLOWLIST, "utf8"), ".githooks/dated-phrasing-allowlist.txt");
  } catch {
    warn("dated-phrasing: the fleet allowlist is missing beside the runner, so no fleet entry applies.");
  }
  const own = readBlob(rev, REPO_ALLOWLIST);
  if (own !== null) allow = allow.concat(parseAllowlist(own, REPO_ALLOWLIST));
  const repoKey = repo ? repo.toLowerCase() : null;
  for (const rel of [...new Set(paths)]) {
    const src = readBlob(rev, rel);
    if (src === null) continue;
    const entries = allow.filter((e) => e.path === rel && (e.repo === "*" || e.repo === repoKey));
    for (const hit of scan(md, rel, src)) {
      if (entries.some((e) => hit.block.includes(e.text))) continue;
      warn(hitMessage(hit), rel, hit.line);
    }
  }
}

try {
  main(process.argv.slice(2));
} catch (err) {
  try {
    warn(`dated-phrasing stopped on an internal error (${err && err.name ? err.name : "error"}); its findings are incomplete.`);
  } catch {
    // Nothing left to report with.
  }
}
process.exitCode = 0;
