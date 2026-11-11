"""Check reviewed test evidence without promoting RED or approving implementation."""
from pathlib import Path
import hashlib,json,collections,sys
BASE=Path(__file__).resolve().parent

def main():
 path=Path(sys.argv[1]) if len(sys.argv)>1 else BASE/'review-fixes-r4-evidence/all.json'
 r=json.loads(path.read_text(encoding='utf-8'));inventory=json.loads((BASE/'review-case-inventory.json').read_text(encoding='utf-8'))
 ids=[x['id'] for x in r['results']];expected=[x['id'] for x in inventory]
 assert len(ids)==len(set(ids))==len(expected)==48 and set(ids)==set(expected),'case discovery/uniqueness mismatch'
 assert r['invalid']==0,'fixture/driver failure is not RED'
 for item in r['results']:
  assert item['checks'] and item['invocations']
  for c in item['checks']:assert c['pass']==(c['actual']==c['expected']),'inconsistent assertion record'
  failed=any(not c['pass'] for c in item['checks'])
  assert (item['status']=='BEHAVIOR_RED')==failed
  assert item['status'] in ('PASS','BEHAVIOR_RED')
  armed={x['point'] for x in item['faultArmedHistory']}
  assert armed==set(item['faultHitCounts']),'cancelled faults disappeared'
  for point,count in item['faultHitCounts'].items():assert count==sum(t.get('kind')=='fault' and t.get('point')==point for t in item['trace'])
 for name,digest in r['provenance']['files'].items():assert hashlib.sha256((BASE/name).read_bytes()).hexdigest()==digest,'stale evidence:'+name
 from mutation_controls import CONTROL_PLAN
 controls=r['mutationControls'];required={('TDD-'+case,mutation):positive for case,positive,mutation in CONTROL_PLAN}
 assert len(controls)==len(required) and {(x['case'],x['mutation']) for x in controls}==set(required),'missing/duplicate controls'
 baseline={x['id']:x for x in r['results']}
 for control in controls:
  assert control['positiveControl']==required[(control['case'],control['mutation'])]
  good=control['positiveEvidence'] if control['positiveControl'] else baseline[control['case']]
  bad=control['mutantEvidence']
  for evidence in (good,bad):
   assert evidence['id']==control['case'] and evidence['checks'] and evidence['invocations']
   expected_lineage=baseline[control['case']]['lineage'];assert evidence['lineage']==expected_lineage,'control evidence lineage mismatch'
   assert all(c['pass']==(c['actual']==c['expected']) for c in evidence['checks'])
   assert evidence['status']==('BEHAVIOR_RED' if any(not c['pass'] for c in evidence['checks']) else 'PASS')
  newly={c['assertion'] for c in bad['checks'] if not c['pass']}-{c['assertion'] for c in good['checks'] if not c['pass']}
  calculated=bad['status']=='BEHAVIOR_RED' and bool(newly) and good['status']=='PASS'
  assert control['positiveStatus']==good['status'] and control['mutationStatus']==bad['status']
  assert sorted(newly)==control['newlyFailedAssertions'] and control['killed']==calculated and calculated,'surviving mutant or inconsistent kill claim'
 counts=collections.Counter(item['status'] for item in r['results'])
 assert r['controlFailures']==sum(not x['killed'] for x in controls) and r['controlFixtureErrors']==0
 assert r['passed']==counts['PASS'] and r['red']==counts['BEHAVIOR_RED'] and r['invalid']==0,'inconsistent totals'
 root=BASE.parents[2]
 for row in inventory:assert hashlib.sha256((root/row['feature']).read_bytes()).hexdigest()==row['featureDigest']
 protected=json.loads((BASE/'review-fix-protected.json').read_text())
 for name,digest in protected.items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,'product/BDD changed:'+name
 screenshots={};artifact_paths=set()
 for item in r['results']:
  if item['id'].startswith('TDD-UI-'):
   p=Path(item['notes'][0]['screenshot']);assert p.exists() and p not in artifact_paths;artifact_paths.add(p);screenshots[item['id']]=hashlib.sha256(p.read_bytes()).hexdigest()
 for index,control in enumerate(controls):
  for label in ('positiveEvidence','mutantEvidence'):
   for note in control[label].get('notes',[]):
    if 'screenshot' in note:
     p=Path(note['screenshot']);assert p.exists() and p not in artifact_paths;artifact_paths.add(p);screenshots[str(index)+'/'+label]=hashlib.sha256(p.read_bytes()).hexdigest()
 summary={'date':r['date'],'executionCounts':{'passed':r['passed'],'red':r['red'],'invalid':r['invalid']},'mutationControls':len(controls),'mutantsKilled':sum(x['killed'] for x in controls),'positiveControls':sum(x['positiveControl'] is not None for x in controls),'sourceAndObservationConsistency':'PASS','screenshots':screenshots,'faultsNotReached':[{'id':x['id'],'points':x['missingFaultPaths']} for x in r['results'] if x['missingFaultPaths']],'qualification':'No blanket RED qualification. Negative safety PASS is legitimate; unhit faults remain blocked paths. Independent re-review required.','readyForImplementation':False,'independentReReview':'PENDING','verifierSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
 (path.parent/'consistency.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps({k:v for k,v in summary.items() if k not in ('screenshots','faultsNotReached')},ensure_ascii=False));return 0
if __name__=='__main__':sys.exit(main())
