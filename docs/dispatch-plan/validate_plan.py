"""Validate planning traceability only; not a product test or valid RED."""
import json, re, hashlib
from pathlib import Path
from build_plan import ROOT, BASE, TASKS

def main():
 index=json.loads((BASE/'plan-index.json').read_text(encoding='utf-8'))
 ids={t['id'] for t in index['tickets']}; scenarios=set(); count=0
 for t in index['tickets']:
  packet=json.loads((BASE/t['path']).read_text(encoding='utf-8'))
  assert packet['status']=='Backlog' and packet['light']=='Gray'
  assert not packet['scope']['productionAllowed']
  assert set(packet['dependsOn']) <= ids
  feature=(BASE/f"bdd/{packet['parentStory']}.feature").read_text(encoding='utf-8')
  fixture=json.loads((BASE/packet['fixtures']).read_text(encoding='utf-8'))
  assert fixture['task']==packet['id']
  for b in packet['bdd']:
   assert b['id'] not in scenarios;scenarios.add(b['id'])
   assert '@'+b['id'] in feature and b['then'] in feature
   assert b['result'] in ('NOT RUN','PASS','BEHAVIOR_RED'); count+=1
 def visit(i,stack):
  assert i not in stack,'dependency cycle'
  p=next(x for x in index['tickets'] if x['id']==i)
  for d in json.loads((BASE/p['path']).read_text(encoding='utf-8'))['dependsOn']:visit(d,stack+[i])
 for i in ids:visit(i,[])
 for mod in index['modules']:
  s=(ROOT/mod['html']).read_text(encoding='utf-8')
  spec=json.loads(re.search(r'<script type="application/json" id="module-spec">(.*?)</script>',s,re.S).group(1))
  assert spec['module']==mod['id'] and spec['status']['implementation']=='NOT STARTED'
 bindings=json.loads((BASE/'step-stubs.json').read_text(encoding='utf-8'))
 assert {b['scenario'] for b in bindings['bindings']}==scenarios
 result={'status':'PASS','layer':'planning-artifact structural consistency only','modules':len(index['modules']),'tasks':len(ids),'scenarios':count,'productTests':'NOT RUN','validRED':'See red/gate-status.json and driver-evidence/all.json' if (BASE/'red/gate-status.json').exists() else 'NOT RUN','boardImport':'NOT RUN','readyForImplementation':False}
 (BASE/'validation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':main()
