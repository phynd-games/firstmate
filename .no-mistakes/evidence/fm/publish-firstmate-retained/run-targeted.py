import os, subprocess, time, json
from pathlib import Path
root=Path.cwd()
evidence=Path(__file__).parent
env=os.environ.copy()
env.update(TMPDIR=str(root/'.test-phase/tmp'),FM_HOME=str(root/'.test-phase/home'),FM_HERDR_LAB_STATE_DIR=str(root/'.test-phase/lab'))
tests=['fm-launch-record','fm-launch-spawn','fm-launch-helpers','fm-herdr-supervisor','fm-backend-herdr','fm-pending-reply','fm-docs-reader','fm-launch-control-review','fm-launch-effects-review','fm-launch-procevent-review','fm-launch-relaunch-review','fm-launch-response-review','fm-launch-supervisor-review','fm-launch-record-herdr-cleanup']
results=[]
for test in tests:
    start=time.time()
    print('START '+test,flush=True)
    with (evidence/(test+'.log')).open('w') as out:
        p=subprocess.run(['bash','tests/'+test+'.test.sh'],env=env,stdout=out,stderr=subprocess.STDOUT)
    result=dict(test=test,exit=p.returncode,seconds=round(time.time()-start,1))
    results.append(result)
    (evidence/'results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    print('\n'.join((evidence/(test+'.log')).read_text().splitlines()[-4:]),flush=True)
