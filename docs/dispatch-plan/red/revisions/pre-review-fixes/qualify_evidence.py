"""Qualify reproducible skeleton RED, never product acceptance."""
from pathlib import Path
import hashlib,json,html
BASE=Path(__file__).resolve().parent
report=json.loads((BASE/'driver-evidence/all.json').read_text(encoding='utf-8'))
cases=json.loads((BASE/'cases.json').read_text(encoding='utf-8'))
assert report['invalid']==0 and len(report['results'])==48
assert {r['id'] for r in report['results']}=={c['id'] for c in cases}
assert all(r['status']=='BEHAVIOR_RED' and any(not c['pass'] for c in r['checks']) and r['invocations'] for r in report['results'])
assert all(v=='PASS' for v in report['fixtureControls'].values())
for name,digest in report['provenance']['files'].items():assert hashlib.sha256((BASE/name).read_bytes()).hexdigest()==digest, 'stale driver:'+name
root=BASE.parents[2]
protected=json.loads((BASE/'protected-hashes.json').read_text(encoding='utf-8'))
for name,digest in protected.items():assert hashlib.sha256((root/name).read_bytes()).hexdigest()==digest,'protected changed:'+name
ui=[r for r in report['results'] if r['id'].startswith('TDD-UI-')]
assert len(ui)==9 and all(r['notes'] and Path(r['notes'][0]['screenshot']).exists() for r in ui)
g=json.loads((BASE/'gate-status.json').read_text(encoding='utf-8'))
g.update(date='2026-11-07',qualifiedBehaviorRED=[r['id'] for r in report['results']],remainingCases=[],qualifiedLayer='48/48 executable boundary-driver RED against unchanged test-only skeleton; no product acceptance',testFramework='PowerShell input skeleton + Python standard-library executable ports/drivers + isolated Playwright 1.56.1 / installed Chrome',canonicalEvidence='driver-evidence/all.json',newlyQualifiedCases=45,independentVerification='NOT RUN',approvalGate='PRESERVED',readyForImplementation=False)
g['notReadyReasons']=['Production envelope/file scope is not frozen; product implementation remains unauthorized','Independent test-quality review and acceptance NOT RUN','Empty skeleton never calls output ports: missing orchestration RED is not verified failure handling','Browser exercises test-only HTML adapter, not installed product UI','Single real child lifecycle is fixture control; production process-tree and installer verification NOT RUN','Official GuGuBoard board import NOT RUN']
g['pendingFaultHandlingVerification']=[{'id':r['id'],'unreached':r['missingFaultPaths']} for r in report['results'] if r['missingFaultPaths']]
(BASE/'gate-status.json').write_text(json.dumps(g,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
rows=[]
for r in report['results']:
 failed=[c for c in r['checks'] if not c['pass']]
 failures='<br>'.join(html.escape(c['assertion'])+': '+html.escape(str(c['actual']))+' → '+html.escape(str(c['expected'])) for c in failed)
 shots=' '.join('<a href="'+Path(n['screenshot']).name+'">截圖</a>' for n in r['notes'] if 'screenshot' in n)
 rows.append('<tr><td>'+r['id']+'</td><td>RED</td><td>'+str(len(r['invocations']))+'</td><td>'+failures+'</td><td>'+html.escape(str(r['faultHitCounts']))+'</td><td>'+shots+'</td></tr>')
page='''<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><title>GuGuBoard RED 行為證據</title><style>body{font:16px system-ui;max-width:1400px;margin:30px auto;padding:20px;color:#17253b}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ccc;padding:10px;text-align:left;vertical-align:top}th{background:#edf2fa}</style><h1>48 個可執行行為案例：48 RED，0 設備／fixture 錯誤</h1><p>2026-11-07｜本次補齊 45 個驅動｜九個真瀏覽器情境有截圖｜原 BDD、產品程式與空骨架不變。</p><p><strong>證據邊界：</strong>RED 針對測試專用空骨架。故障設備控制均 PASS；空骨架沒有呼叫 Output Ports，命中數為零時代表缺少編排，不能聲稱已驗證故障處理、回滾或重試。瀏覽器操作測試 HTML，而非產品 UI。獨立驗證／審查／核准均 NOT RUN，禁止開始產品實作。</p><p><a href="all.json">完整呼叫／故障／狀態證據 JSON</a></p><table><tr><th>案例</th><th>結果</th><th>實際呼叫數</th><th>失敗行為：實際 → 預期</th><th>故障命中數</th><th>介面證據</th></tr>'''+''.join(rows)+'</table></html>'
(BASE/'driver-evidence/report.html').write_text(page,encoding='utf-8')
print(json.dumps({'evidenceConsistency':'PASS','behaviorRED':48,'newDrivers':45,'fixtureErrors':0,'browserCases':9,'protectedHashes':len(protected),'independentAcceptance':'NOT RUN'}))
