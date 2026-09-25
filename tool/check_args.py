# -*- coding: utf-8 -*-
import os,re,sys,sys
# The FEATURE directory to scan, not the project root. A root path here would
# compare the whole tree against itself and report every name as a collision,
# so anything that is not a lib/ path falls back to the default.
_arg = sys.argv[1] if len(sys.argv) > 1 else ''
NEW = _arg if _arg.startswith('lib/') else 'lib/features/video_hub'
def strip(s):
    s=re.sub(r'//[^\n]*','',s); return re.sub(r'/\*.*?\*/','',s,flags=re.S)
# collect ctor param names for classes declared in the feature (+ chip widgets)
params={}
targets=[NEW,'lib/features/local_browser/presentation/widgets']
for base in targets:
    for r,d,f in os.walk(base):
        for fn in f:
            if not fn.endswith('.dart'): continue
            s=strip(open(os.path.join(r,fn),encoding='utf-8').read())
            for m in re.finditer(r'\b(?:const\s+)?(_?\w+)\s*\(\s*\{(.*?)\}\s*\)',s,re.S):
                cls,block=m.group(1),m.group(2)
                # a DECLARATION block always contains `required` or `this.`
                if 'required' not in block and 'this.' not in block: continue
                # A COMMA IS APPENDED BECAUSE THE CLOSING BRACE WAS EATEN by the
                # regex above, so the LAST parameter has no delimiter after it.
                # Without this, `_Sealer({required this.iv, required int at})`
                # registered only `iv` and every call passing `at:` was reported
                # as an undeclared argument — a false positive that would have
                # been "fixed" by deleting a correct argument.
                block = block.rstrip() + ','
                names=set(re.findall(r'(?:required\s+)?(?:this\.)?(\w+)\s*[,}=]',block))
                names|=set(re.findall(r'this\.(\w+)',block))
                names|=set(re.findall(r'super\.(\w+)',block))
                params.setdefault(cls,set()).update(names)
bad=[]
for r,d,f in os.walk(NEW):
    for fn in f:
        if not fn.endswith('.dart'): continue
        p=os.path.join(r,fn); s=strip(open(p,encoding='utf-8').read())
        for m in re.finditer(r'(?<![\w.])(_?[A-Z]\w+)\s*\(',s):
            cls=m.group(1)
            if cls not in params: continue
            i=m.end()-1; depth=0; j=i
            while j<len(s):
                if s[j]=='(': depth+=1
                elif s[j]==')':
                    depth-=1
                    if depth==0: break
                j+=1
            body=s[i+1:j]
            top=[];d2=0
            for ch in body:
                if ch in '([{': d2+=1
                elif ch in ')]}': d2-=1
                top.append(ch if d2>=0 else ch)
            # named args only at depth 0
            depth2=0; cur=''; args=[]
            for ch in body:
                if ch in '([{': depth2+=1
                elif ch in ')]}': depth2-=1
                if ch==',' and depth2==0: args.append(cur); cur=''
                else: cur+=ch
            args.append(cur)
            for a in args:
                mm=re.match(r'\s*(\w+)\s*:',a)
                if mm and mm.group(1) not in params[cls] and mm.group(1)!='key':
                    bad.append('%s: %s(%s: ...) -- not a declared param (has: %s)'%(p,cls,mm.group(1),sorted(params[cls])))
print('=== %d named-arg issue(s) ==='%len(bad))
for b in bad: print(' -',b)
sys.exit(1 if bad else 0)
