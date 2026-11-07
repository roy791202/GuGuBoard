# 定時派工／Webhook／AI Runner 規劃套件

日期：2026-11-06，Asia/Taipei。使用者已同意第一階段範圍與模組切分。這不是產品實作授權，也不是架構全關卡、RED 或驗收通過的證據。

入口：../../.devworkflow/system/system.html。每個 module.html 的 embedded ModuleSpec 是該模組的結構化規格與人類閱讀投影。build_plan.py 是重建模板；變更生成來源後必須重建，不應另行手改生成文件。

## 交付與權限

- 6 個模組文件：5 個產品責任模組＋1 個跨模組驗證模組。
- 16 張 Backlog／Gray 文件工單，48 個 Gherkin 情境、48 個可執行 step bindings（測試專用骨架），逐工單 fixture。
- 已建測試專用骨架與可執行行為驅動；尚無 productionAllowed files 或產品骨架。全部仍 NOT_READY_FOR_IMPLEMENTATION。
- 不變更原有已暫存檔案，不提交、不啟用派工、不更改 hooks／CI／角色。
- MCP 現在綁定 3DCoreEngine；本套件屬於 GuGuBoard，禁止匯入錯誤專案。正式 GuGuBoard 專案位置／可寫連接尚未確認，因此工單目前僅在本套件，不宣稱已建正式看板卡片。
- 未發現可用的專案 LESSONS 文件；本次風險直接記入契約與工單，不把推測當歷史事故。

## 架構決策與現況差異

以既有 PowerShell server + HTML UI 為相容起點，不先指定新語言或套件。Domain 純政策、Application orchestration、Ports、Adapters 明確分離；實體路徑與 API 骨架於下一個設計關卡凍結。

現有 serve-ext.ps1 的 claim 依角色、狀態、指派與 dependsOn 選擇；plannedStart 尚非執行閘門。report 主要追加 note；既有派工器直接啟動 CLI。新方案不可假設現有 API 已提供 completion idempotency、lease generation、身分分離或原子 outbox。

選用六角形＋洋蔥是因為需替換時間、持久化、HTTP、程序與工單服務。捨棄直接在既有 timer 混入所有規則；不採 CQRS、分散式交易或通用 workflow engine。未有測量證據不新增效能框架。

## 詳細契約草案（待設計確認）

### 排程與選擇

首次 notBefore 含 UTC offset；顯示時區 Asia/Taipei。每專案 active run 上限 1；intervalSec 5..3600，預設 60。到期時間比較 inclusive；重啟只評估當下，不補送每個錯過 tick。

沿用看板順序，先排除非 Todo／In Progress、Red、paused、指派不符、已領取、dependsOn 未 Done／Released、未到 notBefore 的工單。在最終 claim 時重新核對條件；不能靠先前 Webhook 的快照授權。新舊派工器採 project dispatch mode 互斥，預設 legacy；切換前須 drain 並人工啟用。

排程識別、revision、游標與 outbox 需同一持久化提交。第一階段單機單服務實例；多寫入者須持鎖並以 revision CAS。跨主機多活 deferred，禁止直接擴增服務副本。

### Webhook

提案入口 POST /runner/v1/events；此端點尚未存在。事件欄位：schemaVersion=1、eventId、projectId、scheduleRevision、occurredAt、eventType=wakeup、targetRunnerId；不包含 token、任意 shell 指令或完整提示詞。

簽章欄位：keyId、timestamp、HMAC-SHA256(timestamp + '.' + 原始 UTF-8 body)。接受時鐘差 ±300 秒；重送需更新 timestamp 並重簽，eventId 與 payload 保持不變。常數時間比對；驗證後以 eventId + body digest 去重，相同 ID 不同 digest 回 409。舊 key 僅在明確有效期內接受。

durable inbox 與去重一起提交後回 202；重複相同事件回 200；格式錯誤 400、認證失敗 401、佇列滿 429、保存失敗 503。限制 body 64 KiB；每 Runner pending inbox 1000 筆、每專案 outbox 1000 筆，超限拒絕新增並保留已存資料。

10 秒 timeout；最多 5 次投遞，失敗後等待 10、30、120、300 秒。2xx 視為可靠接收；429、5xx、網路失敗可重試；其他 4xx 進人工處理。停用 redirect。只允許管理者設定之 exact origin allowlist，禁止連線至任意由事件提供的 URL；本機固定 loopback endpoint 可用 HTTP，其他目標需 HTTPS 與憑證驗證。

本階段是同機 Windows Runner，不對外開放看板。遠端 Runner、tunnel、跨網段與 DNS 防護需另一架構切片。

### Runner 與租約

Webhook 喚醒只觸發領單檢查，不自帶領單權限。一次一個 runId、一個隔離 checkout/worktree、一個 AI CLI process tree；工作區身分、SHA 與允許 scope 綁定執行。

可信 orchestrator 每五分鐘續租；依伺服器回覆的有效期，最遲到期前 60 秒仍未續租成功即停止程序樹。必須驗證已退出；無法停止則 quarantine 並阻擋重領，不假設 Kill 成功。網路分割無法提供瞬間全域停止保證；安全截止前停止與重新領取前對帳是硬契約。

Runner 重啟不得只憑 PID 殺程序或判定工作仍存在，需 run marker、程序建立時間與受控程序群組。租約 generation／fencing 必須由伺服器提供並驗證；目前缺此契約，需架構確認後才新增。Claim、續租、交付不得只依 AI 自填身分。

### 交付與下一張

Completion 包含 completionId、projectId、ticketId、runId、leaseGeneration、developer identity/session、checkout SHA/tree、測試命令與 exit／passed／failed／分類、證據 URI＋digest、結果、PR 或無 PR 原因。失敗或未知狀態不得偽裝 Green。

狀態：Prepared → EvidenceSaved → ReviewUpdated → Released → Confirmed。持久化每步與回執；同 ID 同 digest 重送回原結果，不同內容 Conflict。對帳先讀回看板與 journal。Confirmed 前不接下一張；若無法確定先前更新是否生效，隔離等待人工或重試，不能倒退狀態。

成功交付最多設 In Review／Green／READY_FOR_TDD。卡住時設 Yellow／Red 並填 reason；Red 時暫停專案派工。交付失敗不當作成功領下一張。交付後新工作階段再 claim；無工單進 Idle，等待喚醒或 60 秒對帳。相依仍等 Done／Released。

### 獨立關卡

Developer、Verifier、Reviewer 必須可信 identity 與 session 各異，不共用對話；本規劃工作階段不算任何工單驗收。Verifier 不改產品。Review 與 acceptance 通過後由授權人／高階角色確認，且 PR 必須已合併才設 Done／Blue。

所有驗證綁定候選 tree 和 commit；PR 更新使證據失效。Squash merge 以可信 tree 對應與必要的 merge 後回歸連結驗證；不能要求 squash 前後 commit SHA 相同，也不能只憑 PR merged 就沿用不同 tree 的證據。

## UI schema

管理者：enabled=false、notBefore=null、timezone=Asia/Taipei、intervalSec=60、maxConcurrent=1（第一階段固定）、dispatchMode=legacy。開始時間必須含時區；間隔在範圍內；儲存失敗保留舊值。唯讀角色控制停用並顯示原因。

Webhook：targetRunnerId、allowlisted endpoint、key reference、重試唯讀摘要、測試投遞。秘密不回顯；test event 僅檢查接收健康，不加入正式工作。

執行頁：ticket/run/event/completion IDs、checkout、程序／交付／驗收分開顯示，Idle／Offline／Paused／Quarantined 明確；空資料不顯示成功。關卡顯示可信角色及 PR tree；不可操作項有原因。使用 label、鍵盤焦點、aria-live 錯誤訊息；不用顏色當唯一狀態訊號。

本階段不重設既有介面視覺，沿用目前管理面板表單。外部成熟產品 UX 對照與互動原型待 UI 詳細設計工單，尚未聲稱完成外部研究。

## 里程碑與發布

M0：詳細規格／port 簽章／scope／fixture／可執行骨架確認，逐工單有效 RED，正式看板匯入；目前未達成。
M1：SCH/WH/RUN/CMP focused 與 module contract GREEN；M2：治理與整合獨立驗收；M3：Windows 真機恢復測試與相容性報告。

Sprint 候選：Sprint A SCH/WH/RUN-01；B RUN-02/03/CMP；C GOV/RUN-04/UI/INT。未指定日期與人力，不承諾一個 Sprint 完成所有工作。Story points 需團隊校準；Task 只填工時。

版本預計 Minor，精確版本待現行 release baseline 確認。預設停用；Staging RC → 獨立驗收 → 授權發布。回滾先停排程與投遞、drain／隔離程序、保存 journal、切回 legacy；不得丟棄 inbox 或直接重播全部事件。Packaging、silent install、DCC 對本次文件交付 NOT RUN／不適用；未來 Windows Runner 包裝另開工單。

## 後續關卡與 pending automation

1. 確認詳細 API、fencing、儲存格式／鎖、錯誤模型、實體檔案與相容性策略。
2. 選擇專案測試框架並建可編譯 Skeleton；將 step-stubs.json 綁定到真實測試。未綁定必須拒絕執行，不算 skip 或通過。
3. 每個情境記錄 valid RED，再凍結 implementation envelope；目前沒有有效 RED。
4. 在正確 GuGuBoard 專案建立 Epic → Feature → Story → Task；目前 plan-index.json 不是 board.json 匯入檔。
5. 獨立代理驗證／審查與正式核准，最後才可放行實作。

重建：`python docs/dispatch-plan/build_plan.py`。文件檢查：`python docs/dispatch-plan/validate_plan.py`。此命令只檢查文件完整性，絕不證明產品行為。


## 2026-11-07 可執行驅動與有效 RED

使用者核准的範圍仍限測試，沒有產品實作授權。其餘 45 項已有故障、並行、恢復、HTTP 與真瀏覽器驅動；連同 SCH-01 共 48 項。正式執行結果見 red/driver-evidence/all.json，人類逐項報告見 red/driver-evidence/report.html；證據資格由 red/qualify_evidence.py 檢查。

RED 針對未實作的測試骨架：缺少 Port 編排、持久化效果、租約／交付流程或介面投影，並非已完成產品的驗收。故障控制設備已真正命中；骨架未達故障點時另列 missingFaultPaths，不宣稱回滾／重試已實測。九個瀏覽器案例操作測試 HTML，不是產品 UI。產品程式、原 Skeleton、BDD、hooks、CI、Git index 與正式看板不變。

獨立測試品質審查、獨立驗收、架構 conformance、正式工單匯入及產品 implementation envelope 仍未完成。readyForImplementation 保持 false。細節、工具版本、執行命令與測試設備修正見 red/README.md 和 red/HARNESS-LESSONS.md。
