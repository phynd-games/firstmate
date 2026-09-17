import os,subprocess,json,time
from pathlib import Path
root=Path.cwd(); e=Path(__file__).parent
env=os.environ.copy(); env.update(FM_HOME=str(root/'.test-phase/home'),TMPDIR=str(root/'.test-phase/tmp'),EVIDENCE_DIR=str(e),FM_DOCS_READER_PYTHON=str(root/'.test-phase/home/state/docs-reader/venv/bin/python'),FM_HERDR_LAB_STATE_DIR=str(root/'.test-phase/lab'))
commands=[('baseline',['python3',str(e/'baseline-check.py')]),('reader-recovery',['bash','tests/fm-docs-reader.test.sh','launch-recovery']),('cli-lost-response',['bash',str(e/'cli-evidence.sh')]),('timeout-contract',['bash','tests/fm-lint.test.sh','timeout-status']),('native-launch',['bash','tests/fm-launch-record-herdr-live-e2e.test.sh']),('reader-surface',['python3',str(e/'reader-evidence.py')])]
results=[]
for name,command in commands:
  current=env.copy()
  if name=='native-launch':
    current['FM_LAUNCH_RECORD_LIVE']='1'
    current['TMPDIR']=os.environ.get('TMPDIR','/tmp')
  print('START '+name,flush=True); start=time.time()
  with (e/(name+'.txt')).open('w') as out:
    r=subprocess.run(command,env=current,stdout=out,stderr=subprocess.STDOUT)
  results.append(dict(name=name,command=command,exit=r.returncode,seconds=round(time.time()-start,1)))
  (e/'extra-results.json').write_text(json.dumps(results,indent=2)+'\n')
  print(json.dumps(results[-1]),flush=True)
  print('\n'.join((e/(name+'.txt')).read_text().splitlines()[-5:]),flush=True)
