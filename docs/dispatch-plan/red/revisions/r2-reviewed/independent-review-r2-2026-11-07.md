# 獨立測試品質審查 R2 — 2026-11-07

READY_FOR_AI_IMPLEMENTATION: **NO**。本報告是測試準備品質審查，不是產品驗收。

審查者：`/root/independent_red_review`，未參與本批測試/產品開發。本次僅新增此報告與對應JSON。未修改原測試、證據、gate、產品、看板或Git。

## 判定定義

- VALID_NEGATIVE_PASS：禁止副作用情境可由安全no-op合法通過，且有反向mutant。
- VALID_RED：目前缺失行為直接對應BDD，測試主要斷言未發現不合理要求；不等同完整契約覆蓋。
- BLOCKED_PATH：上游/故障未達，測試方向合理但後段資格未成立。
- PARTIAL_TEST：補強部分成立，仍有弱斷言/可信前提/未覆蓋Then。
- INVALID_TEST：錯誤預期或互相矛盾fixture會拒絕正確實作。

{'VALID_NEGATIVE_PASS': 2, 'VALID_RED': 24, 'BLOCKED_PATH': 10, 'PARTIAL_TEST': 8, 'INVALID_TEST': 4}

## 實際執行

- TEMP fixture_contract_tests.py:7 PASS
- TEMP correct signed/dedup ControlBinding on RUN-01-2: wrong expected202 reproduced
- TEMP correct Exited/Unknown View on UI-03-1: false lease invariant reproduced
- TEMP corrected full-sequence reopen HTTP:202, oldPeer1/newPeer0; initial incomplete timeout probe withdrawn
- TEMP SCH-01 baseline:1 PASS/2 BEHAVIOR_RED/0 INVALID;3 mutation controls killed;2 paired positive controls PASS;exit1 expected baseline RED

完整48與16mutants僅查既有證據和來源，未獨立重跑全部。12來源hash已逐一比對一致。fixture PASS不移算為subject故障處理證據。

更正：先前WH-02-3獨立probe漏oldPeer.http_mode=ok；完整序列已重現202。撤回port變動/timeout缺陷，不以此判失敗。

## Findings

### R2-01 P1 正確簽章去重控制被202期望錯殺

`review_strengthening.py:76` — 同eventId/body在-300已接受，+300應200。TEMP獨立正確signed-dedup控制只有此斷言失敗。

### R2-02 P1 Exited歷史run被誤當活程序要求lease

`review_strengthening.py:42` — UI-03-1正確顯示Exited/Unknown的TEMP控制只因該全域assert失敗。亦只查ticket key存在，沒有owner/generation/expiry matching；在integration前執行，未檢integration產生的run。

### R2-03 P1 RUN-03有效租約前提身分不一致

`run_drivers.py:79` — lease owner worker，但Identity與可信runLedger owner dev-1。正確使用可信principal續租將LeaseLost。

### R2-04 P1 CMP-02-1沒有當前有效lease的成功交付前提

`run_drivers.py:96` — World leases預設空；首次response_loss前僅payload/ledger，正確fenced SubmitCompletion應拒絕，不能到達postcommit fault。

### R2-05 P2 Stop失敗測在預期已停完的程序，缺故障hit斷言

`review_strengthening.py:99` — 應以另一組活程序/孫程序安排Stop失敗，驗仍存活、隔離與禁止領單；當前Stop fault未要求reached=1。

### R2-06 P2 Pause之後發送測試沒有任何待投遞事件

`run_drivers.py:156` — default outbox=[]，DeliverPending零HTTP不能證明paused gate有效；ui-safe control任意return Paused也會過。

### R2-07 P2 過期租約仍可Renew/Release

`driver_support.py:111` — fake只核owner/generation，未核until；fixture測試只驗新owner claim後舊generation被擋，未驗過期但尚未reclaim之續租。

### R2-08 P2 integrated ingress無成功gate且completion身份仍部分固定

`review_strengthening.py:153` — 即使inbox空仍RunNext；payload仍由固定completion()帶developer/session，leaseGeneration取舊ledger而非權威claim；INT-01-3未驗Blue。

### R2-09 P2 8個mutant沒有配對PASS正向控制，無法揭露錯殺

`mutation_controls.py:61` — new failure相對no-op RED可證明某個安全斷言能抓故意錯誤，不能證明整個case可被正確實作滿足；獨立新控制已發現兩個錯殺。

### R2-10 P3 mutation qualification採信killed與newlyFailedAssertions欄位

`qualify_review_fixes.py:22` — 未重算配對checks差集、控制status/check自洽與evidence lineage；未比對report red/passed/invalid總數是否與results一致。

## 48項逐案與R1 closure

| ID | R2判定 | R1補強 | 實際原因/觀察 | 故障 | 尚需補強 |
|---|---|---|---|---|---|
| TDD-SCH-01-1 | VALID_NEGATIVE_PASS | CLOSED | 原不產生事件與程序均PASS；time-ignore-boundary mutant使新增副作用失敗 | 無 | 保留到期正向對照 |
| TDD-SCH-01-2 | VALID_RED | CLOSED | outbox仍0，直接缺少唯一持久派工意圖 | 無 | 補revision/CAS與重開去重 |
| TDD-SCH-01-3 | VALID_RED | CLOSED | 已分時區、空值、4/3601及5/3600；缺Validation與有效邊界保存 | 無 | 補null/型別與合法值成功語意 |
| TDD-SCH-02-1 | VALID_NEGATIVE_PASS | CLOSED | 暫停無副作用PASS；移除強制Store讀取 | 無 | 保留unpaused正向控制 |
| TDD-SCH-02-2 | VALID_RED | CLOSED | 缺當下評估與cursor；已驗二次reconcile不再補發 | 無 | 補revision切換 |
| TDD-SCH-02-3 | BLOCKED_PATH | PARTIAL | 故障未命中；新transaction payload與恢復重試斷言已加 | Store.Commit=0 | 以有效提交路徑證明故障與回滾，不把no-op保留快照當完成 |
| TDD-WH-01-1 | VALID_RED | CLOSED | 缺HTTP接收與durable receipt；完整tickets不變已驗 | 無 | 補first delivery實際簽章/bytes |
| TDD-WH-01-2 | BLOCKED_PATH | PARTIAL | 未接觸timeout peer；新增error/attempt/nextAt符合方向 | timeout未達 | 正向HTTP timeout流程通過後才判failure handling |
| TDD-WH-01-3 | PARTIAL_TEST | PARTIAL | 可信allowlist改良；第二localhost請求後未再驗Http零呼叫；首錯誤origin可被fixture錯誤掩蓋 | 無 | 每個拒絕輸入後獨立驗無transport及完整snapshot；加允許目標正向 |
| TDD-WH-02-1 | VALID_RED | CLOSED | 缺重試HTTP；已驗wire body/HMAC/current timestamp/deadline | 無 | 補完整10/30/120/300退避及HTTP分類 |
| TDD-WH-02-2 | VALID_RED | CLOSED | 缺人工處理持久狀態 | 無 | 補4到5次失敗轉移與人工可讀理由 |
| TDD-WH-02-3 | BLOCKED_PATH | PARTIAL | subject尚未寫retry；恢復前提未達；原外部peer設回ok合理 | timeout未達 | 以subject實寫retry後完整重開流程驗證；撤回port變動即缺陷說法 |
| TDD-RUN-01-1 | VALID_RED | CLOSED | 缺durable inbox及首次202；事件ack正向控制PASS | 無 | 補同ID不同digest409與並發/重開去重 |
| TDD-RUN-01-2 | INVALID_TEST | OPEN | 同evt-1/body在-300已接受，+300重送應200卻硬期望202；獨立正確控制被錯殺 | 無 | 各邊界用新ID或按既有去重狀態期望200；補正確簽章+去重正向控制 |
| TDD-RUN-01-3 | BLOCKED_PATH | PARTIAL | Commit仍0；faultArmedHistory已保留且滿載內容完整比較 | Store.Commit=0 | 拆分保存/滿載；在拒絕後驗完整authoritative snapshot與無lease/run |
| TDD-RUN-02-1 | PARTIAL_TEST | PARTIAL | 真claim seam barrier與owner/generation已驗；仍未比對owner是贏家的trusted principal | 無 | 故意錯claim owner也同步錯start owner的mutant必殺；驗租約owner對Identity |
| TDD-RUN-02-2 | BLOCKED_PATH | PARTIAL | Start故障未命中；補claim、報告與精確補償參數方向正確 | Process.Start=0 | 驗claim成功回執後start失敗；補報告內容/錯誤分類而非任意非空reports |
| TDD-RUN-02-3 | VALID_RED | CLOSED | 空board無lease/process；Idle缺失；fake已拒絕missing | 無 | 保留有票正向控制 |
| TDD-RUN-03-1 | INVALID_TEST | OPEN | fixture lease owner=worker；Identity與runLedger owner=dev-1；有效持有租約前提矛盾 | 無 | 統一可信principal/ledger/lease；299/300邊界與過期續租控制 |
| TDD-RUN-03-2 | BLOCKED_PATH | PARTIAL | 續租故障/停止未達；新增descendant及workspace狀態；Stop failure在預期成功停止後才注入 | Board.Renew=0;Process.Stop=0 | 獨立活程序tree注入Stop失敗；明確hit與still-alive，驗隔離檔與禁止重領 |
| TDD-RUN-03-3 | PARTIAL_TEST | PARTIAL | 重開查Inspect與舊程序/孫程序退出已補；未驗工作區實際隔離及其後可安全重啟 | 無 | PID reuse/建立時間不符；工作區marker；停舊後可新跑的正向控制 |
| TDD-CMP-01-1 | VALID_RED | CLOSED | 缺journal、review、release；exact payload/Confirmed/tdd/history已加 | 無 | 驗history內容、READY_FOR_TDD/版本與不可改舊歷史 |
| TDD-CMP-01-2 | VALID_RED | CLOSED | 單獨缺tests/evidence及失敗統計、missing evidence均拒絕；完整snapshot有效 | 無 | 補有效URI但digest錯、UNKNOWN/零測試、PR或理由 |
| TDD-CMP-01-3 | VALID_RED | CLOSED | 各錯ticket/run/project/developer/SHA/tree分開拒絕 | 無 | 補trusted session與cross-project evidence |
| TDD-CMP-02-1 | INVALID_TEST | OPEN | 首次SubmitCompletion前leases為空；正確檢查有效當前租約將拒絕，response-loss前提不可滿足 | Completion.ResponseAfterCommit=0 | 種相符有效lease/status/run後再測post-commit response loss；新回執必非空 |
| TDD-CMP-02-2 | BLOCKED_PATH | PARTIAL | Release fault0；已補不重複review update及恢復release次數 | Board.Release=0 | 首輪失敗後必檢stage/lease/禁止下一張；成功release須驗回應非只call數 |
| TDD-CMP-02-3 | VALID_RED | CLOSED | 有效替代evidence/digest已改；缺Conflict，完整原快照比較 | 無 | 以兩份已驗證合法payload正向控制確認衝突原因 |
| TDD-RUN-04-1 | VALID_RED | CLOSED | FIX-2/新非空session缺失；原task仍review | 無 | 驗真正隔離checkout/可信新session |
| TDD-RUN-04-2 | VALID_RED | CLOSED | no-dependent-lease/Claim已加；Idle缺失 | 無 | 前置Done後可claim對照 |
| TDD-RUN-04-3 | VALID_RED | CLOSED | 新增durable reconciliation與無lease；目前缺回報及對帳 | 無 | 驗恢復成功後可繼續 |
| TDD-GOV-01-1 | VALID_RED | CLOSED | 有trusted run ledger與forged client identity拒絕；Unauthorized缺失 | 無 | 三身分/session交叉矩陣與identity-read控制 |
| TDD-GOV-01-2 | VALID_RED | CLOSED | 缺verification；新增trusted tree/session綁定 | 無 | 驗完整證據資料/實測FAIL不得當PASS |
| TDD-GOV-01-3 | PARTIAL_TEST | PARTIAL | 持久roleGrants與wrong tree已驗；wrong-tree是格式無效字串，未排除僅格式拒絕 | 無 | 用格式正確但不相符tree；三角色各異/覆寫grants mutant |
| TDD-GOV-02-1 | VALID_RED | CLOSED | 改trusted verification/review/PR records；逐gate及tree mismatch拒絕 | 無 | 證據過期/跨專案/PR更新失效控制 |
| TDD-GOV-02-2 | VALID_RED | CLOSED | 缺Done/Blue與history；已驗matching merged tree | 無 | 必驗獨立trusted來源與完整history/revision/time，不能只非空 |
| TDD-GOV-02-3 | PARTIAL_TEST | PARTIAL | 補齊all gates後反向授權；但dev-agent可信Identity與既有human roleGrant混合需明確authority來源 | 無 | 使每案trusted principal與roleGrant/session一致，另測forged client role無效 |
| TDD-UI-01-1 | VALID_RED | CLOSED | 缺concurrency預設；readonly由test HTML固定提供 | 無 | 固定UI行為只算adapter證據，產品DOM另驗 |
| TDD-UI-01-2 | VALID_RED | CLOSED | 欄位識別與notBefore文字已加；缺錯誤結果 | 無 | 完整state、焦點/aria、合法提交正向 |
| TDD-UI-01-3 | PARTIAL_TEST | PARTIAL | exact理由與強制API拒絕完整snapshot已補；actor human-1的grant仍admin但Identity role viewer | 無 | 明確一致的可信viewer grant/session；不能逼實作信任矛盾來源 |
| TDD-UI-02-1 | VALID_RED | CLOSED | 回應text+完整HTML檢secret，hidden leak mutant被殺；缺key顯示 | 無 | 產品logs/localStorage/其他endpoint另驗 |
| TDD-UI-02-2 | PARTIAL_TEST | PARTIAL | 驗無inbox/lease/run；仍只有任意非空health與HTTP次數 | 無 | 捕捉test event bytes/schema並實際到Runner health-only入口；精確健康結果 |
| TDD-UI-02-3 | PARTIAL_TEST | PARTIAL | Pause真click/持久paused已補；但DeliverPending時outbox為空，所以零發送斷言vacuuous | 無 | 種一筆due pending且unpaused對照能送；pause後不得送，pause-ignore-delivery mutant必殺 |
| TDD-UI-03-1 | INVALID_TEST | OPEN | Exited歷史run被全域running-job-lease斷言錯殺；獨立正確View控制只有此assert失敗 | 無 | 只對active實際工作驗租約，歷史Exited/Unknown不可要求仍持租約；加正確View控制 |
| TDD-UI-03-2 | VALID_RED | CLOSED | exact reason及強制完成命令拒絕/完整state已補 | 無 | 產品server可信認證另驗 |
| TDD-UI-03-3 | VALID_RED | CLOSED | 缺空狀態；無成功訊息有效 | 無 | 無假run與aria success對照 |
| TDD-INT-01-1 | BLOCKED_PATH | PARTIAL | 停止人工補事件，scheduler無event即block；下游尚不可達 | scheduler到delivery阻擋 | 各成功上游stage傳遞真輸出；ingress失敗要阻止RunNext；completion身份全部取實run |
| TDD-INT-01-2 | BLOCKED_PATH | PARTIAL | scheduler阻擋；postcommit disconnect與恢復碼存在但未執行 | scheduler到delivery阻擋 | 獨立composition正向控制到fault；驗duplicate不再啟動/ack/唯一history |
| TDD-INT-01-3 | BLOCKED_PATH | PARTIAL | scheduler阻擋；已加FIX-3後續start，但漏原Then Blue及完整可信角色綁定 | scheduler到delivery阻擋 | 下游正向控制；驗Done和Blue皆成立、驗收前FIX-3零claim與有效gate回執 |

## 實作前缺口

1. 修復R2-01至R2-04錯誤預期/前提，對正確signed-dedup、Exited UI、有效lease renewal、有效completion各有PASS控制。
2. 補活程序Stop failure、pending事件Pause gate、真ingress→run成功gate與最終Blue，加入會違反這些規則的mutant。
3. 對BLOCKED_PATH保留未達狀態；空骨架不命中不等於fixture品質失敗，也不能升格failure-handling qualified。
4. 補齊可信principal/roleGrant/lease/ledger一致性、過期fencing與mutation evidence自洽。
5. 凍結產品Skeleton、Port簽章/錯誤/交易契約及productionAllowed scope，再經架構和使用者核准。現有test-only控制不授權產品實作。
