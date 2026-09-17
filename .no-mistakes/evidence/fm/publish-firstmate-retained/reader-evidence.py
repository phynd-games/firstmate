import os,subprocess,urllib.request,json
from pathlib import Path
root=Path.cwd(); e=Path(__file__).parent
env=os.environ.copy(); env.update(FM_HOME=str(root/'.test-phase/reader'),FM_DOCS_READER_PYTHON=str(root/'.test-phase/home/state/docs-reader/venv/bin/python'),FM_DOCS_READER_TEST_ALLOW='1')
lines=[]
def run(*args):
    p=subprocess.run([str(root/'bin/fm-docs-reader.sh'),*args],env=env,capture_output=True,text=True)
    lines.extend(['$ bin/fm-docs-reader.sh '+' '.join(args),p.stdout,p.stderr,'exit='+str(p.returncode)])
    assert p.returncode==0, lines
    return p.stdout.strip()
first=run('ensure'); second=run('ensure'); assert first==second
url=run('url',str(root/'.test-phase/reader/data/report.md'))
run('status')
with urllib.request.urlopen(url) as response:
    body=response.read(); assert response.status==200
    (e/'reader-report.html').write_bytes(body)
    lines.append('HTTP GET '+url+' -> '+str(response.status)+'; '+str(len(body))+' bytes')
(e/'reader.url').write_text(url)
(e/'reader-ready.launch.json').write_bytes((root/'.test-phase/reader/state/.launch-docs-reader').read_bytes())
(e/'reader-cli.txt').write_text('\n'.join(lines)+'\n')
print(url)
