#!/usr/bin/env python3
"""A repository method the app never calls.

THE BUG THIS EXISTS FOR, found on 23 Sep 2026 on a real device.

`ContentRepository.getById` is the only method that loads a title's album —
the mixed grid of stills and clips behind a card. It was declared on the
interface, implemented in BOTH repositories, tested against, discussed in
three design documents, and called by nothing at all.

So `content.items` was empty on every screen in every build ever shipped. The
detail screen drew no grid while the card beside it advertised twenty photos,
and two separate server-side faults were found and fixed before anyone
noticed that even a perfect server had no one asking.

That is the same shape as `dead_settings.py`'s bug class — something stored
and never read — one level up: something BUILT and never called. It is worth
its own check because the symptom is silence. Nothing throws, nothing logs,
the screen renders, and the only evidence is a feature that is quietly not
there.

WHAT IT CHECKS. Every method declared on a repository interface in
`lib/features/*/domain/*_repository.dart` must be referenced somewhere that
is not an interface or an implementation of it — i.e. by a provider, a
screen, or another service. Implementations alone do not count: two files
faithfully implementing a method nobody calls is exactly the state this
missed.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = os.path.join(ROOT, 'lib')

# Methods every Dart object has, or that the framework calls for us.
IGNORE = {'toString', 'noSuchMethod', 'hashCode', 'runtimeType', 'dispose'}

fails = []


def strip(src):
    """Remove comments and string bodies so a mention in prose is not a call."""
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'^\s*///?.*$', '', src, flags=re.M)
    src = re.sub(r"'''.*?'''|\"\"\".*?\"\"\"", "''", src, flags=re.S)
    src = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    return src


def _balanced(src, open_idx):
    """The text between `src[open_idx]` and its matching close brace."""
    depth = 0
    for i in range(open_idx, len(src)):
        if src[i] == '{':
            depth += 1
        elif src[i] == '}':
            depth -= 1
            if depth == 0:
                return src[open_idx + 1:i]
    return ''


def dart_files():
    for r, _d, fs in os.walk(LIB):
        for fn in fs:
            if fn.endswith('.dart'):
                yield os.path.join(r, fn)


def interfaces():
    """(path, class name, [method names]) for every abstract repository."""
    for p in dart_files():
        rel = os.path.relpath(p, ROOT).replace('\\', '/')
        if '/domain/' not in rel or not rel.endswith('_repository.dart'):
            continue
        src = strip(open(p, encoding='utf-8').read())
        m = re.search(r'abstract\s+class\s+(\w+)[^{]*\{', src)
        if not m:
            continue
        name = m.group(1)
        # BRACE-MATCHED, not greedy-to-end-of-file. The first attempt used
        # `\{(.*)\}\s*$` and swallowed every class declared BELOW the
        # interface — so `SignInCancelled` and `SignInNotConfigured`, which
        # live under AccountRepository in the same file, were reported as
        # uncalled methods of it. A constructor looks exactly like an abstract
        # method declaration once the body is gone.
        body = _balanced(src, m.end() - 1)
        # `Future<Foo> bar(` / `Foo bar(` / `Stream<X> baz(` — a declaration
        # ending in a semicolon, which is what an abstract member looks like.
        methods = re.findall(
            r'^\s*(?:[\w<>,\s\?\[\]]+?)\s+(\w+)\s*\([^;{]*\)\s*;', body, flags=re.M)
        # A name starting with a capital is a constructor or a type, never
        # a method. Belt and braces alongside the brace matching above.
        yield rel, name, [x for x in methods
                          if x not in IGNORE and not x[:1].isupper()]


def main():
    if not os.path.isdir(LIB):
        print('=== lib not present, nothing to check ===')
        return 0

    sources = {}
    for p in dart_files():
        sources[os.path.relpath(p, ROOT).replace('\\', '/')] = \
            strip(open(p, encoding='utf-8').read())

    for rel, cls, methods in interfaces():
        # Files that IMPLEMENT this interface do not count as callers.
        impls = {r for r, s in sources.items()
                 if re.search(r'implements\s+[\w\s,]*\b%s\b' % re.escape(cls), s)}
        impls.add(rel)

        for meth in methods:
            call = re.compile(r'\.\s*%s\s*\(' % re.escape(meth))
            if not any(call.search(s) for r, s in sources.items() if r not in impls):
                fails.append(
                    'UNCALLED: %s.%s is declared and implemented but nothing '
                    'outside the repository ever calls it. A feature that is '
                    'built and never invoked fails silently — see the note at '
                    'the top of tool/unread_contract.py.' % (cls, meth))

    for f in fails:
        print(' - %s' % f)
    print('=== %d uncalled contract method(s) ===' % len(fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
