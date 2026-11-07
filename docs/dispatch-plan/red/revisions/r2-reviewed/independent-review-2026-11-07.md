# 獨立測試品質審查 — GuGuBoard 派工／Webhook／Runner

日期：2026-11-07（Asia/Taipei）。結論：**READY_FOR_AI_IMPLEMENTATION = NO**。

| Verdict | 數量 |
|---|---:|
| VALID_RED | 11 |
| PARTIAL_RED | 35 |
| INVALID_RED | 2 |
| SPEC_GAP | 0 |
| 合計 | 48 |

## 身分、證據與限制

- 開發／測試撰寫者：本聊天主代理 `/root`（先前工作階段）。
- 獨立審查者：另外啟動且不繼承開發對話的 `/root/independent_red_review`；未參與本批測試、驅動或產品程式撰寫。
- 主代理僅保存與排版審查結果，不冒充獨立審查者。
- Checkout：D:\GuGuBoard；branch `master`；HEAD `ab2392318eb6e919fb5e4527100c9741b8ca3a16`。測試／規劃目錄未提交，HEAD 本身不能完整識別它們；本次另存來源 SHA-256 baseline。
- 審查方法：對照 48 項既有 all.json、來源、BDD、工單、資格檢查器與 provenance；其中八個 provenance 來源雜湊與當前檔案一致。
- 審查者沒有重跑 48 案，沒有執行會覆寫原始證據的 runner／qualifier，未修改任何檔案、產品、測試、看板或 Git。這是獨立來源與既有動態證據審查，不是重新產生的動態結果、產品實測驗收或發布核准。
- VALID_RED：直接對應 BDD，足以辨認缺失行為；不表示產品驗收或全契約覆蓋。
- PARTIAL_RED：有缺失訊號，但前提、故障路徑或重要 Then 未被證明。
- INVALID_RED：目前失敗不是 BDD 要求的缺失行為。
- 先前 gate-status.json／report.html 的 48 項自評保留供稽核；不得將該自評當成本次獨立審查的結果。此次僅新增審查文件，不修改原 gate 或看板狀態。

## 48 項逐項審查

以下 ID 均省略 TDD- 前綴；「無」表示無顯式故障注入；「0」表示被測骨架未命中故障點。

| ID | 失敗根因 | 故障到達 | Verdict／斷言有效性 | 具體補強 |
|---|---|---|---|---|
| SCH-01-1 | 未呼叫 Clock；回 NotImplemented | 無 | INVALID_RED：BDD「不產生事件」已通過；額外 Clock／NotDue 才造成 RED | 用可觀察時間邊界組合區分早派與不派，不指定內部呼叫作 BDD 失敗 |
| SCH-01-2 | 兩次評估後 outbox 仍為 0 | 無 | VALID_RED：直接觀察一個持久派工意圖 | 補 event identity、revision、cursor 原子提交及重啟重送 |
| SCH-01-3 | 未回 Validation | 無 | PARTIAL_RED：同一輸入同時違反時區與間隔，遮蔽單項缺陷 | 分開無時區／4 秒，補 5、3600、3601、空值及具體錯誤欄位 |
| SCH-02-1 | 未呼叫 Store.Read | 無 | INVALID_RED：BDD「不派工」已通過；RED 只來自強制讀 Port | 比較 paused／unpaused 相同到期排程；檢查事件與程序副作用 |
| SCH-02-2 | outbox 0；cursor 未追至現在 | 無 | VALID_RED：重開後沒有當下評估 | 補重複 reconciliation 不補發、跨 revision、停用狀態 |
| SCH-02-3 | 未達 Commit；未回 Unavailable | Store.Commit=0 | PARTIAL_RED：no-op 不等於原子失敗保護 | 證明已算出新 cursor/outbox；命中失敗後驗皆未提交，再重試 |
| WH-01-1 | HTTP 0；pending 未變 delivered | 無 | VALID_RED：實際接收及持久 receipt 缺失 | 驗 payload/eventId/簽章；工單與驗收狀態不得改動 |
| WH-01-2 | 沒接觸 timeout peer；未存 retry | timeout 未達 | PARTIAL_RED：未證明 timeout 分支 | 真 timeout 與分類、attempt/nextAt、deadline、完整事件保存 |
| WH-01-3 | 未回 Validation | 無 | PARTIAL_RED：固定 peer 計數看不到任意外連 | 用受控不允許 origin 與全出口監測；allowlist 由可信設定給定 |
| WH-02-1 | 到重試時間仍無 HTTP | 無 | PARTIAL_RED：儲存欄位相同不代表送出 bytes 相同 | peer 捕捉 body/ID/簽章/timestamp；驗時間邊界與退避序列 |
| WH-02-2 | 未存 manual | 無 | VALID_RED：轉人工核心行為可觀察 | 驗第 4→5 次實際失敗、理由與多次評估不再送 |
| WH-02-3 | reopen 後未投遞 | 無 | PARTIAL_RED：保存由 fixture 保證，未證明 subject 恢復 | subject 寫 retry 後重開，驗 endpoint、時鐘、到期順序 |
| RUN-01-1 | inbox 0；首次 200 非 202 | 無 | VALID_RED：真 ingress 與持久 dedup 缺失 | 同 ID 異 digest=409、並行重送、重開去重、ack 前 commit |
| RUN-01-2 | tampered/stale 均 200 | 無 | PARTIAL_RED：拒絕所有請求也會滿足負向案 | 有效簽章正向控制、±300/301、未來時間、未知/過期 key、缺 header、可信 key |
| RUN-01-3 | Commit 0；保存失敗及滿載均 200 | Commit=0，輸出遺失該 fault | PARTIAL_RED：兩種錯誤混案；只比較部分 inbox | 拆兩案、保留 fault hit、完整資料、無副作用、ack 與容量上界 |
| RUN-02-1 | leases 0；runs 0 | 無 | PARTIAL_RED：真雙程序，但 fake 已代做唯一 claim；未驗 Start 贏家 | barrier 放競爭 seam；核對 owner/generation 與 Start args，多輪及 fencing |
| RUN-02-2 | Start fault 0；Release 0 | Process.Start=0 | PARTIAL_RED：空 lease 不證明補償 | 先成功 claim，再命中 start error，驗回報與精確 owner/generation release |
| RUN-02-3 | 沒 Claim；未回 Idle | 無 | PARTIAL_RED：fake 可對空 board 發租約 | fake 依契約拒不存在票；驗 Idle、無 lease/inbox 消耗/程序，不強迫不必要 Claim |
| RUN-03-1 | Renew 呼叫 0 | 無 | PARTIAL_RED：不驗真的延長；fake Renew 沒寫 lease | 驗 old/new until、generation、時鐘與 299/300 秒、下次續租 |
| RUN-03-2 | Renew fault 0；子程序仍活 | Board.Renew=0 | PARTIAL_RED：漏整棵程序樹與工作區隔離 | 建父孫程序；deadline/重試；全樹退出、quarantine、Stop 失敗禁重領 |
| RUN-03-3 | 未 quarantine；未回 Quarantined | 無 | PARTIAL_RED：reopen 遺失 handle；未驗停舊後才重跑 | marker/建立時間/group 查舊程序；確認停止、隔離、新執行與 PID reuse |
| CMP-01-1 | journal 0；In Progress；lease 未放 | 無 | VALID_RED：交付持久化與進審查缺失 | payload/digest/版本、Green/READY_FOR_TDD/history、Confirm 前禁下一張 |
| CMP-01-2 | 未回 Validation | 無 | PARTIAL_RED：tests/evidence 同時空，遮蔽個別缺失 | 各自缺漏、failed>0、exit 非0、UNKNOWN、無 PR 理由、證據不存在/digest 不符 |
| CMP-01-3 | 未回 Conflict | 無 | PARTIAL_RED：僅 generation=0，漏其他版本 | 錯 ticket/run/project/owner/generation/SHA/tree，核對可信 ledger |
| CMP-02-1 | journal 0；未 Confirmed | 無 | PARTIAL_RED：沒有真的回應遺失，未驗原結果 | commit 後 response loss；相同 response、一次 note/update/release、完整 journal |
| CMP-02-2 | Release fault 0；未 Confirmed | Board.Release=0 | PARTIAL_RED：缺首輪失敗中間狀態與禁止接單 | ReviewUpdated 保留、無重複 update、restart 一次 release、最後 Confirm |
| CMP-02-3 | 未回 Conflict | 無 | PARTIAL_RED：新 evidence 同時帶 malformed digest | 兩份各自有效 payload/digest；由同 ID 異內容造成 Conflict，原 receipt 不變 |
| RUN-04-1 | FIX-2 未啟動；無新 session | 無 | VALID_RED：下一獨立工作與新 session 可觀察 | 缺 session 不可算新 session；驗可信身分與隔離 checkout |
| RUN-04-2 | 未回 Idle | 無 | PARTIAL_RED：no-start 已過，未驗無 Claim dependent | FIX-3 lease/Claim/Process 皆無，前置 Done 後可領正向控制 |
| RUN-04-3 | 未回 ReconcileRequired | 無 | PARTIAL_RED：未要求真正對帳、隔離或禁 Claim | 驗 reconciliation/read、保持未知、無 lease/process，對帳成功後繼續 |
| GOV-01-1 | 未回 Unauthorized | 無 | PARTIAL_RED：developerSession 由 request 自填 | 可信交付身分；偽造 request/session 不可繞過，驗 Identity port |
| GOV-01-2 | verifications 0 | 無 | VALID_RED：獨立驗證保存但不完成 | 完整記錄、tree/session、證據來源、失敗實測與自驗負向 |
| GOV-01-3 | reviews 0 | 無 | PARTIAL_RED：w.ident 不變近乎天然成立 | 不可變 identity 回傳；持久角色/權限不變、三角色/session 各異、tree 綁定 |
| GOV-02-1 | 未回 GateRejected | 無 | PARTIAL_RED：只缺 verified/merged | reviewed/authorized/tree mismatch、過期證據、跨專案、偽造 gate，快照不變 |
| GOV-02-2 | 未 Done/Blue；approvals 0 | 無 | PARTIAL_RED：seed 布林取代可信證據鏈，缺完整 history | 獨立記錄/Git port；history/revision/time；不同 merged tree 必拒 |
| GOV-02-3 | 未回 Unauthorized | 無 | PARTIAL_RED：其他 gates 未合格，拒絕原因可混淆 | 其餘 gates 全合格，只改可信角色/noApprove，無 mutation |
| UI-01-1 | concurrency 空白 | 無 | VALID_RED：瀏覽器缺預設值 | 並行值固定 read-only/disabled、其餘 defaults；產品 UI 另驗 |
| UI-01-2 | submit 後無 error text | 無 | PARTIAL_RED：任意非空字可過 | notBefore 對應可讀錯誤、焦點/aria、舊值與合法提交對照 |
| UI-01-3 | Save enabled | 無 | PARTIAL_RED：漏權限原因，disabled 時無強制 API 測試 | 理由、DOM disabled、forged command Unauthorized、完整快照不變 |
| UI-02-1 | key reference 空白 | 無 | PARTIAL_RED：innerText 漏 response/attribute/hidden/log secret | 檢查 response/network、outerHTML/attributes/scripts，不只不顯示 |
| UI-02-2 | HTTP 0；health 空白 | 無 | PARTIAL_RED：peer 固定 202，未走 Runner test-event 防工作 | 實際 test event 至 ingress，驗 mode/schema、inbox/lease/run 無正式工作、明確 health |
| UI-02-3 | Offline 未顯示 | 無 | PARTIAL_RED：Pause enabled 但無 handler | 點 Pause、持久 paused、禁止後續投遞、狀態；對齊 operation 契約 |
| UI-03-1 | process/completion 空白 | 無 | VALID_RED：兩種不同狀態分別顯示 | exit 非0、交付失敗、quarantine；exit 不等於成功文案 |
| UI-03-2 | Complete 未停用；reason 空白 | 無 | PARTIAL_RED：任意 reason 可過，漏繞 UI 拒絕 | exact PR_NOT_MERGED/可讀原因、直接 GateRejected、狀態不變 |
| UI-03-3 | empty text 空白 | 無 | VALID_RED：缺空狀態；無成功訊息有效 | 無假 run/card、無 aria success banner、正向資料對照 |
| INT-01-1 | FIX-2 未跑；FIX-1 Todo | 無 | PARTIAL_RED：手造 event 接各段，非真資料流 | 前段輸出作後段輸入，關聯 event/run/completion IDs/SHA，禁手補事件 |
| INT-01-2 | runs0；Release fault0；未 Confirm | Board.Release=0 | PARTIAL_RED：未 transport disconnect，只武裝 Release exception | 指定階段斷線/response loss，重啟同 journal，逐階段去重與恢復 |
| INT-01-3 | 未 Blue/Done | 無 | PARTIAL_RED：命令數不證明授權，完全未 assert FIX-3 解鎖 | 可信 identities/gate records；FIX-3 前禁領、之後真 claim/start；不同 tree 必敗 |
## 主要問題（P0–P4）

### P1：非行為 RED 被算成有效 RED

run_drivers.py:21、28 的 SCH-01-1／SCH-02-1：BDD 禁止副作用已通過，失敗來自額外 Clock／Store 呼叫或 outcome。Skeleton.ps1:9–11 是純 snapshot no-op，不能用它證明這兩項 BDD 不成立。

### P1：故障未到達，資格檢查仍全部列為 qualified

run_drivers.py:32、57、66、74、88 與 INT 恢復分支的 subject fault hits 全為 0。qualify_evidence.py:9 只要求有 failed assertion 與 invocation；:17 直接把全部放入 qualifiedBehaviorRED，沒有確認 BDD Then 為真正失敗、fault 到達或 assertion 的 actual/expected/pass 自洽。

RUN-01-3 在 run_drivers.py:58 清除 w.faults，結尾從目前 faults 建報告時遺失 Store.Commit 歷史；目前 pendingFaultHandlingVerification 因此少列此案。應記錄 immutable armed/triggered fault 歷史，不能只讀最後仍武裝的字典。

### P1：租約及恢復替身不足以支持安全契約

處於 driver_support.py:49–54 的 Claim 不驗 ticket 存在、狀態、相依、owner、notBefore；generation 固定 1。Renew 回時間但不更新持久 lease。:59–64 只起單子程序，Stop 終止此 World 的所有 children，沒有 run/ticket targeting、程序樹、建立時間或工作區隔離。重開 World 的 children 為空，不能辨認舊程序。

run_drivers.py:72 只查呼叫不查延期；:74 漏程序樹與隔離；:76 漏舊程序停止確認後才放行。這些是測試設備與斷言缺口，不是已證實的產品實際毀損。

### P1：治理測試缺可信驗證鏈

run_drivers.py:101–117 的 developer session 來自提交參數，gates 直接 seed 布林。錯誤實作「gates=true 就 Done」也可能通過 GOV-02-2，未證明可信角色、候選/合併 tree 與證據失效契約。三角色與 session 的反向矩陣不足。

### P1：整合資料流與相依解鎖未被驗證

INT 分支人工 event(w) 與固定 evt-1，不是轉送 scheduler 的輸出。INT-01-3 只檢查 Blue、Done 及三個 operation 名稱，沒有檢查 FIX-3 被解鎖或實際啟動。run_drivers.py:16 的 completion 固定 runId/SHA/tree，未從實際 run 派生。

### P2：HTTP fake 隱藏目標、header、deadline 等測試輸入

driver_support.py:42–45 忽略 subject 提供的 URL、headers、timeout，永遠送 self.url 且固定 .05 秒，規格為 10 秒。Peer 只記 body 長度，不存 bytes/header，不能驗 outgoing HMAC、exact origin、redirect、key rotation 或重送 body。event() 自控只證明 fixture 能簽，不能轉算 subject 驗簽證據。

### P2：UI 斷言不足

browser-driver.cjs 只擷取 innerText，不能證明秘密沒有在 response、attributes 或 hidden DOM 回傳。ui-skeleton.html:4 的 Pause 無 click handler；UI-01-3 漏權限原因；多項僅查任意非空字。run_drivers.py:119 將 UI-02 全查 GetWebhookView，UI-02-3 metadata 卻指定 GetRunnerView，必須對齊契約。

### P2：恢復前提與故障分類不足

CMP-02-1 未注入保存後 response loss；INT-01-2 未斷線。no-op 下的 snapshot 不變天然成立。Binding.invoke 在有任意 RPC fault 後將 target exception 當作 unhandledDependencyFailure，應逐案要求預期 domain error，不得把任意 raw exception 視為可接受測試結果。

### P3：完整性檢查不等於品質審查

qualify_evidence.py:7 的 len48 加 set equality 未顯式檢查 ID unique；截圖只驗存在，未驗 digest/內容相符；provenance 未綁當次 Git tree 及 PowerShell/Node/Chrome 執行檔版本。未發現因此偽造當前證據，但 verifier 防護不足。

### P3：多套重複資料會漂移

runner 主要用 cases ID/bdd 分派，request/expected/initialState 多數未驅動實際測試，task fixtures 也未載入。cases、task fixture、硬編碼 driver 可各自漂移。每案應記錄 scenario revision、fixture digest、實際 operation 與斷言追溯。

未發現本次材料可直接證明的產品 P0 缺陷；以上 P1 為實作前測試防線重大缺口，不應解讀成已發生的資料毀損。

## 進入實作前最低缺口

1. 修正兩個 INVALID_RED；不可只移除額外斷言後仍宣稱該 BDD 已有有效 RED。
2. 35 個 PARTIAL_RED 逐案補完整 Given/When/Then，優先完整程序樹／隔離、可信治理、相依解鎖、response loss、真正串接資料流。
3. 各 fault 分開記錄已武裝、subject 到達、真正觸發、處理結果；未命中禁止 failure-handling qualification，fixture 控制不得移算。
4. Mock 依 Port 契約驗輸入，但不能代替被測業務責任；HTTP 必須觀察實際 URL/header/body/deadline。
5. 加正負向與 mutation controls：拒絕全部、忽略時間、固定回結果、錯 owner 啟動、錯 tree 核准、secret 外漏、Pause 無效果等錯誤靶必須被測試抓到。控制靶不是產品實作，也不是驗收。
6. 凍結真正產品 Skeleton、Port signatures、錯誤模型、持久化契約及 productionAllowed file scope，經人確認。現有 productionAllowed=[]，不可自行解除。
7. 補強後再次獨立測試品質審查，完成架構與實作授權關卡。產品 UI、真 AI CLI、完整程序樹、真 Adapters、安裝及完整回歸，皆未由本審查完成。

## 最終判定

**測試套件品質審查：需補強／退回測試準備階段。**

**READY_FOR_AI_IMPLEMENTATION：NO。**

此為測試審查結果，不是產品 acceptance。沒有實作或修正產品，沒有修改原測試、BDD、gate、自評證據、看板完成狀態或 Git。補強清單是後續工作，不代表本次已修復。
