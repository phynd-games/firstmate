import os,subprocess,json
from pathlib import Path
root=Path.cwd(); base=root/'.test-phase/base'; evidence=Path(__file__).parent
env=os.environ.copy(); env.update(TMPDIR=str(root/'.test-phase/tmp'),FM_HOME=str(root/'.test-phase/home'))
# Apply only the four disclosed fixture terminal-id corrections; production stays at base.
fixture=base/'tests/fm-backend-herdr.test.sh'
text=fixture.read_text(); old='"pane_id":"w7:p3","tab_id":"w7:t3","workspace_id":"w7"'
assert text.count(old)==4
fixture.write_text(text.replace(old,old+',"terminal_id":"term_w7p3"'))
for name in ['fm-backend-herdr','fm-pending-reply']:
  with (evidence/('baseline-'+name+'.log')).open('w') as out:
    r=subprocess.run(['bash','tests/'+name+'.test.sh'],cwd=base,env=env,stdout=out,stderr=subprocess.STDOUT)
  print(json.dumps(dict(test=name,base='5c6f9e08',exit=r.returncode)),flush=True)
  print('\n'.join((evidence/('baseline-'+name+'.log')).read_text().splitlines()[-4:]),flush=True)
