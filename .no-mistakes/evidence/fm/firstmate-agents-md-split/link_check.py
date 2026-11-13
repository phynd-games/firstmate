import re,sys,pathlib
root=pathlib.Path(sys.argv[1]).resolve()
files=[root/'AGENTS.md']+sorted((root/'docs/agent-sections').glob('*.md'))
def slug(h):
    h=h.strip().lower(); h=re.sub(r'[^\w\- ]','',h); return h.replace(' ','-')
def anchors(p):
    out=set()
    for l in p.read_text().splitlines():
        m=re.match(r'^#+\s+(.*)',l)
        if m: out.add(slug(m.group(1)))
    return out
bad=0;total=0
for f in files:
    for m in re.finditer(r'\]\(([^)\s]+)\)',f.read_text()):
        t=m.group(1)
        if re.match(r'^[a-z]+:',t): continue
        total+=1
        path,_,frag=t.partition('#')
        tgt=(f.parent/path).resolve() if path else f
        if not tgt.exists(): print(f"BROKEN {f.relative_to(root)} -> {t}"); bad+=1; continue
        if frag and tgt.suffix=='.md' and frag not in anchors(tgt):
            print(f"BAD-ANCHOR {f.relative_to(root)} -> {t}"); bad+=1
print(f"checked {total} relative links in {len(files)} files; broken={bad}")
