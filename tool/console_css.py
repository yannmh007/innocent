#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Two different things must not share one class name in the console page.

WHY THIS EXISTS. The operator console's top bar was three pixels tall for
weeks. Nothing was broken in the markup and nothing threw: `.bar` was
declared once as the toolbar (`height:44px`) and again, two hundred lines
later, as the track of an upload progress bar (`height:3px`). Same
specificity, later rule wins, so a 44px row of brand, tabs and email address
was rendered inside a three-pixel box and clipped. It was reported as "the UI
is not right" with a screenshot, because that is all a person can say about
it — there is no error to search for.

WHAT IS FLAGGED, and deliberately nothing more: a BARE single-class
selector — `.foo` with no second class, no pseudo, no combinator, no element
— written twice at the top level of the stylesheet. That is exactly the shape
of the bug and it has no legitimate use: two bare rules for one class are two
authors who did not know about each other.

WHAT IS NOT FLAGGED, because all of it is how CSS is meant to be written:
`.chip` then `.chip.ok` (a modifier), `.hint` then `.modal .hint` (a context),
`.lrow` then `.lrow:hover` (a state), and anything inside `@media` (the whole
point of a breakpoint is to redefine). A check that reported those would be
switched off within a week, and then it would not be there on the day it
mattered.

Grouped selectors count separately, so `.a,.b{}` declares both `a` and `b`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAGE = os.path.join(ROOT, 'docs', 'studio', 'index.html')

# The whole selector is one class and nothing else.
BARE = re.compile(r'^\.([A-Za-z][\w-]*)$')


def rules(css: str):
    """(selector_list, line) for every rule, with @media contents marked."""
    out = []
    depth = 0          # nesting depth of @-blocks we are inside
    i = 0
    line = 1
    buf = []
    while i < len(css):
        ch = css[i]
        if ch == '\n':
            line += 1
        if ch == '{':
            sel = ''.join(buf).strip()
            buf = []
            if sel.startswith('@'):
                depth += 1
            else:
                out.append((sel, line, depth))
                # Skip the declaration block wholesale; it cannot contain
                # another selector in plain CSS.
                j = css.index('}', i) if '}' in css[i:] else len(css) - 1
                line += css.count('\n', i, j)
                i = j
        elif ch == '}':
            if depth:
                depth -= 1
        else:
            buf.append(ch)
        i += 1
    return out


def collisions(css: str):
    """(name, first_line, second_line) for every bare class written twice."""
    seen = {}
    out = []
    for sel_list, line, depth in rules(css):
        if depth:
            continue        # inside @media — redefining is the whole point
        # A GROUPED rule is a shared base, not a definition of its own.
        # `.lhead,.lrow{…}` sets the column template both share, and each
        # then has a rule for what it does not. Counting the grouped rule
        # would report that ordinary, correct pattern — and a check that
        # reports correct code is a check that gets switched off.
        parts = [x for x in sel_list.split(',') if x.strip()]
        if len(parts) != 1:
            continue
        for sel in parts:
            bare = BARE.match(sel.strip())
            if not bare:
                continue
            name = bare.group(1)
            if name in seen:
                out.append((name, seen[name], line))
            else:
                seen[name] = line
    return out


# The detector proved against the collision it was written for. Without this
# a refactor could quietly stop it matching anything, and a check that finds
# nothing looks exactly like a codebase with nothing wrong in it.
HISTORICAL = """
.bar{display:flex;align-items:center;height:44px}
.brand{font-weight:650}
@media(max-width:720px){ .bar{height:auto} }
.chip{height:19px}
.chip.ok{color:green}
.hint{color:grey}
.modal .hint{font-size:11px}
.lhead,.lrow{display:grid}
.lhead{height:28px}
.lrow{cursor:pointer}
.bar{flex:0 0 90px;height:3px}
"""


def self_test() -> bool:
    found = collisions(HISTORICAL)
    names = [f[0] for f in found]
    if names != ['bar']:
        print(' - SELF TEST FAILED: expected exactly [\'bar\'], got %r. The '
              'detector no longer finds the collision it was written for.'
              % (names,))
        return False
    return True


def main() -> int:
    if not self_test():
        print('=== 1 shared class name(s) ===')
        return 1
    if not os.path.exists(PAGE):
        print('=== console page not present ===')
        return 0
    html = open(PAGE, encoding='utf-8').read()
    m = re.search(r'<style>(.*?)</style>', html, re.S)
    if not m:
        print('=== no <style> block ===')
        return 0
    css = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)

    issues = collisions(css)
    for name, first, second in issues:
        print(' - .%s is written as a bare rule twice, at line %d and line '
              '%d. Same specificity, so the later one wins every property '
              'they share — which is how the console toolbar ended up three '
              'pixels tall. Rename one of them.'
              % (name, first, second))
    print('=== %d shared class name(s) ===' % len(issues))
    return 1 if issues else 0


if __name__ == '__main__':
    sys.exit(main())
