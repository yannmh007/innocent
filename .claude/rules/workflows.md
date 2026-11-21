---
paths:
  - ".github/workflows/**"
  - "tool/*.sh"
  - "test_device/run.sh"
---

# GitHub Actions

- Actions pinned by full SHA with a `# vN` comment; checkout with
  `persist-credentials: false`; `permissions:` as small as the job needs.
- **Nothing secret in a log**: presigned URLs and DEKs stay in variables or
  files, never echoed; `::add-mask::` values a log must mention.
- **On main**, build.yml runs for anything outside `docs/**`,
  `tool/transcode.sh`, `CLAUDE.md` and `.claude/**`, and a new push CANCELS
  the running build (concurrency `cancel-in-progress`). Never push to main
  while a release build runs.
- **Schedules run main's copy** of a workflow; a branch change to a
  scheduled workflow takes effect only when it reaches main.
- **A check meant to alert runs on a schedule on main.** GitHub e-mails
  the owner when a scheduled run fails; a dispatch-only check alerts
  nobody. transport-check is the outage alarm (every 6 h, since 7 Nov);
  playback-check is dispatch-only.
- **Schedules run hours late.** ingest's `*/5` fired at 18:18, 23:17 and
  02:55 (7 Nov): GitHub throttles busy schedules. Anything that must happen
  soon is started by dispatch (as ingest and transcode are); a schedule is
  for daily work and alarms only. To prove a house step now, dispatch the
  workflow on main by hand.
- **A job that should follow another is started by it**, on main only:
  Transcode dispatches Trick-play when its run recorded a rung (21 Nov
  2026, the owner's word; the daily schedule stays as the net). A branch
  run is a test and dispatches nothing.
- **Renewing an action's pin** (21 Nov 2026, Node 20 deprecated):
  `git ls-remote --tags https://github.com/<owner>/<action>` gives each
  tag's commit (a `^{}` line is an annotated tag's commit: pin that); fetch
  that SHA into a bare repo (`git fetch --depth 1 <url> <sha>`) and read
  its `action.yml` — `runs.using` (node24) and `inputs`, against every
  `with:` key this repository passes. Then the branch Build, the device lab
  and Test Lab on the new pins before a release.
- `tool/check.py` runs `workflow_yaml.py` and `security_invariants.py` over
  these files; Semgrep runs on push and fails on new findings (a JWT-shaped
  literal counts, even a fake one: build it at run time).
- **Reading a step in the middle of a long job log:** `get_job_logs` with
  `return_content: false` gives a blob URL the sandbox cannot fetch (proxy
  403, 20 Nov), and `tail_lines` only reaches the last steps. Print what a
  step proves into `$GITHUB_STEP_SUMMARY` as well, or hand the run to
  `ci-reader`; do not pull 150+ lines hoping to reach it.
