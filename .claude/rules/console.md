---
paths:
  - "docs/studio/**"
  - "docs/console/**"
---

# The console

- Served twice until the Pages copy retires: GitHub Pages
  (`yannmh007.github.io/innocent/studio/`, CSP in a `<meta>`) and
  `console.innocentplayer.com` (headers from `docs/console/build.mjs`). A
  new host the console calls must be added to that CSP and to
  `tool/js/console_build_test.mjs`.
- No inline scripts (`script-src 'self'`); relative imports only, resolving
  inside the bundle (the build test checks).
- Tests: `tool/js/console_smoke.mjs` (Chromium, every role's menu and
  route) and `console_build_test.mjs`; both run in `tool/check.py`.
- Every console write goes through the `studio` function, which checks the
  role itself; the page never holds a service key.
