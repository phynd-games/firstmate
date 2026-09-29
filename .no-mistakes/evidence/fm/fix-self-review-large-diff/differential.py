import hashlib, os, pathlib, re, subprocess, sys
D,checker,E=map(pathlib.Path,sys.argv[1:])
report=D/'home/data/task-a/pr-self-review.md'
valid=report.read_text()
files=re.search(r'^Tests: .*?files=([^;]+)',valid,re.M)[1]
changed=re.search(r'^Changed files: (.+)',valid,re.M)[1]
env=dict(os.environ,FM_HOME=str(D/'home'))
def setfiles(value):
    binding=hashlib.sha256(f'tests|unaffected|{value}|{changed}|behavioral|retain-regression\n'.encode()).hexdigest()
    line=f'Tests: reviewed; surface=tests; scope=unaffected; files={value}; rationale=no applicable changed tests surface; binding={binding}'
    return re.sub(r'^Tests: .*',lambda _:line,valid,flags=re.M)
def replace(key,value):
    return re.sub(r'^'+re.escape(key)+r': .*',lambda _:key+': '+value,valid,flags=re.M)
entries=files.split(',')
hexes=['hex:'+x.encode().hex() for x in entries]
cases=[('valid-raw',valid),('valid-hex',setfiles(','.join(hexes))),('mixed',setfiles(','.join([hexes[0]]+entries[1:]))),('duplicates',setfiles(files+','+entries[-1])),('reordered',setfiles(','.join(reversed(entries)))),('omitted',setfiles(','.join(entries[:-1]))),('unchanged',setfiles(files+',keep/unchanged.txt'))]
for name,token in [('odd-hex','hex:abc'),('uppercase-hex','hex:AB'),('empty-hex','hex:'),('nonhex','hex:zz'),('absolute','/etc/passwd'),('dotdot','apps/../x'),('dot','apps/./x'),('empty-entry',''),('space','has space'),('comma-hex','hex:612c62'),('nul','hex:00'),('newline','hex:0a'),('tab','hex:09'),('semicolon','hex:613b62'),('colon','hex:613a62'),('backslash','hex:615c62'),('utf8','hex:c3a9')]:
    cases.append((name,setfiles(files+','+token)))
for key in ['Base SHA','Head SHA','Merge-base SHA','Changed files','Substrate base SHA','Substrate head SHA','Substrate changed files']:
    for name,value in [('zero','0'*(64 if 'files' in key else 40)),('bad','invalid')]:
        cases.append((key+'-'+name,replace(key,value)))
cases += [('missing-base-ref',replace('Base ref','missing')),('bad-task',replace('Task id','other')),('bad-version',replace('Self-review report','unknown')),('bad-repository',replace('Target repository','/missing')),('incomplete',replace('Review status','incomplete')),('dirty',replace('Tree status','dirty')),('oversize',valid+'x'*1048577)]
assert len(cases)==45,len(cases)
lines=['Original: 844e04e; optimized: 59be001; both invoked through fm-pr-self-review-check.sh using Bash 3.2.']
results={}
def run(executable):
    p=subprocess.run(['/bin/bash',str(executable),'task-a','no-mistakes'],env=env,text=True,capture_output=True,timeout=60)
    return p.returncode,p.stdout,p.stderr
for name,content in cases:
    report.write_text(content)
    before=run(D/'original/fm-pr-self-review-check.sh')
    after=run(checker)
    lines.append(f'{name}: original exit={before[0]}, optimized exit={after[0]}; output={after[1].strip() or after[2].strip()}')
    print(lines[-1],flush=True)
    results[name]=after
    assert before==after,(name,before,after)
(E/'differential-checker.txt').write_text('\n'.join(lines)+'\n')
source=pathlib.Path('bin/fm-pr-lib.sh').read_text()
mutations=[('coverage','[ -z "$uncovered" ] || return 1',': # coverage disabled','omitted'),('membership','[ -z "$extra" ]',': # membership disabled','unchanged'),('syntax','fm_pr_review_path_syntax_valid "$entry" || return 1','fm_pr_review_path_syntax_valid "$entry" || continue','odd-hex')]
m=[]
for name,old,new,case in mutations:
    md=D/name;md.mkdir()
    assert old in source
    (md/'fm-pr-lib.sh').write_text(source.replace(old,new,1))
    (md/'fm-pr-self-review-check.sh').write_text(checker.read_text())
    report.write_text(dict(cases)[case])
    r=run(md/'fm-pr-self-review-check.sh')
    m.append(f'{name} mutation, {case} input: normal exit={results[case][0]}, mutant exit={r[0]}; mutant output={r[1].strip() or r[2].strip()}')
    print(m[-1],flush=True)
    assert results[case][0]!=0 and r[0]==0
(E/'mutation-checker.txt').write_text('\n'.join(m)+'\n')
report.write_text(valid)
