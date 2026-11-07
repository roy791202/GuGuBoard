"""Generate review-only engineering artifacts; never mutates the live board."""
import json, html, hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'docs/dispatch-plan'
STAMP = '2026-11-06T00:00:00+08:00'
TASKS = [
 ('SCH-01','dispatch-scheduling','到期與唯一派工意圖',6,[], [('有效排程在開始前一秒','評估派工','不產生事件'),('有效排程剛好到期','連續評估兩次','只保存一個派工意圖'),('時間未含時區或間隔小於五秒','儲存設定','拒絕設定且保留舊值')]),
 ('SCH-02','dispatch-scheduling','暫停與重新啟動對帳',6,['SCH-01'], [('專案已暫停','到達派工時間','不派工'),('服務錯過三個檢查週期','恢復服務','只重新評估目前工作且不補發三批'),('事件保存失敗','評估到期排程','不推進排程游標')]),
 ('WH-01','webhook-delivery','可靠投遞',6,['SCH-01'], [('有一筆待投遞事件','接收端可靠接收','事件標示已接收而非工作完成'),('接收端逾時','投遞事件','保留待重試紀錄'),('目標不在允許清單','儲存目標','拒絕目標且不連線')]),
 ('WH-02','webhook-delivery','有界重試與恢復',6,['WH-01'], [('事件已失敗一次','到達下一重試時間','使用相同事件識別重新投遞'),('事件已連續失敗五次','評估重試','停止自動重試並顯示人工處理'),('服務在重試前重啟','恢復投遞','保留次數與下次時間')]),
 ('RUN-01','ai-runner','驗證喚醒與可靠去重',8,[], [('事件有效且佇列有空位','接收兩次相同事件','只保存一筆工作'),('事件已被竄改或超過五分鐘','接收事件','拒絕且不啟動工作'),('接收儲存失敗或佇列已滿','接收事件','不回覆成功且不遺失已接受工作')]),
 ('RUN-02','ai-runner','領單後隔離啟動',8,['RUN-01'], [('有兩個 Runner 同時要求一張工作','領取工作','只有有效租約持有人啟動'),('領取成功但程序無法啟動','開始工作','回報失敗並釋放租約'),('沒有可領工單','請求工作','進入等待且不啟動程序')]),
 ('RUN-03','ai-runner','續租與中止恢復',8,['RUN-02'], [('工作仍在執行且持有租約','到達五分鐘續租點','延長租約'),('續租無法在安全期限內確認','處理租約失效','停止整個受控程序樹且隔離工作區'),('Runner 重啟且舊程序狀態未知','執行恢復對帳','先隔離並確認舊程序停止再允許新執行')]),
 ('CMP-01','work-completion','驗證交付回報',8,['RUN-02'], [('測試全綠且證據完整','提交交付','工單進入審查中並保存證據'),('程序正常結束但缺測試證據','提交交付','拒絕成功交付且不設完成'),('交付內容來自其他租約或版本','提交交付','拒絕回報且保留原工單')]),
 ('CMP-02','work-completion','交付重入與對帳',8,['CMP-01'], [('交付已保存但回應遺失','重送相同交付','回傳原結果且不重複追加交付'),('工單已進審查中但釋放失敗','重試交付','完成釋放並確認交付'),('相同交付識別帶不同內容','重新提交','回報衝突且不覆寫原證據')]),
 ('RUN-04','ai-runner','交付後繼續領單',6,['CMP-02','RUN-03'], [('上一張交付已確認且存在獨立就緒工單','繼續領單','在新工作階段執行下一張'),('下一張相依工單尚未核准合併','繼續領單','不領取相依工單'),('上一張交付結果未知','繼續執行','先對帳且不接新工單')]),
 ('GOV-01','verification-approval','角色與工作階段分離',8,[], [('驗證者是原開發者或同一工作階段','提交驗證','拒絕驗收'),('獨立驗證者完成實測','提交證據','保存驗證結果但不自動完成'),('獨立審查者與開發者身分不同','提交審查','保存審查結果且不提升角色')]),
 ('GOV-02','verification-approval','核准與合併關卡',8,['GOV-01'], [('尚未驗證或尚未合併','要求完成工單','拒絕完成'),('驗證審查核准皆通過且證據對應已合併版本','授權者確認完成','工單設完成與藍燈並保存歷程'),('開發者或派工憑證嘗試核准','要求完成工單','拒絕且保留狀態')]),
 ('UI-01','dispatch-scheduling','排程設定介面',6,['SCH-02'], [('管理者開啟新排程','檢視設定','顯示停用與並行一個的預設值'),('開始時間無效','儲存設定','顯示欄位錯誤且保留舊設定'),('唯讀使用者開啟設定','嘗試變更','無法儲存且顯示權限原因')]),
 ('UI-02','webhook-delivery','Webhook 與 Runner 設定介面',6,['WH-02','RUN-01'], [('管理者設定金鑰','重新開啟設定','只顯示金鑰參照且不回傳秘密'),('管理者發出測試事件','檢視結果','顯示連線結果且不啟動正式工單'),('Runner 離線','檢視設定','顯示離線狀態且可暫停投遞')]),
 ('UI-03','verification-approval','執行與關卡紀錄介面',6,['GOV-02','CMP-02'], [('程序已結束但交付未確認','檢視工單','分別呈現程序與交付狀態'),('尚未合併工單','檢視關卡','完成控制停用並說明原因'),('沒有執行紀錄','檢視紀錄','呈現空狀態且不顯示成功')]),
 ('INT-01','dispatch-integration','完整派工與恢復',8,['RUN-04','GOV-02','UI-03','UI-02'], [('兩張獨立已就緒工作與一張未解除相依工作','完成第一張交付','第二張開始且第一張等待獨立驗證並不領第三張'),('事件重送且交付中途斷線','服務恢復對帳','不重複執行且能確認交付'),('開發完成後由不同身分驗證審查並核准已合併版本','完成驗收','僅此時變藍並解除相依')]),
]
META = {
 'dispatch-scheduling': ('定時派工','擁有排程與到期游標；不擁有工單或 AI 程序',['ConfigureSchedule','EvaluateDue','PauseSchedule'],['Clock','ScheduleOutboxStore','TicketQuery'],'排程游標與 outbox 同交易提交'),
 'webhook-delivery': ('Webhook 投遞','擁有投遞紀錄與重試；不擁有工單執行',['DeliverPending','RetryDue','TestDelivery'],['HttpDelivery','DeliveryStore','SecretProvider','Clock'],'事件識別固定；成功接收後才標示 delivered'),
 'ai-runner': ('AI Runner','擁有 inbox 與本機 run；工單租約仍由看板授權',['AcceptWakeup','RunNext','Reconcile','StopRun'],['TicketLease','AIProcess','RunStore','Workspace','Clock','SecretProvider'],'inbox 與去重一起保存；領取後啟動失敗須補償釋放'),
 'work-completion': ('交付回報','擁有 completion journal；不擁有最終核准',['SubmitCompletion','ReconcileCompletion'],['BoardDelivery','EvidenceStore','CompletionStore','Clock'],'Prepared → EvidenceSaved → ReviewUpdated → Released → Confirmed；每步可重入'),
 'verification-approval': ('獨立驗證與核准','擁有驗證證據與核准紀錄；角色由可信設定提供',['SubmitVerification','SubmitReview','ApproveCompletion'],['Identity','BoardGate','PullRequestStatus','EvidenceStore'],'驗證、審查、核准需綁定同一候選版本；版本改變須失效重驗'),
 'dispatch-integration': ('派工整合','只驗證跨模組流程，不擁有其他模組狀態',['ExerciseSystem'],['Scheduling','Delivery','Runner','Completion','Approval'],'沿用各模組交易；不用分散式原子交易'),
}
CONTRACTS = [
 'C01：有效租約為執行授權；同工單最多一個有效執行者。舊程序停止無法確認時隔離並阻擋再啟動。',
 'C02：Webhook 至少一次投遞；接收端依 eventId 與 payload digest 去重；同 ID 不同內容拒絕。',
 'C03：HTTP 202 只代表 durable inbox 已保存；不表示工作、交付或驗收完成。',
 'C04：exit 0 不代表成功交付；成功需要測試、證據、工單、runId、lease generation、checkout SHA。',
 'C05：同 completionId 同內容可重送；不同內容衝突；Confirm 前不得接下一張。',
 'C06：開發只能 In Review／READY_FOR_TDD；Done 需獨立驗證、獨立審查、授權核准及 PR 合併。',
 'C07：依賴仍需 Done／Released；回報交付不解除依賴。',
 'C08：排程與候選選擇在領單端再驗證；Webhook 不帶執行權；既有派工器與新 Runner 不得同時驅動同專案。',
 'C09：角色、工作階段與版本來自可信記錄，不能採信 AI 自填身分。驗證證據綁定候選 tree；合併 tree 不同須重驗。',
 'C10：錯誤分類 Validation／Unauthorized／Conflict／Unavailable／Timeout／LeaseLost／ReplanRequired；失敗不回傳 succeeded=true。',
]

def write(path, text):
 path.parent.mkdir(parents=True, exist_ok=True)
 path.write_text(text, encoding='utf-8')

def render(spec):
 raw=json.dumps(spec,ensure_ascii=False,indent=2).replace('<','\\u003c')
 def view(v):
  if isinstance(v,dict): return '<dl>'+''.join('<dt><b>'+html.escape(str(k))+'</b></dt><dd>'+view(x)+'</dd>' for k,x in v.items())+'</dl>'
  if isinstance(v,list): return '<ul>'+''.join('<li>'+view(x)+'</li>' for x in v)+'</ul>'
  if isinstance(v,str) and v.endswith('.html'): return '<a href="../../'+html.escape(v,quote=True)+'">'+html.escape(v)+'</a>'
  return html.escape(str(v))
 sections=[]
 for caption,labels in [('Hexagonal System Boundary',['Driving adapters: UI / Timer / HTTP','Input Ports','Application → Domain Core','Output Ports ← Driven Adapters']),('Module Dependency / State Boundaries',['Scheduling [schedule + outbox]','Webhook [delivery] → Runner [inbox + run]','Completion [journal] → Next Claim','Verification → Review → Approval + Merge'])]:
  boxes=''.join(f'<rect x="20" y="{15+i*75}" width="660" height="48" rx="8" fill="#e6eefb" stroke="#537cb0"/><text x="35" y="{45+i*75}" fill="#17253b" font-size="16">{html.escape(label)}</text>'+ (f'<path d="M350 {63+i*75} v27 m-5 -7 l5 7 5 -7" fill="none" stroke="#537cb0"/>' if i<3 else '') for i,label in enumerate(labels))
  sections.append('<section><h2>'+caption+'</h2><svg role="img" aria-label="'+caption+'" viewBox="0 0 700 310" style="width:100%">'+boxes+'</svg><p>箭頭向內表示控制或契約依賴；方括號為模組權威狀態。模組之間僅經 Ports；交易範圍見下方規格。</p></section>')
 for k,v in spec.items():
  sections.append('<section><h2>'+html.escape(k)+'</h2>'+view(v)+'</section>')
 return '<!doctype html><html lang="zh-Hant"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>'+html.escape(spec['title'])+'</title><style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:20px;background:#f4f6fa;color:#17253b}section{background:white;padding:20px;margin:16px 0;border-radius:10px}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:15px system-ui;line-height:1.7}a{color:#2157ae}</style><h1>'+html.escape(spec['title'])+'</h1><p>規劃與測試套件｜詳細規格已同意｜測試層級見各節證據｜禁止派工</p>'+''.join(sections)+'<script type="application/json" id="module-spec">'+raw+'</script></html>'

def main():
 BASE.mkdir(parents=True,exist_ok=True)
 gate_path=BASE/'red/gate-status.json'
 gate=json.loads(gate_path.read_text(encoding='utf-8')) if gate_path.exists() else {}
 result_path=BASE/'red'/gate.get('canonicalEvidence','driver-evidence/all.json')
 assert result_path.resolve().is_relative_to((BASE/'red').resolve())
 run=json.loads(result_path.read_text(encoding='utf-8')) if result_path.exists() else {}
 observed={r['id']:r for r in run.get('results',[]) if r['status'] in ('PASS','BEHAVIOR_RED')}
 manifest={'schemaVersion':1,'date':'2026-11-07','approval':'Scope and detailed specification approved; production envelope not frozen','implementation':'NOT_READY_FOR_IMPLEMENTATION','modules':[],'tickets':[]}
 for mod,(title,owner,inputs,outputs,transaction) in META.items():
  tasks=[]; scenarios=[]
  for tid,m,name,hours,deps,cases in TASKS:
   if m!=mod: continue
   sid='S-'+tid
   bdd=[]
   for n,(given,when,then) in enumerate(cases,1):
    bid=f'{sid}-{n}'; testid=f'TDD-{tid}-{n}'
    bdd.append({'id':bid,'given':given,'when':when,'then':then,'test':testid,'level':'L4' if tid=='INT-01' else ('L3' if tid.startswith('UI') else 'L2'),'result':observed[testid]['status'] if testid in observed else 'NOT RUN'})
   feature='Feature: '+name+'\n  Background:\n    Given 已授權且隔離的測試專案\n\n  Rule: '+title+'遵守交付與角色邊界\n'
   for b in bdd:
    feature+=f"\n    @{b['id']}\n    Scenario: {b['id']} {b['then']}\n      Given {b['given']}\n      When {b['when']}\n      Then {b['then']}\n"
   write(BASE/f'bdd/{sid}.feature',feature)
   packet={'id':tid,'module':mod,'parentStory':sid,'title':name,'intent':name,'layer':'Presentation' if tid.startswith('UI') else 'Application','estimateHours':hours,'status':'Backlog','light':'Gray','tdd':'Red' if any(observed.get(b['test'],{}).get('status')=='BEHAVIOR_RED' for b in bdd) else 'None','ci':'NOT RUN','prUrl':'','dependsOn':deps,'contracts':CONTRACTS,'bdd':bdd,'fixtures':f'fixtures/{tid}.json','testPlan':{'command':f'pwsh -NoProfile -File docs/dispatch-plan/red/Run-Red.ps1 -Task {tid}','redCriterion':'測試可載入且 fixture 正確；僅因缺少上述 observable behavior 失敗。缺套件、編譯錯誤與 pending stub 不算 RED。','failureInjection':'在所有 Output Port 回傳可控失敗；比較前後持久化快照、事件數、啟動次數與工單狀態','acceptance':['所有列出 Then 均有可執行斷言','測試意圖不變且 focused 與 module contract GREEN','相鄰回歸全部 GREEN 或逐項分類','獨立實測與審查；無越界修改']},'scope':{'allowedNow':[f'docs/dispatch-plan/tasks/{mod}/{tid}.json',f'docs/dispatch-plan/bdd/{sid}.feature',f'docs/dispatch-plan/fixtures/{tid}.json'],'productionAllowed':[],'protected':['serve-board.ps1','serve-ext.ps1','board.html','.ai-pm/**','.ai-board/**','.ai-hooks/**','.githooks/**','.github/**'],'gate':'具體產品路徑、介面與 RED 尚未凍結；禁止由本工單開始實作'},'regression':['L0 pure policies','L1 public component','L2 module ports','L3 real adapters','L4 adjacent modules','L5 system acceptance'],'roles':{'developer':'UNASSIGNED','verifier':'UNASSIGNED distinct identity/session','reviewer':'UNASSIGNED distinct identity/session'},'history':[{'at':STAMP,'from':None,'to':'Backlog','by':'planning-assistant','reason':'建立文件工單，未匯入正式看板'}]}
   write(BASE/f'tasks/{mod}/{tid}.json',json.dumps(packet,ensure_ascii=False,indent=2)+'\n')
   write(BASE/f'fixtures/{tid}.json',json.dumps({'task':tid,'clock':'2026-11-06T09:00:00+08:00','project':'fixture-guguboard','ticket':'FIX-1','nextIndependent':'FIX-2','dependent':'FIX-3','eventId':'evt-fixture-1','completionId':'cmp-fixture-1','identities':{'developer':'dev-1','verifier':'qa-1','reviewer':'review-1','approver':'human-1'},'secrets':'test doubles only; no real credentials','cases':bdd},ensure_ascii=False,indent=2)+'\n')
   tasks.append(packet);scenarios.extend(bdd);manifest['tickets'].append({'id':tid,'module':mod,'path':f'tasks/{mod}/{tid}.json','status':'Backlog','light':'Gray'})
  spec={'title':title,'module':mod,'purpose':owner,'status':{'architecture':'DETAILED_REVIEW_PENDING','scope':'APPROVED','skeleton':'NOT CREATED','red':'NOT RUN','implementation':'NOT STARTED','moduleHealth':'NOT_READY'},'architecture':{'context':'GuGuBoard 管理者、排程服務、Webhook、Windows Runner、AI CLI、獨立驗證與 Git PR provider','domain':'純政策與不變量，不依賴平台','application':'協調以下 input/output ports','inputPorts':inputs,'outputPorts':outputs,'drivingAdapters':['管理 UI／API','受控計時器或 Webhook ingress','Contract tests'],'drivenAdapters':['持久化','HTTP／Agent API','Windows 程序或測試 doubles：依實際 Port 選用'],'hexagonalDiagram':'外部 UI／Timer／HTTP → Input Ports → Application → Domain；Application → Output Ports ← Infrastructure implements','dependencyDiagram':'Presentation → Command → Application → Domain；Adapters → Ports；內層不引用外層','stateOwnership':owner,'mutationBoundary':'僅對應 use case 可經儲存 Port 變更其權威狀態','transactionBoundary':transaction,'externalBoundary':'AI 輸出與網路輸入不可信；驗證身分與證據來源','forbidden':['Domain → HTTP／Filesystem／Process','UI → shell／直接寫狀態','跨模組直接讀寫內部狀態']},'contractsAndInvariants':CONTRACTS,'bddCoverage':scenarios,'coverageCategories':{f'B{i}':{'status':'Applicable','evidence':'規劃情境及失敗注入；實際 coverage 待 executable tests','deferred':'跨 OS 真機驗證 deferred：第一階段 Windows，核心仍須平台無關'} for i in range(1,13)},'tddStrategy':{'levels':['L0 Unit','L1 Component','L2 Module Contract','L3 Adapter Integration','L4 Cross-module','L5 System'],'red':'NOT RUN; stubs 不可列入 passing suite','pendingAutomation':['選定既有相容測試框架','凍結 ports 與可編譯骨架','實作 assertions 與 fake ports','記錄有效 RED','獨立 UI/CLI evidence']},'tasks':tasks,'risks':['既有 claim/report 尚不足以提供 generation fencing 與 completion idempotency，需先核准相容擴充','目前無產品層實測、無可執行產品綁定、不可派工','不得以文件檢查取代行為證據'],'decisions':['六角形＋洋蔥；不引入 CQRS 或通用工作流引擎','保留既有 API；新增能力需詳細契約核准','本套件不修改正式看板'],'metadata':{'date':'2026-11-07','revision':1,'source':'embedded ModuleSpec; regenerate using build_plan.py'}}
  evidence_path=BASE/'red/gate-status.json'
  if evidence_path.exists():
   evidence=json.loads(evidence_path.read_text(encoding='utf-8'))
   spec['status']['scope']='APPROVED'
   spec['status']['architecture']='DETAILED_SPEC_APPROVED; executable envelope still pending'
   spec['status']['skeleton']='TEST ONLY; production NOT CREATED'
   spec['status']['red']=evidence.get('qualifiedLayer','RED evidence pending')
   spec['redEvidence']=evidence
   spec['tddStrategy']['red']=evidence.get('qualifiedLayer','NOT RUN')
   spec['tddStrategy']['pendingAutomation']=['凍結產品 input/output ports 與 scope','產品實作後確認每個故障點實際命中及補償斷言','獨立測試品質審查與產品 UI/CLI 驗收']
   spec['risks'].append('Empty-skeleton RED is not fault-handling verification or product UI acceptance; inspect per-case reachability')
   spec['behaviorEvidence']=[{'id':r['id'],'status':r['status'],'checks':r['checks'],'missingFaultPaths':r.get('missingFaultPaths',[]),'notes':r.get('notes',[])} for r in run.get('results',[]) if r['id'] in {b['test'] for b in scenarios}]
  out=ROOT/f'.devworkflow/modules/{mod}/module.html';write(out,render(spec));manifest['modules'].append({'id':mod,'html':str(out.relative_to(ROOT)).replace('\\','/')})
 write(BASE/'plan-index.json',json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
 hierarchy=[{'id':'E-DISPATCH','level':'Epic','title':'可靠自動派工與獨立驗收','parentId':None,'status':'Backlog','light':'Gray'}]
 for mod,(title,*_) in META.items():
  hierarchy.append({'id':'F-'+mod,'level':'Feature','title':title,'parentId':'E-DISPATCH','status':'Backlog','light':'Gray'})
 for tid,mod,title,hours,deps,cases in TASKS:
  hierarchy.append({'id':'S-'+tid,'level':'Story','title':'作為管理者，我想要'+title+'，以便安全自動交付工作','parentId':'F-'+mod,'estimate':{'storyPoints':3 if hours<=6 else 5},'estimateNote':'初估，待團隊校準','status':'Backlog','light':'Gray','bdd':[f'S-{tid}-{i}' for i in range(1,len(cases)+1)]})
  hierarchy.append({'id':tid,'level':'Task','title':title,'parentId':'S-'+tid,'estimate':{'hours':hours},'dependsOn':deps,'status':'Backlog','light':'Gray','scenarioIds':[f'S-{tid}-{i}' for i in range(1,len(cases)+1)]})
 write(BASE/'work-hierarchy.json',json.dumps({'purpose':'Planning hierarchy, not a live board import payload','items':hierarchy},ensure_ascii=False,indent=2)+'\n')
 system={'title':'GuGuBoard 定時派工、Webhook 與 AI Runner','intent':'開發交付確認後自動接下一張；獨立驗證、審查、核准及合併關卡保留','moduleNavigation':manifest['modules'],'workflow':'Due → Outbox → Webhook → Inbox → Claim → Run → Completion Confirmed → Next Claim；In Review → Independent Verify → Independent Review → Authorized Approval + Merged PR → Done','tasks':manifest['tickets'],'gate':gate.get('qualifiedLayer','Detailed specification approved; implementation not authorized'),'results':'文件驗證見 validation.json；測試骨架 RED 分級見 docs/dispatch-plan/red/gate-status.json；無 build/package/runtime acceptance 證據'}
 write(ROOT/'.devworkflow/system/system.html',render(system))
 # Explicit inert binding skeletons: no misleading empty passing tests.
 bindings=[{'scenario':f'S-{tid}-{i}','Given':g,'When':w,'Then':t,'binding':'UNBOUND','result':'NOT RUN'} for tid,_,_,_,_,cases in TASKS for i,(g,w,t) in enumerate(cases,1)]
 write(BASE/'step-stubs.json',json.dumps({'status':'EXECUTABLE_BEHAVIOR_DRIVERS_BOUND' if (BASE/'red/gate-status.json').exists() else 'PENDING_NOT_EXECUTABLE','mustFailIfUnbound':True,'bindings':[{**b, 'binding':'red/Run-Red.ps1 -> '+b['scenario'].replace('S-','TDD-',1), 'result':observed.get(b['scenario'].replace('S-','TDD-',1),{}).get('status','NOT RUN')} for b in bindings] if (BASE/'red/gate-status.json').exists() else bindings},ensure_ascii=False,indent=2)+'\n')
 print(f'Generated {len(META)} module documents, {len(TASKS)} tickets, {len(bindings)} scenarios; no production changes.')

if __name__=='__main__': main()
