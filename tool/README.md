# tool/

Structural checks for a project that has no local compiler.

```bash
python3 tool/check.py                     # everything
python3 tool/check.py lib/features/x      # scope the feature-local checks
```

Exit code 0 means every check passed. It does **not** mean the project
compiles — see `docs/maintenance.md` for the order that actually works:

    FlutLab Analyzer  →  tool/check.py  →  Build

These scripts read source as text. They know nothing about types.

## Adding a check

1. Write it as its own script that prints `=== N issue(s) ===` and exits
   non-zero when N > 0.
2. Add it to `CHECKS` in `check.py` with one line saying what it guards
   against.
3. **Break something on purpose and confirm it fires.** A check that has never
   failed is not evidence of anything.
4. **Run it against the whole existing tree.** If it accuses code that
   compiles, the check is wrong — narrow it before committing. Rules that cry
   wolf get switched off, and then they protect nothing.
