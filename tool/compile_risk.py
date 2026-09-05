# -*- coding: utf-8 -*-
"""Every PROJECT type a file names must be reachable from that file's imports.
This is the check that catches the v0.97.2 class of failure ("Type 'Video' not
found") which balance/symbol checks are blind to."""
import os, re, sys, collections

ROOT = sys.argv[1] if len(sys.argv)>1 else '.'
LIB = os.path.join(ROOT,'lib')
ONLY = sys.argv[2] if len(sys.argv)>2 else None   # optional path filter
fails=[]

def strip_dart(s):
    out=[];i=0;n=len(s)
    while i<n:
        c=s[i]
        if c=='/' and i+1<n and s[i+1]=='/':
            while i<n and s[i]!='\n': i+=1
            continue
        if c=='/' and i+1<n and s[i+1]=='*':
            i+=2;d=1
            while i<n and d>0:
                if s[i]=='/' and i+1<n and s[i+1]=='*': d+=1;i+=2;continue
                if s[i]=='*' and i+1<n and s[i+1]=='/': d-=1;i+=2;continue
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
            out.append(' ');continue
        if c in '\'"':
            q=c
            if s[i:i+3]==q*3:
                j=i+3
                while j<n:
                    if s[j]=='\\': j+=2;continue
                    if s[j:j+3]==q*3: j+=3;break
                    j+=1
                i=j
            else:
                j=i+1
                while j<n:
                    if s[j]=='\\': j+=2;continue
                    if s[j]==q: j+=1;break
                    if s[j]=='\n': break
                    j+=1
                i=j
            out.append(' ');continue
        out.append(c);i+=1
    return ''.join(out)

files=[]
for r,d,f in os.walk(LIB):
    for fn in f:
        if fn.endswith('.dart'): files.append(os.path.join(r,fn))

# --- where each project type is declared ---------------------------------
decl={}
for p in files:
    s=strip_dart(open(p,encoding='utf-8').read())
    for m in re.finditer(r'\b(?:abstract\s+)?(?:class|enum|mixin|extension)\s+(\w+)',s):
        decl.setdefault(m.group(1),set()).add(os.path.abspath(p))
    for m in re.finditer(r'\btypedef\s+(\w+)',s):
        decl.setdefault(m.group(1),set()).add(os.path.abspath(p))
    # Top-level providers are not TYPES, so the type scan missed them entirely
    # — and a forgotten provider import is among the most common Riverpod
    # errors there is. Tracked as symbols in their own right.
    for m in re.finditer(r'^final\s+[\w<>,\s\.\?]*?\s*(\w+Provider)\s*=',s,re.M):
        decl.setdefault(m.group(1),set()).add(os.path.abspath(p))

# --- part/parent map: a part file inherits the parent's imports -----------
part_of={}
for p in files:
    raw=open(p,encoding='utf-8').read()
    m=re.search(r"^part of ['\"]([^'\"]+)['\"];",raw,re.M)
    if m:
        part_of[os.path.abspath(p)]=os.path.abspath(os.path.join(os.path.dirname(p),m.group(1)))

def imports_of(p):
    """abs paths this file can see (own imports + parts it declares)."""
    raw=open(p,encoding='utf-8').read()      # RAW: stripping kills import URIs
    seen={os.path.abspath(p)}
    for m in re.finditer(r"^\s*(?:import|part)\s+['\"]([^'\"]+)['\"]",raw,re.M):
        u=m.group(1)
        if u.startswith('package:mx_clone/'):
            seen.add(os.path.abspath(os.path.join(LIB,u[len('package:mx_clone/'):])))
        elif not u.startswith(('dart:','package:')):
            seen.add(os.path.abspath(os.path.join(os.path.dirname(p),u)))
    return seen

for p in files:
    ap=os.path.abspath(p)
    if ONLY and ONLY not in p: continue
    visible=imports_of(p)
    # Importing a LIBRARY also brings in every type declared in its `part`
    # files -- player_state.dart is a part of player_provider.dart, so a file
    # that imports the provider can name PlayerState without importing it.
    for lib_file in list(visible):
        for child,par in part_of.items():
            if par==lib_file: visible.add(child)
    parent=part_of.get(ap)
    if parent and os.path.exists(parent):
        visible |= imports_of(parent)
        # siblings of the same library
        for q in files:
            if part_of.get(os.path.abspath(q))==parent: visible.add(os.path.abspath(q))
    s=strip_dart(open(p,encoding='utf-8').read())
    used=set(re.findall(r'(?<![\w.])([A-Z]\w+)',s))
    # ONLY where a provider is actually consumed. A bare `\w+Provider` token
    # also matches constructor parameters and fields named after a provider
    # (SortViewDialog takes one called `preferencesProvider`), which produced
    # two false positives against code that has always compiled.
    used|=set(re.findall(r'ref\.\w+\(\s*(\w+Provider)\b',s))
    for t in sorted(used):
        if t not in decl: continue          # SDK/Flutter/package type -> not ours
        if decl[t] & visible: continue
        fails.append('%s: uses project type "%s" (declared in %s) but does not import it'
                     % (p,t,sorted(os.path.relpath(x,ROOT) for x in decl[t])[:2]))

print('=== %d import issue(s) ===' % len(fails))
for f in fails: print(' -',f)
sys.exit(1 if fails else 0)
