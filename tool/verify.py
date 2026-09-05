# -*- coding: utf-8 -*-
"""Structural verifier for Innocent (FlutLab has no compiler)."""
import os, re, sys, collections

ROOT = sys.argv[1] if len(sys.argv) > 1 else '.'
LIB = os.path.join(ROOT, 'lib')
fails = []
INFO = []

def add(msg): fails.append(msg)

def dart_files():
    for r, d, f in os.walk(LIB):
        for fn in f:
            if fn.endswith('.dart'):
                yield os.path.join(r, fn)

def strip_dart(s):
    out=[]; i=0; n=len(s)
    while i<n:
        c=s[i]
        if c=='/' and i+1<n and s[i+1]=='/':
            while i<n and s[i]!='\n': i+=1
            continue
        if c=='/' and i+1<n and s[i+1]=='*':
            i+=2; depth=1
            while i<n and depth>0:
                if s[i]=='/' and i+1<n and s[i+1]=='*': depth+=1; i+=2; continue
                if s[i]=='*' and i+1<n and s[i+1]=='/': depth-=1; i+=2; continue
                i+=1
            continue
        if c=='r' and i+1<n and s[i+1] in '\'"':
            q=s[i+1]
            if s[i+1:i+4]==q*3:
                e=s.find(q*3,i+4); i=n if e==-1 else e+3
            else:
                j=i+2
                while j<n and s[j]!=q and s[j]!='\n': j+=1
                i=j+1
            out.append(' '); continue
        if c in '\'"':
            q=c
            if s[i:i+3]==q*3:
                j=i+3
                while j<n:
                    if s[j]=='\\': j+=2; continue
                    if s[j:j+3]==q*3: j+=3; break
                    j+=1
                i=j
            else:
                j=i+1
                while j<n:
                    if s[j]=='\\': j+=2; continue
                    if s[j]==q: j+=1; break
                    if s[j]=='\n': break
                    j+=1
                i=j
            out.append(' '); continue
        out.append(c); i+=1
    return ''.join(out)

# ---- 1. invisible chars ---------------------------------------------------
ZW = ['\u200b','\u2060','\ufeff','\u00a0']
ZW_BURMESE = ['\u200c','\u200d']   # legitimate in Burmese text
for p in dart_files():
    s=open(p,encoding='utf-8').read()
    bad = ZW + ([] if p.endswith('app_strings.dart') else ZW_BURMESE)
    for ch in bad:
        if ch in s:
            add('INVISIBLE U+%04X in %s (x%d)' % (ord(ch), p, s.count(ch)))

# ---- 2. balance -----------------------------------------------------------
for p in dart_files():
    s=strip_dart(open(p,encoding='utf-8').read())
    for o,c,nm in [('{','}','brace'),('(',')','paren'),('[',']','bracket')]:
        if s.count(o)!=s.count(c):
            add('BALANCE %s in %s (%d vs %d)'%(nm,p,s.count(o),s.count(c)))

# ---- 2b. MALFORMED DECLARATIONS -------------------------------------------
# THE GAP THAT LET A WHOLE BUILD THROUGH. Stripping a parameter with a regex
# turned `getFeatured({required bool x})` into `getFeatured(())`, and
# `search(String q, {required bool x})` into `search(String q, {})`. Both have
# PERFECTLY BALANCED parentheses, so the balance check waved them past, and
# Dart rejects both.
#
# Scoped to DECLARATIONS on purpose. `f(())` passes an empty record and
# `f(a, {})` passes an empty map — legal as CALLS, meaningless as parameter
# lists. A rule that cannot tell them apart would accuse working code, and a
# rule that accuses working code gets switched off.
DECL = re.compile(
    r'^[ \t]{0,6}(?:@override\s+)?'
    r'(?:static\s+|abstract\s+|external\s+)*'
    r'[\w<>,\?\[\] \t]+?\s+(\w+)\s*\(',
    re.M)

for p in dart_files():
    s=strip_dart(open(p,encoding='utf-8').read())
    for m in DECL.finditer(s):
        i = m.end() - 1              # at the opening paren
        depth = 0
        j = i
        while j < len(s):
            if s[j] == '(': depth += 1
            elif s[j] == ')':
                depth -= 1
                if depth == 0: break
            j += 1
        if j >= len(s): continue
        # Only a real declaration: the parameter list is followed by a body,
        # an arrow, an initialiser list or a semicolon.
        after = s[j+1:j+8].lstrip()
        if not (after.startswith('{') or after.startswith('=>')
                or after.startswith(';') or after.startswith(':')
                or after.startswith('async') or after.startswith('sync')):
            continue
        params = s[i+1:j].strip()
        if params == '()':
            add('SIGNATURE `%s(())` — empty parens where parameters belong, at %s:%d'
                % (m.group(1), p, s[:m.start()].count('\n') + 1))
        elif re.fullmatch(r'\{\s*\}', params) or re.search(r',\s*\{\s*\}$', params):
            add('SIGNATURE `%s(...)` has an EMPTY named-parameter list, at %s:%d'
                % (m.group(1), p, s[:m.start()].count('\n') + 1))

# ---- 2c. duplicate top-level declarations WITHIN one file -----------------
# A block pasted twice compiles nowhere and reads fine — the second copy is
# usually hundreds of lines from the first.
for p in dart_files():
    s=strip_dart(open(p,encoding='utf-8').read())
    tops = re.findall(r'^final\s+[\w<>,\s\.\?]*?\s*(\w+)\s*=', s, re.M)
    tops += re.findall(r'^(?:const|var)\s+[\w<>,\s\.\?]*?\s*(\w+)\s*=', s, re.M)
    for name, c in collections.Counter(tops).items():
        if c > 1:
            add('DUPLICATE top-level "%s" declared %d times in %s' % (name, c, p))

# ---- 3. AppStrings: getters, locale parity, duplicates --------------------
AS = os.path.join(LIB,'core/localization/app_strings.dart')
as_src = open(AS,encoding='utf-8').read()
getters = re.findall(r'String get (\w+) =>', as_src)
# AppStrings also exposes METHODS (parameterised strings): `String versionOf(Object v) =>`
methods = [m for m in re.findall(r'^\s+String (\w+)\(', as_src, re.M) if not m.startswith('_')]
gdup = [k for k,c in collections.Counter(getters).items() if c>1]
if gdup: add('APPSTRINGS duplicate getters: %s' % gdup)
getset = set(getters) | set(methods)

def map_keys(name):
    m = re.search(r"static const Map<String, String> _%s = <String, String>\{(.*?)\n  \};" % name, as_src, re.S)
    if not m: return None
    return re.findall(r"^\s*'([A-Za-z0-9_]+)':", m.group(1), re.M)

maps = {n: map_keys(n) for n in ('en','my','th')}
for n,ks in maps.items():
    if ks is None:
        add('APPSTRINGS could not parse _%s map' % n); continue
    d=[k for k,c in collections.Counter(ks).items() if c>1]
    if d: add('APPSTRINGS duplicate keys in _%s: %s'%(n,d))
if all(maps[n] is not None for n in maps):
    en=set(maps['en'])
    for n in ('my','th'):
        miss = en - set(maps[n])
        extra = set(maps[n]) - en
        if miss: add('APPSTRINGS _%s missing: %s'%(n,sorted(miss)[:8]))
        if extra: add('APPSTRINGS _%s orphan: %s'%(n,sorted(extra)[:8]))
    orphan_get = set(getters) - en - set(methods)
    if orphan_get:
        INFO.append('pre-existing getters with no en entry: %s' % sorted(orphan_get))

# ---- 4. AppStrings members actually used exist ----------------------------
for p in dart_files():
    raw=open(p,encoding='utf-8').read()
    if 'AppStrings' not in raw: continue
    s=strip_dart(raw)
    used=set(re.findall(r'AppStrings\.of\(context\)\.(\w+)', s))
    # `final s = AppStrings.of(context);` then s.foo -- ONLY when `s` has a
    # single meaning in the file. Shadowing (`final s = songs[i];`) is the
    # #1 false-positive source in this project, so an ambiguous `s` is skipped
    # entirely rather than guessed at.
    s_binds = re.findall(r'\b(?:final|late final|var)\s+(?:AppStrings\s+)?s\s*=\s*([^;\n]+)', s)
    s_binds += re.findall(r'\bfor\s*\(\s*(?:final|var)\s+s\s+in\b', s)
    # Check `s.` when EVERY binding of `s` in the file is AppStrings. The
    # earlier rule required exactly one binding, which silently skipped any
    # file where three widgets each did `final s = AppStrings.of(context);` —
    # unambiguous files, dropped from the check. Skip only on real ambiguity,
    # i.e. at least one binding that is something else (`final s = songs[i]`).
    if s_binds and all('AppStrings.of' in str(b) for b in s_binds):
        used |= set(re.findall(r'\bs\.(\w+)', s))
    for u in used:
        if u in ('of','localeName','supportedLocales','localizationsDelegates','locale'): continue
        if u not in getset:
            add('APPSTRINGS missing getter "%s" used in %s' % (u,p))

# ---- 5. token-class members exist (AppColors, and any VH-style holder) ----
# Generalised from an AppColors-only check after the Video Hub introduced its
# own token class: a typo'd token compiles nowhere and was caught by nothing.
TOKEN_CLASSES = {
    'AppColors': os.path.join(LIB,'core/theme/app_colors.dart'),
    'VH': os.path.join(LIB,'features/video_hub/presentation/video_hub_theme.dart'),
}
members = {}
for cls, path in TOKEN_CLASSES.items():
    if not os.path.exists(path):
        add('TOKENS source missing for %s: %s' % (cls, path)); continue
    src_t = open(path, encoding='utf-8').read()
    m = set(re.findall(r'static\s+(?:const|final)\s+[\w<>,\s?]*?\s(\w+)\s*=', src_t))
    m |= set(re.findall(r'static\s+(?:const|final)\s+(\w+)\s*=', src_t))
    members[cls] = m
for p in dart_files():
    s=strip_dart(open(p,encoding='utf-8').read())
    for cls, known in members.items():
        for mem in set(re.findall(r'(?<![\w.])'+cls+r'\.(\w+)', s)):
            if mem.startswith('_'): continue
            if mem not in known:
                add('TOKENS %s has no member "%s" (used in %s)'%(cls,mem,p))

# ---- 6. private symbols defined in same directory -------------------------
def defs_in(text):
    """scanner: _name( ... ) followed by { => : async sync"""
    found=set()
    for m in re.finditer(r'\b(_\w+)\s*(<[^<>()]*>)?\s*\(', text):
        name=m.group(1); i=m.end()-1
        depth=0
        while i < len(text):
            if text[i]=='(': depth+=1
            elif text[i]==')':
                depth-=1
                if depth==0: break
            i+=1
        j=i+1
        while j<len(text) and text[j] in ' \n\t': j+=1
        tail=text[j:j+6]
        if tail.startswith('{') or tail.startswith('=>') or tail.startswith(':') \
           or tail.startswith('async') or tail.startswith('sync'):
            found.add(name)
    return found

bydir=collections.defaultdict(str)
for p in dart_files():
    bydir[os.path.dirname(p)] += '\n'+strip_dart(open(p,encoding='utf-8').read())
for d,text in bydir.items():
    defined = defs_in(text) | set(re.findall(r'\b(_\w+)\s*=',text)) \
            | set(re.findall(r'\bget\s+(_\w+)',text)) \
            | set(re.findall(r'\bset\s+(_\w+)',text)) \
            | set(re.findall(r'(?:class|enum|mixin|extension|typedef)\s+(_\w+)',text)) | set(re.findall(r'\b(_\w+);',text)) \
            | set(re.findall(r'(?:final|const|late final|var)\s+[\w<>,\s?]*\s(_\w+)\b',text)) \
            | set(re.findall(r'\b(_\w+)\s*\?\?=',text))
    called = set(re.findall(r'(?<![\w.])(_\w+)\s*\(',text))
    # Tear-offs have no parentheses: `onPressed: _submit,`. The call-shaped
    # regex above cannot see them, and passing a nonexistent method as a
    # callback is a normal typo that compiles nowhere.
    called |= set(re.findall(r'[:(,?]\s*(_\w+)\s*[,)]',text))
    called |= set(re.findall(r'=>\s*(_\w+)\s*[;,)]',text))
    for c in sorted(called-defined):
        # Throwaway lambda parameters: (_, __) => ...
        if set(c) == {'_'}: continue
        add('PRIVATE symbol "%s" called but not defined in %s'%(c,d))

# ---- 7. duplicate top-level/class member declarations in one file ---------
for p in dart_files():
    s=strip_dart(open(p,encoding='utf-8').read())
    names=re.findall(r'^\s{0,2}(?:class|enum|mixin|extension)\s+(\w+)',s,re.M)
    d=[k for k,c in collections.Counter(names).items() if c>1]
    if d: add('DUPLICATE type declaration %s in %s'%(d,p))

# ---- 8. pubspec vs app_version --------------------------------------------
pub=open(os.path.join(ROOT,'pubspec.yaml'),encoding='utf-8').read()
pv=re.search(r'^version:\s*([0-9.]+)\+(\d+)',pub,re.M)
av=open(os.path.join(LIB,'core/app_version.dart'),encoding='utf-8').read()
avs=re.search(r"version\s*=\s*'([0-9.]+)'",av)
avb=re.search(r'build\w*\s*=\s*(\d+)',av)
if pv and avs and pv.group(1)!=avs.group(1):
    add('VERSION mismatch pubspec %s vs app_version %s'%(pv.group(1),avs.group(1)))
if pv and avb and pv.group(2)!=avb.group(1):
    add('VERSION build mismatch pubspec %s vs app_version %s'%(pv.group(2),avb.group(1)))

for i in INFO: print('[info]', i)
print('=== %d issue(s) ===' % len(fails))
for f in fails: print(' -', f)
sys.exit(1 if fails else 0)
