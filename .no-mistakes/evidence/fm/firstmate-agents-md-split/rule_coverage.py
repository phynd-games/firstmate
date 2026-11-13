import sys,re,pathlib
base=pathlib.Path(sys.argv[1]).read_text().splitlines()
root=pathlib.Path(sys.argv[2])
new=[root/'AGENTS.md']+sorted((root/'docs/agent-sections').glob('*.md'))
def norm(s):
    s=s.strip()
    s=re.sub(r'^#+\s*','',s)
    s=re.sub(r'\]\((\.\./)+','](',s)  # repo-root-relative link adjustment
    s=re.sub(r'\s+',' ',s)
    return s
pool=set()
for f in new:
    for l in f.read_text().splitlines(): pool.add(norm(l))
missing=[(i+1,l) for i,l in enumerate(base) if norm(l) and norm(l) not in pool]
print(f"base non-blank lines: {sum(1 for l in base if norm(l))}")
print(f"base lines with no verbatim home in AGENTS.md + docs/agent-sections: {len(missing)}")
for n,l in missing: print(f"  base L{n}: {l[:200]}")
