// First tests for cairn-find. Run: `node --test bin/cairn-find.test.mjs`
// Covers the matcher tokenization fix: multi-word queries return hits (was empty),
// exact-phrase still ranks top, single-word ordering is unchanged, empty query exits 2.
import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { rank } from "./cairn-find.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const BIN = path.join(HERE, "cairn-find.mjs");

test("multi-word query: a line with SOME terms now scores > 0 (was 0 = dropped)", () => {
  // "the planner subagent ledger" contains 'subagent' but NOT the contiguous
  // phrase "cairn subagent" — the OLD whole-query includes() returned 0 (RED).
  const line = "the planner subagent ledger";
  assert.equal(line.includes("cairn subagent"), false, "phrase must NOT be contiguous");
  assert.ok(rank(line, "cairn subagent") > 0, "tokenized match should now score > 0");
});

test("multi-word query: more matched terms outranks fewer", () => {
  const both = rank("cairn subagent invocation", "cairn subagent");
  const one = rank("cairn tooling note", "cairn subagent");
  assert.ok(both > one, "line with both terms should outrank line with one");
});

test("exact-phrase still ranks ABOVE any tokenized (scattered-terms) match", () => {
  const phrase = rank("call the cairn subagent now", "cairn subagent"); // contiguous phrase
  const scattered = rank("cairn helper and a subagent", "cairn subagent"); // both terms, not contiguous
  assert.ok(phrase > scattered, "contiguous phrase must outrank scattered terms");
});

test("single-word query: ordering is unchanged (exact > startsWith > substring > none)", () => {
  const exact = rank("subagent", "subagent");
  const starts = rank("subagent shell no-ops", "subagent");
  const sub = rank("the subagent shell", "subagent");
  const none = rank("unrelated line", "subagent");
  assert.ok(exact > starts && starts > sub && sub > none, "single-word tiers preserved");
  assert.equal(none, 0, "non-matching single-word line scores 0");
});

test("single-word query: a matching line is a superset (still > 0)", () => {
  assert.ok(rank("planner subagent role", "planner") > 0);
});

test("empty query exits 2 with stderr message", () => {
  const r = spawnSync(process.execPath, [BIN], { encoding: "utf8" });
  assert.equal(r.status, 2, "no-arg invocation must exit 2");
  assert.match(r.stderr, /missing query/);
});
