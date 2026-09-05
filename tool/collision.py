# -*- coding: utf-8 -*-
"""Any top-level name declared by the NEW feature that also exists elsewhere in
the project is a latent ambiguous-import error. Catch it before a future file
imports both."""
import os,re,sys,sys
LIB='lib'; # The FEATURE directory to scan, not the project root. A root path here would
# compare the whole tree against itself and report every name as a collision,
# so anything that is not a lib/ path falls back to the default.
_arg = sys.argv[1] if len(sys.argv) > 1 else ''
NEW = _arg if _arg.startswith('lib/') else 'lib/features/video_hub'
def strip(s):
    s=re.sub(r'//[^\n]*','',s)
    s=re.sub(r'/\*.*?\*/','',s,flags=re.S)
    return s
def top_names(path):
    s=strip(open(path,encoding='utf-8').read())
    n=set(re.findall(r'^(?:abstract\s+)?(?:class|enum|mixin|extension|typedef)\s+(\w+)',s,re.M))
    n|=set(re.findall(r'^final\s+\w[\w<>,\s\.]*?\s(\w+Provider)\s*=',s,re.M))
    n|=set(re.findall(r'^final\s+(\w+)\s*=',s,re.M))
    return n
new={}
for r,d,f in os.walk(NEW):
    for fn in f:
        if fn.endswith('.dart'):
            p=os.path.join(r,fn)
            for n in top_names(p): new.setdefault(n,[]).append(p)
old={}
for r,d,f in os.walk(LIB):
    if r.startswith(NEW): continue
    for fn in f:
        if fn.endswith('.dart'):
            p=os.path.join(r,fn)
            for n in top_names(p): old.setdefault(n,[]).append(p)
bad=[]
for n,paths in sorted(new.items()):
    if n.startswith('_'): continue
    if n in old:
        bad.append('COLLISION "%s": new %s  vs existing %s'%(n,paths[0],old[n][0]))
    if len(paths)>1:
        bad.append('DUPLICATE "%s" declared twice in new feature: %s'%(n,paths))
print('=== %d collision(s) ==='%len(bad))
for b in bad: print(' -',b)
sys.exit(1 if bad else 0)
