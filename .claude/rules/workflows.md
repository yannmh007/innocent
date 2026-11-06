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
- `tool/check.py` runs `workflow_yaml.py` and `security_invariants.py` over
  these files; Semgrep runs on push and fails on new findings (a JWT-shaped
  literal counts, even a fake one: build it at run time).
