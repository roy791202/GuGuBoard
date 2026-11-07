"""Check reviewed test evidence without promoting RED or approving implementation."""
from pathlib import Path
import hashlib,json,collections,sys
BASE=Path(__file__).resolve().parent

def main():
 path=Path(sys.argv[1]) if len(sys.argv)>1 else BASE/'review-fixes-evidence/all.json'
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
 controls=r['mutationControls'];assert len(controls)==16 and len({x['case'] for x in controls})==16,'missing mutation controls'
 assert all(x['killed'] and x['newlyFailedAssertions'] for x in controls),'surviving mutant or no mutation-specific failure'
 assert all(x['positiveStatus']=='PASS' for x in controls if x['positiveControl']),'positive control failed'
 root=BASE.parents[2]
 for row in inventory:assert hashlib.sha256((root/row['feature']).read_bytes()).hexdigest()==row['featureDigest']
 protected=json.loads((BASE/'review-fix-protected.json').read_text())
 for name,digest in protected.items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,'product/BDD changed:'+name
 screenshots={}
 for item in r['results']:
  if item['id'].startswith('TDD-UI-'):
   p=Path(item['notes'][0]['screenshot']);assert p.exists();screenshots[item['id']]=hashlib.sha256(p.read_bytes()).hexdigest()
 summary={'date':r['date'],'executionCounts':{'passed':r['passed'],'red':r['red'],'invalid':r['invalid']},'mutationControls':len(controls),'mutantsKilled':sum(x['killed'] for x in controls),'positiveControls':sum(x['positiveControl'] is not None for x in controls),'sourceAndObservationConsistency':'PASS','screenshots':screenshots,'faultsNotReached':[{'id':x['id'],'points':x['missingFaultPaths']} for x in r['results'] if x['missingFaultPaths']],'qualification':'No blanket RED qualification. Negative safety PASS is legitimate; unhit faults remain blocked paths. Independent re-review required.','readyForImplementation':False,'independentReReview':'PENDING','verifierSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
 (path.parent/'consistency.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n',encoding='utf-8');print(json.dumps({k:v for k,v in summary.items() if k not in ('screenshots','faultsNotReached')},ensure_ascii=False));return 0
if __name__=='__main__':sys.exit(main())
