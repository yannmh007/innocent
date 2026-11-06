# How Claude works on this repository, and why (6 Nov 2026)

The owner asked: spend fewer tokens, lose no quality, take what fits from a
public "model routing" setup (github.com/edotheDev/claude-model-router) and
do better where the evidence says so. This records what was checked and
what was decided. The rules themselves are in `CLAUDE.md`, the procedures
in `.claude/skills/`, the agents in `.claude/agents/`, the hooks in
`.claude/hooks/`.

## What the model-router setup does

A supervisor main session; 26 agents, each with `model:` and `effort:` in its
frontmatter (7 on Opus for judgment, 19 on Sonnet for routine); a
PreToolUse hook on the Agent tool that blocks forks, caps effort at xhigh,
counts calls per agent and description, and escalates the 2nd call to
xhigh and the 3rd to Opus; a log of every agent call.

## What the evidence says

| Claim or practice | Evidence | Verdict here |
|---|---|---|
| Every message re-reads the whole chat, so keep the main session small | True, but the re-read is billed at the cached rate (prompt caching docs; costs docs "Why usage climbs in a long session") | Long sessions do cost: one workstream per session, `/compact` at breaks |
| Delegate the bulk of the work to agents | Agents start cold: ~25k tokens before the first useful one (median of 856 spawns, measured publicly); fan-outs used 2.6–5.9x the input tokens of doing the work in sequence and were never faster (Systima, "The Subagent Tax"); Anthropic: agents ~4x, multi-agent ~15x the tokens of chat | Delegate only verbose or self-contained work; keep small edits in the main session |
| Cheaper model per agent via `model:` / `effort:` frontmatter | Official (sub-agents docs: `model`, `effort`, `tools`, `omitClaudeMd`, `maxTurns`); routing subagents to a smaller model cut a fan-out bill ~37% in one measurement | Adopted for five agents |
| Block forks: a fork copies the whole conversation | Official: a fork reuses the parent's prompt cache, so it "costs less than a fresh subagent for tasks that need the same context" | Not adopted: forks allowed when the side task needs this conversation |
| Escalate by counting calls (2nd = xhigh, 3rd = Opus) | The hook counts calls, not failures, and strips common verbs (fix, build, edit, update, make…) from descriptions, so different tasks can collide and a successful task repeated is "escalated" | Not adopted as a hook; the rule is: re-brief once, then do it in the main session. For routine sessions, the official advisor tool (Sonnet main, Opus consulted at decision points, cache kept) does the same job, decided by the model |
| Effort high as standard, cap at xhigh | Opus/Sonnet/Haiku 5.5 default to medium; on 5.5 an effort change keeps the cache (prompt caching docs) | Default effort; `/effort high` for releases, migrations, security |
| Switch models freely | Each model has its own cache: a switch re-reads everything uncached (`opusplan` switches at every plan-mode toggle) | Choose the model at session start and keep it |
| Log every agent call | Cheap, read-only | Adopted (`agent_log.py`) |

Things the post does not do that the official docs recommend and that fit
this project better:
- **Trim verbose tool output before it enters context** (costs docs:
  "Offload processing to hooks"). Here the worst offender was GitHub's
  workflow-run objects: each carries its head commit's full message and two
  avatar-laden actors. `trim_github.py` (PostToolUse) keeps the facts — a
  run went from 3,283 to ~650 characters, live, nothing lost.
- **Skills instead of a long CLAUDE.md** (costs docs: keep CLAUDE.md under
  200 lines; skills load only when used). The release, live-database and
  lab procedures were re-derived after every compaction; they are skills now.
- **CLAUDE.md carries the standing rules**, so a fresh session starts right
  and compaction summaries can be shorter.
- **Smaller tool calls** (perPage 1–3, tail_lines ≤ 80, columns not `*`).

## Decided

- Main session: Opus for this repository's production work. Quality first.
- Five agents, each with an explicit model and effort: `ci-reader` (Sonnet,
  low), `lab-reader` (Sonnet, medium), `researcher` (Sonnet, medium),
  `Explore` (Sonnet, medium; overrides the built-in, which would run on
  Opus), `reviewer` (Opus, high: a second pair of eyes before main).
  `omitClaudeMd` where the agent does not need the project rules.
- Hooks: `trim_github.py`, `agent_log.py`. Both fail open.
- Skills: `release`, `live-db-change`, `device-labs`.
- Not adopted: blanket delegation, the fork ban, call-count escalation.

## Memory across sessions (second post, 6 Nov 2026)

The same author's setup: a short CLAUDE.md (28 lines), and Claude Code's
**auto memory** — one small file per correction ("never use dashes in
captions"), indexed one line each in `MEMORY.md`, which loads at session
start; 454 such files.

What the docs say, and what it means here:
- **Auto memory is per machine** ("not shared across machines or cloud
  environments", memory docs). This project works in cloud sessions whose
  container is reclaimed: notes written to `~/.claude/projects/…/memory/`
  vanish. None existed in this session. `autoMemoryDirectory` could point
  into the checkout, but this repository is public and auto memory is not
  curated, so it is not used.
- **Path-scoped rules** (`.claude/rules/*.md` with `paths:`) load only when
  Claude reads a matching file — the cheapest place for a lesson that
  concerns one area. Verified live: reading a migration loaded
  `migrations.md`, and nothing else.
- **The index costs every session** (MEMORY.md: up to 200 lines / 25 KB);
  454 one-line entries would be past it. Rules cost nothing until needed.
- **Stale memories mislead** (the post says so too). Here
  `tool/claude_config_test.py` fails when a rule's `paths:` match nothing, a
  named file is gone, or frontmatter does not parse — it caught two skills
  whose descriptions did not parse as YAML. `/doctor prompt-audit` finds
  conflicting or outdated instructions.

Decided: corrections and lessons go into the repository, reviewed, public-
safe: CLAUDE.md (everywhere), `.claude/rules/` (by path), skills
(procedures). Claude tells the owner one line on what it saved. Five rule
files hold what this project learned the hard way (edge functions,
migrations, the app, workflows, the console); a fourth skill,
`edge-deploy`; `tool/edge_stub/` makes a local function boot reproducible
in any session (it lived only in a scratch directory before).

## How to tell whether it works

- `/usage` in a session (Pro/Max plans) shows what counts against the plan,
  with attribution to subagents, skills and MCP servers, and recommendations.
- `/context` shows what fills the window now.
- `.claude/state/agent-log.tsv` lists every delegation.

Sources: code.claude.com/docs/en/costs, /prompt-caching, /sub-agents,
/model-config, /advisor, /hooks; anthropic.com/engineering/multi-agent-research-system;
systima.ai/blog/subagent-tax; ranjankumar.in/claude-code-subagent-token-cost.
