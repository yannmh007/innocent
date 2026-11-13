---
paths:
  - "docs/studio/**"
  - "docs/console/**"
---

# The console

- Served from `console.innocentplayer.com` (headers from
  `docs/console/build.mjs`). The GitHub Pages copy
  (`yannmh007.github.io/innocent/studio/`, CSP in a `<meta>`) was retired
  13 Nov 2026: no function or Worker answers that origin any more. A
  new host the console calls must be added to that CSP and to
  `tool/js/console_build_test.mjs`.
- **A new origin FOR the console is five places, not four**: the
  functions' `console_origins.js`, the stream Worker's `STUDIO_ORIGINS`,
  Supabase's Redirect URLs, the CSP — and the CORS policy of BOTH R2
  buckets, because uploads go from the page straight to R2 (presigned PUT).
  Why: the 6 Nov move to `console.innocentplayer.com` left the R2 policy
  out, and a week of sign-ins, reviews and previews could not show it.
  How: an upload on the new origin is the proof, not use in general.
- No inline scripts (`script-src 'self'`); relative imports only, resolving
  inside the bundle (the build test checks).
- Tests: `tool/js/console_smoke.mjs` (Chromium, every role's menu and
  route) and `console_build_test.mjs`; both run in `tool/check.py`.
- Every console write goes through the `studio` function, which checks the
  role itself; the page never holds a service key.
