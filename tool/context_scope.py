"""`context` used where the enclosing class does not have one.

WHY THIS EXISTS — added 27 Aug 2026, after it broke a release build.

A `State` subclass inherits a `context` field. A `StatelessWidget` or
`ConsumerWidget` does NOT: the only BuildContext inside its methods is one that
was passed in. Four lines were added that read `AppStrings.of(context)` inside
`VideoOptionMenu` — a ConsumerWidget whose methods take `sheetContext` — and
ALL SIX existing checkers passed. `compile_risk.py` only asks whether a known
project TYPE is imported, and `context` is neither a type nor an import.

The trap is that the same file also contains `build(BuildContext context)` and
dozens of legitimate `context` uses inside builder closures, so the mistake
reads as normal at a glance and only the compiler objects.

TWO EARLIER VERSIONS WERE THROWN AWAY, useless in opposite directions:

  1. Scanning per FILE rather than per CLASS. A file holds both a Widget and
     its State, so State methods were scanned too — nine accusations against
     working code. A checker that accuses working code gets switched off.
  2. Skipping any method whose parameters mention `BuildContext`. The bug is
     precisely a method that takes `sheetContext` and writes `context`, so the
     one case worth catching was the one excluded. The parameter has to be
     named exactly `context`.

Two more traps the working version has to handle:

  * `AppStrings.of(context)` contains the literal text `(context)`, so a naive
    "is a closure parameter present" pattern matches the very line it is meant
    to accuse. A closure parameter is followed by `=>`, `{` or `async`.
  * A signature can span lines. A method declared with its parameters on the
    following line was skipped entirely until signatures were joined.

Verified BOTH directions before shipping: silent on the whole tree, and it
names the exact line when the bug is re-injected.
"""
import os
import re
import sys

CLASS_HEAD = re.compile(
    r'^class\s+(\w+)\s+extends\s+([\w<>, ]+?)\s*(?:\{|with|implements)')
SIG_START = re.compile(
    r'^  (?:static\s+)?(?:Future<[^>]*>|void|bool|String|int|double|Widget)'
    r'\s+(\w+)\(')
# A CLOSURE parameter list: `(context) =>`, `(context) {`, `(context, x) {`,
# `builder: (context`. Deliberately NOT a plain call argument such as
# `AppStrings.of(context)` — matching that was what made version 2 silent.
CLOSURE_CTX = re.compile(
    r'\(\s*context\s*(?:,[^)]*)?\)\s*(?:=>|\{|async)|builder:\s*\(\s*context')
USES_CONTEXT = re.compile(r'\bof\(context\)|(?<![\w.])context\.')
HAS_CONTEXT_PARAM = re.compile(r'\bBuildContext\s+context\b')


def collect_sig(lines, i):
    """Join a signature that may span lines. Returns (params, last_line_idx)."""
    buf = lines[i]
    j = i
    while buf.count('(') > buf.count(')') and j + 1 < len(lines):
        j += 1
        buf += ' ' + lines[j]
    m = re.search(r'\((.*)\)', buf)
    return (m.group(1) if m else ''), j


def scan(root):
    hits = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(root, 'lib')):
        for name in filenames:
            if not name.endswith('.dart'):
                continue
            path = os.path.join(dirpath, name)
            lines = open(path, encoding='utf-8').read().split('\n')

            blocks = []
            for i, line in enumerate(lines):
                m = CLASS_HEAD.match(line)
                if not m:
                    continue
                j = i + 1
                while j < len(lines) and lines[j] != '}':
                    j += 1
                blocks.append((m.group(2), i, j))

            for base, start, end in blocks:
                b = base.rstrip()
                # A State subclass HAS an inherited `context`; a Widget has not.
                if 'State<' in b or b.endswith('State'):
                    continue
                if not b.endswith('Widget'):
                    continue
                i = start
                while i < end:
                    if not SIG_START.match(lines[i]):
                        i += 1
                        continue
                    params, sig_end = collect_sig(lines, i)
                    j = sig_end + 1
                    if HAS_CONTEXT_PARAM.search(params):
                        i = j
                        continue
                    while j < end and lines[j] != '  }':
                        line = lines[j]
                        if USES_CONTEXT.search(line) and not CLOSURE_CTX.search(line):
                            k = j - 1
                            shadowed = False
                            while k > sig_end:
                                if CLOSURE_CTX.search(lines[k]):
                                    shadowed = True
                                    break
                                k -= 1
                            if not shadowed:
                                rel = path.split('/lib/')[-1]
                                hits.append((rel, j + 1, line.strip()[:64]))
                        j += 1
                    i = j + 1
    return hits


if __name__ == '__main__':
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    issues = scan(root)
    for rel, line, text in issues:
        print(f' - CONTEXT {rel}:{line} uses `context`, but the enclosing '
              f'class has none — pass the BuildContext in')
        print(f'     {text}')
    print(f'=== {len(issues)} context issue(s) ===')
    sys.exit(1 if issues else 0)
