#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Every `implements X` really implements X, with the same shapes.

THE GAP THIS CLOSES. A build failed with errors nothing here could see:
`RowFacetsArg(widget.rowKey)` when the constructor took two positional
arguments, and `repo.search(query)` when the signature had lost its positional
parameter. Both are the same underlying fault - a DECLARATION and its USES
drifting apart - and both are invisible to a checker that only reads one file
at a time.

Three rules, all cross-file:

  1. a class that `implements` a project interface declares every member of it
  2. each of those members has the same positional count and the same set of
     named parameters as the interface declares
  3. a constructor call to a project class passes an argument count the
     constructor can actually accept

Still not a type checker. It compares SHAPES, not types: it will not notice a
String passed where an int belongs. That is what the analyzer is for, and it
is why `tool/check.py` tells you to run the analyzer too.
"""
import os
import re
import sys
import collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else '.'
LIB = os.path.join(ROOT, 'lib')
fails = []


def strip(text):
    """Remove comments; replace each string literal with a placeholder token.

    A placeholder rather than whitespace, because this checker COUNTS
    ARGUMENTS. Blanking `f('a', 'b')` to `f( ,  )` loses the very thing being
    measured, and the first version of this file reported five false positives
    for exactly that reason.
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '*':
            i += 2
            depth = 1
            while i < n and depth:
                if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
                    depth += 1
                    i += 2
                    continue
                if text[i] == '*' and i + 1 < n and text[i + 1] == '/':
                    depth -= 1
                    i += 2
                    continue
                i += 1
            continue
        if c in '\'"':
            q = c
            if text[i:i + 3] == q * 3:
                j = i + 3
                while j < n:
                    if text[j] == '\\':
                        j += 2
                        continue
                    if text[j:j + 3] == q * 3:
                        j += 3
                        break
                    j += 1
                i = j
            else:
                j = i + 1
                while j < n:
                    if text[j] == '\\':
                        j += 2
                        continue
                    if text[j] == q:
                        j += 1
                        break
                    if text[j] == '\n':
                        break
                    j += 1
                i = j
            out.append('_STR_')
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def dart_files():
    for r, d, f in os.walk(LIB):
        for fn in f:
            if fn.endswith('.dart'):
                yield os.path.join(r, fn)


def balanced(text, start):
    """Index of the ')' matching the '(' at `start`, or -1."""
    depth = 0
    i = start
    while i < len(text):
        if text[i] == '(':
            depth += 1
        elif text[i] == ')':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def split_top(params):
    """Split a parameter list on top-level commas only."""
    parts = []
    depth = 0
    cur = ''
    for ch in params:
        if ch in '([{<':
            depth += 1
        elif ch in ')]}>':
            depth -= 1
        if ch == ',' and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    parts.append(cur)
    # A trailing comma produces one empty tail; every OTHER empty is a real
    # position whose content the stripper blanked (a string literal).
    if parts and not parts[-1].strip():
        parts.pop()
    return [p.strip() for p in parts]


def shape(params):
    """(required positional, max positional, named names) for a declaration.

    Optional positionals `[a, b]` are counted SEPARATELY: a call may pass
    anywhere from required to max, and collapsing that into one number made a
    legal call look like an overflow.
    """
    named = set()
    brace = params.find('{')
    bracket = params.find('[')
    head = params
    optional = 0
    if brace >= 0:
        head = params[:brace]
        end = params.rfind('}')
        tail = params[brace + 1:end] if end > brace else ''
        for p in split_top(tail):
            m = re.search(r'(\w+)\s*(?:=|$)', p.replace('required', ' '))
            if m:
                named.add(m.group(1))
    elif bracket >= 0:
        head = params[:bracket]
        end = params.rfind(']')
        opt = params[bracket + 1:end] if end > bracket else ''
        optional = len([p for p in split_top(opt) if p])
    required = len([p for p in split_top(head) if p])
    return required, required + optional, named


# ---- collect declarations --------------------------------------------------
# interface name -> {member: (positional, named)}
interfaces = {}
# class name -> (positional, named, file) for its unnamed constructor
constructors = {}
# class name -> list of interfaces it claims
implementers = collections.defaultdict(list)
# class name -> {member: (positional, named)}
class_members = collections.defaultdict(dict)
class_file = {}

CLASS = re.compile(
    r'\b(?:abstract\s+)?class\s+(\w+)[^{]*?\{', re.S)
# The return-type group MUST begin with a real character, not a space.
#
# CHECKER BUG, found 25 Aug 2026 by a negative test that refused to fire.
# The class was `[\w<>,\?\[\] \t]+?`, which happily matched a run of pure
# whitespace — so the CONTINUATION LINE of an expression body,
#
#     Future<String?> resolveImageUrl(MediaRef ref) async =>
#         resolveImageUrlSync(ref);
#
# read as a declaration of `resolveImageUrlSync` with a blank return type. Any
# adapter that DELEGATES to a member therefore appeared to declare it, and the
# `implements` completeness check — the whole reason this file exists — was
# silently satisfied by the call site. Anchoring the group on a non-space first
# character costs nothing and closes it.
MEMBER = re.compile(
    r'^[ \t]{2,4}(?:@override\s+)?(?:static\s+|external\s+)?'
    r'([\w<>,\?\[\]][\w<>,\?\[\] \t]*?)\s+(\w+)\s*\(', re.M)

for path in dart_files():
    src = strip(open(path, encoding='utf-8').read())
    for m in CLASS.finditer(src):
        name = m.group(1)
        header = src[m.start():m.end()]
        class_file[name] = path
        for kw in ('implements', 'extends'):
            hm = re.search(kw + r'\s+([\w,\s<>]+?)(?:\s+(?:with|implements|extends)\b|\{)', header)
            if hm:
                for t in hm.group(1).split(','):
                    t = t.split('<')[0].strip()
                    if t:
                        implementers[name].append(t)
        # body span
        depth = 0
        i = m.end() - 1
        while i < len(src):
            if src[i] == '{':
                depth += 1
            elif src[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = src[m.end():i]
        for mm in MEMBER.finditer(body):
            ret, member = mm.group(1).strip(), mm.group(2)
            if member in ('if', 'for', 'while', 'switch', 'return', 'catch'):
                continue
            close = balanced(body, mm.end() - 1)
            if close < 0:
                continue
            req, mx, nm = shape(body[mm.end():close])
            class_members[name][member] = (req, mx, nm)
        # unnamed constructor
        cm = re.search(r'(?:const\s+)?' + re.escape(name) + r'\s*\(', body)
        if cm:
            close = balanced(body, cm.end() - 1)
            if close > 0:
                req, mx, nm = shape(body[cm.end():close])
                constructors[name] = (req, mx, nm, path)

# an "interface" is any class other classes implement
for cls, bases in implementers.items():
    for b in bases:
        if b in class_members:
            interfaces[b] = class_members[b]

# ---- 1 + 2. implementations match their interface -------------------------
for cls, bases in implementers.items():
    for base in bases:
        if base not in interfaces:
            continue
        for member, (pos, _mx, named) in interfaces[base].items():
            if member not in class_members.get(cls, {}):
                fails.append(
                    'CONFORMANCE %s implements %s but does not declare "%s" (%s)'
                    % (cls, base, member,
                       os.path.relpath(class_file.get(cls, '?'), ROOT)))
                continue
            ipos, _imx, inamed = class_members[cls][member]
            if ipos != pos:
                fails.append(
                    'CONFORMANCE %s.%s takes %d positional, %s declares %d (%s)'
                    % (cls, member, ipos, base, pos,
                       os.path.relpath(class_file.get(cls, '?'), ROOT)))
            missing = named - inamed
            extra = inamed - named
            if missing:
                fails.append(
                    'CONFORMANCE %s.%s is missing named %s required by %s (%s)'
                    % (cls, member, sorted(missing), base,
                       os.path.relpath(class_file.get(cls, '?'), ROOT)))
            if extra:
                fails.append(
                    'CONFORMANCE %s.%s declares named %s that %s does not (%s)'
                    % (cls, member, sorted(extra), base,
                       os.path.relpath(class_file.get(cls, '?'), ROOT)))

# ---- 3. constructor call arity --------------------------------------------
# Only for classes whose constructor takes ONLY positional parameters: a
# mixed list makes counting at the call site ambiguous, and a wrong answer
# here would be worse than no answer.
for path in dart_files():
    src = strip(open(path, encoding='utf-8').read())
    for name, (req, mx, named, decl_file) in constructors.items():
        if named or req == 0:
            continue
        for m in re.finditer(r'(?<![\w.])' + re.escape(name) + r'\s*\(', src):
            # skip the declaration itself
            if os.path.abspath(path) == os.path.abspath(decl_file):
                line_start = src.rfind('\n', 0, m.start()) + 1
                if re.match(r'\s*(?:const\s+)?' + re.escape(name) + r'\s*\(',
                            src[line_start:m.end()]):
                    continue
            close = balanced(src, m.end() - 1)
            if close < 0:
                continue
            args = split_top(src[m.end():close])
            if any('=' in a and ':' not in a.split('=')[0] for a in args):
                continue
            if any(':' in a for a in args):
                continue          # named args present: not this rule's job
            if args and not (req <= len(args) <= mx):
                fails.append(
                    'ARITY %s(...) called with %d positional argument(s); the '
                    'constructor accepts %d%s, at %s:%d'
                    % (name, len(args), req,
                       '' if mx == req else '-%d' % mx,
                       os.path.relpath(path, ROOT),
                       src[:m.start()].count('\n') + 1))

print('=== %d conformance issue(s) ===' % len(fails))
for f in fails:
    print(' -', f)
sys.exit(1 if fails else 0)
