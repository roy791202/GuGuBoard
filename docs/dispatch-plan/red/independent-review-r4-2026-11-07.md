# R4 獨立審查與工單重新確認

結論：**測試定義/fixture/斷言修補 PASS_WITH_DOCUMENTATION_GAPS；READY_FOR_AI_IMPLEMENTATION = NO**。

審查者 `/root/independent_red_review` 未參與本批開發。僅新增本報告與JSON；未修改原測試/規格/產品/證據/gate/看板/Git。

## 兩軸結果

- 48項：READY_DEFINITION=48，表示本次指定案例定義層未發現新阻擋性缺陷，不等於完整Module所有契約已覆蓋。
- 原空骨架：2 PASS /46 BEHAVIOR_RED /0 INVALID；其中6案故障未達、3案整合在scheduler阻擋。
- 原證據25配對正向PASS與25新增失敗mutation kill，已獨立只讀重算；未把控制靶hit移算subject hit。
- R3三項已閉環，並有本代理TEMP實際重現。

## 實際執行與限制

- TEMP fixture_contract_tests.py:12 tests PASS in9.833s
- TEMP CMP-01-1 completion-commit-script:PASS
- TEMP CMP-01-1 completion-missing-history:BEHAVIOR_RED solely delivery history assertion
- TEMP RUN-04-1 next-job-script:PASS
- TEMP RUN-04-1 wrong owner/generation/expired lease:3 BEHAVIOR_RED at execution authority assertion
- TEMP independent LostStopControl physical=True:PASS;physical=False:RED at two physical marker assertions;both controls Renew hit2/Stop hit1
- Independent read-only audit:16 tickets,48 BDD/test bindings,DAG acyclic,index/task identity/status/estimate/scope/fixture files all consistent
- Independent read-only evidence recalculation:48 status/checks,25 paired positive PASS/25 mutant new failures,15 source hashes/protected hashes match

完整48與全25配對控制未由本代理全量重跑；原R4證據時間：2026-11-07T01:40:11.675203+08:00。產品/安裝UI/真CLI/整合驗收均未執行。

## R3缺陷閉環

| 項目 | 獨立動態結果 |
|---|---|
| CMP01有效lease/history | 成功控制PASS；漏history控制只因history斷言RED |
| RUN04可信owner/gen/expiry | 正向PASS；3種錯誤含假Exited投影均被immutable call觀察器抓到 |
| RUN03失效隔離 | 真Workspace隔離PASS；只寫flag控制被2個實體marker斷言抓到；控制Renew2/Stop1 |

## 文件與證據缺口

### R4-DOC-01 P2 關卡入口仍指R3與21個控制，未反映當前R4證據

`gate-status.json:80`、`gate-status.json:121`、`gate-status.json:127`

canonicalEvidence=review-fixes-r3-evidence/all.json，qualityReviewStatus=PENDING_R3，positiveControls/mutantsKilled=21；當前受審R4為25/25。newlyQualifiedCases=45與qualifiedBehaviorRED=[]亦未說明為歷史欄位。

容易讓人審查錯輪次，屬文件關卡缺口；readyForImplementation=false維持安全，不是產品故障。

### R4-DOC-02 P2 README與validator結果仍指向原driver-evidence舊證據

`../README.md:100`、`README.md:3`、`../validation.json:8`、`../validate_plan.py:32`

兩README稱driver-evidence/all.json/report.html為正式結果，validation.json與其生成來源亦連舊目錄；該輪曾有INVALID_RED分類缺陷。

需由文件責任者統一current evidence指標並標歷史輪次；本審查不擅自修改。

### R4-DOC-03 P3 12個fixture unittest原始stdout未見獨立持久檔

`review-fixes-r4-evidence/all.json:1`

all.json內fixtureControls是selftest摘要，不等於12個unittest完整輸出；本代理TEMP已獨立重跑12/12 PASS，因此目前品質判斷有實際依據，但原標準入口完整stdout仍宜保存。

不將缺原stdout判作fixture測試失敗；保留可重現性限制。

## 16張工單重新確認

plan-index與16份ticket JSON一對一；各有唯一Story及3個BDD/test ID，合計48，與R4 evidence完全相符。未發現循環或不存在的相依。估算使用hours，合計112小時；未將估算當交付承諾。全部Backlog/Gray、tdd Red、CI NOT RUN，productionAllowed均空；allowedNow僅文件範圍且檔案存在。這是文件工單，正式board import不在本次驗證範圍。

| 工單 | Module | Story | 小時 | 相依 | R4測試結果 | 工單狀態/範圍 |
|---|---|---|---:|---|---|---|
| SCH-01 | dispatch-scheduling | S-SCH-01 | 6 | 無 | {'PASS': 1, 'BEHAVIOR_RED': 2} | Backlog/Gray；productionAllowed=[] |
| SCH-02 | dispatch-scheduling | S-SCH-02 | 6 | SCH-01 | {'PASS': 1, 'BEHAVIOR_RED': 2} | Backlog/Gray；productionAllowed=[] |
| UI-01 | dispatch-scheduling | S-UI-01 | 6 | SCH-02 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| WH-01 | webhook-delivery | S-WH-01 | 6 | SCH-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| WH-02 | webhook-delivery | S-WH-02 | 6 | WH-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| UI-02 | webhook-delivery | S-UI-02 | 6 | WH-02, RUN-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| RUN-01 | ai-runner | S-RUN-01 | 8 | 無 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| RUN-02 | ai-runner | S-RUN-02 | 8 | RUN-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| RUN-03 | ai-runner | S-RUN-03 | 8 | RUN-02 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| RUN-04 | ai-runner | S-RUN-04 | 6 | CMP-02, RUN-03 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| CMP-01 | work-completion | S-CMP-01 | 8 | RUN-02 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| CMP-02 | work-completion | S-CMP-02 | 8 | CMP-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| GOV-01 | verification-approval | S-GOV-01 | 8 | 無 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| GOV-02 | verification-approval | S-GOV-02 | 8 | GOV-01 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| UI-03 | verification-approval | S-UI-03 | 6 | GOV-02, CMP-02 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |
| INT-01 | dispatch-integration | S-INT-01 | 8 | RUN-04, GOV-02, UI-03, UI-02 | {'BEHAVIOR_RED': 3} | Backlog/Gray；productionAllowed=[] |

一個合法拓撲順序：`SCH-01 → SCH-02 → UI-01 → WH-01 → WH-02 → RUN-01 → UI-02 → RUN-02 → RUN-03 → CMP-01 → CMP-02 → RUN-04 → GOV-01 → GOV-02 → UI-03 → INT-01`。所有task的BDD結果與R4結果一致，沒有發現負向PASS仍被ticket寫RED。

## 48項逐案（定義與SUT證據分軸）

| ID | 定義品質 | SUT證據 | 獨立判斷 |
|---|---|---|---|
| TDD-SCH-01-1 | READY_DEFINITION | NEGATIVE_PASS | 合法負向PASS；配對忽略時間mutant能被抓。 |
| TDD-SCH-01-2 | READY_DEFINITION | BEHAVIOR_RED | 唯一持久outbox行為缺失，正向script與reject-all對照成立。 |
| TDD-SCH-01-3 | READY_DEFINITION | BEHAVIOR_RED | 無時區、空值、4/3601及合法5/3600各有明確斷言；配對正向成立。 |
| TDD-SCH-02-1 | READY_DEFINITION | NEGATIVE_PASS | 合法暫停負向PASS；不再以Store呼叫當RED。 |
| TDD-SCH-02-2 | READY_DEFINITION | BEHAVIOR_RED | 重開只評當下、cursor追上、第二次reconcile不多發的定義合理。 |
| TDD-SCH-02-3 | READY_DEFINITION | FAULT_UNREACHED | 提交payload同時含cursor/outbox，失敗保存與恢復重試定義合理；subject Commit未達。 |
| TDD-WH-01-1 | READY_DEFINITION | BEHAVIOR_RED | HTTP接收、receipt及tickets不變符合BDD；完整first-send安全矩陣仍屬後續module coverage。 |
| TDD-WH-01-2 | READY_DEFINITION | BEHAVIOR_RED | 有實際timeout peer、錯誤分類、attempt與nextAt；空骨架尚未接觸peer。 |
| TDD-WH-01-3 | READY_DEFINITION | BEHAVIOR_RED | 兩個不允許origin各驗零Http呼叫，加允許目標正向配置；可信policy不由client自行指定。 |
| TDD-WH-02-1 | READY_DEFINITION | BEHAVIOR_RED | 實際wire bytes、HMAC、timestamp及宣告10秒timeout斷言合理；physical timeout縮放僅fixture。 |
| TDD-WH-02-2 | READY_DEFINITION | BEHAVIOR_RED | 五次後manual、不再發送的核心負向轉移可觀察。 |
| TDD-WH-02-3 | READY_DEFINITION | BEHAVIOR_RED | 先由subject寫retry再重開；old peer設回ok，固定外部URL合理；subject首次投遞未達。 |
| TDD-RUN-01-1 | READY_DEFINITION | BEHAVIOR_RED | 首次202及同事件200、durable單筆inbox；配對ack控制符合案例範圍。 |
| TDD-RUN-01-2 | READY_DEFINITION | BEHAVIOR_RED | 已修正-300首次202、+300重送200；TEMP signed-ack-script全部PASS。 |
| TDD-RUN-01-3 | READY_DEFINITION | FAULT_UNREACHED | 已保留immutable armed history，滿載原資料完整比較；Store.Commit subject未達。 |
| TDD-RUN-02-1 | READY_DEFINITION | BEHAVIOR_RED | 真claim barrier、獨立trusted contenders、唯一真Process.Start及owner/generation比對；配對wrong-owner mutant成立。 |
| TDD-RUN-02-2 | READY_DEFINITION | FAULT_UNREACHED | claim/start故障/精確release補償/失敗報告；故障尚未達，不能算failure handling已驗。 |
| TDD-RUN-02-3 | READY_DEFINITION | BEHAVIOR_RED | 空board零lease/process且Idle；正向control及無claim啟動mutant對照成立。 |
| TDD-RUN-03-1 | READY_DEFINITION | BEHAVIOR_RED | Identity/ledger/lease owner均dev-1；TEMP renew-script PASS，expiry持久更新可觀察。 |
| TDD-RUN-03-2 | READY_DEFINITION | FAULT_UNREACHED | 兩組Stop成功/失敗皆驗QUARANTINED實體檔；獨立真Workspace控制PASS、只寫flag控制由兩檔案斷言抓到。 |
| TDD-RUN-03-3 | READY_DEFINITION | BEHAVIOR_RED | 停止舊父孫、實體quarantine、後續新workspace/session及PID mismatch保護已有定義；這些深層步驟baseline尚未到達。 |
| TDD-CMP-01-1 | READY_DEFINITION | BEHAVIOR_RED | 共用有效lease until已補；TEMP completion-commit-script PASS，missing-history控制僅history斷言RED。 |
| TDD-CMP-01-2 | READY_DEFINITION | BEHAVIOR_RED | 共用lease基線已有效，證據/測試缺漏維持單獨失效欄位；原invalid fixture缺陷已閉環。 |
| TDD-CMP-01-3 | READY_DEFINITION | BEHAVIOR_RED | 共用lease基線已有效，run/版本/身分各自Conflict原因不再受缺until混淆。 |
| TDD-CMP-02-1 | READY_DEFINITION | FAULT_UNREACHED | 已補有效相符lease/status；TEMP completion-commit-script通過真postcommit斷線及replay receipt/history斷言；baseline fault仍0。 |
| TDD-CMP-02-2 | READY_DEFINITION | FAULT_UNREACHED | 保留ReviewUpdated journal和有效lease；Release中斷與重開恢復定義合理；subject fault仍0。 |
| TDD-CMP-02-3 | READY_DEFINITION | BEHAVIOR_RED | 相同ID不同有效evidence/digest，完整快照保持與Conflict；未改expected以過關。 |
| TDD-RUN-04-1 | READY_DEFINITION | BEHAVIOR_RED | 以immutable Process.Start callerPrincipal/leaseAtCall/clockAtCall核owner/gen/expiry；TEMP正向PASS且錯owner/gen/expiry含假Exited均RED。 |
| TDD-RUN-04-2 | READY_DEFINITION | BEHAVIOR_RED | 相依未完成不得Claim/lease/start，Idle與無dependent lease皆有斷言。 |
| TDD-RUN-04-3 | READY_DEFINITION | BEHAVIOR_RED | 未知completion的durable reconciliation及零lease/no new run符合核心行為。 |
| TDD-GOV-01-1 | READY_DEFINITION | BEHAVIOR_RED | trusted ledger/session比較與forged client欄位拒絕；有PASS反向control，非client身分自證。 |
| TDD-GOV-01-2 | READY_DEFINITION | BEHAVIOR_RED | 保存verification且tree/session綁可信run、不自動完成；目前缺保存行為。 |
| TDD-GOV-01-3 | READY_DEFINITION | BEHAVIOR_RED | 持久grants完整比較；改用格式合法c*40不同tree，排除僅格式拒絕。 |
| TDD-GOV-02-1 | READY_DEFINITION | BEHAVIOR_RED | 各verification/review/authority/merge缺失及tree不符分別拒絕；principal與grants同步。 |
| TDD-GOV-02-2 | READY_DEFINITION | BEHAVIOR_RED | 完整trusted gate records正向，Done/Blue及matching tree history斷言；仍非真Git服務驗收。 |
| TDD-GOV-02-3 | READY_DEFINITION | BEHAVIOR_RED | 其他gate合格後只變可信actor/role/noApprove，session同步可信principal，完整snapshot不變。 |
| TDD-UI-01-1 | READY_DEFINITION | BEHAVIOR_RED | 預設停用/並行1可讀；readonly是test adapter本身行為，不能移算產品UI。 |
| TDD-UI-01-2 | READY_DEFINITION | BEHAVIOR_RED | 欄位notBefore與具體提示、保留設定；當前缺view/validation實作。 |
| TDD-UI-01-3 | READY_DEFINITION | BEHAVIOR_RED | viewer-1有一致roleGrant/session，exact reason及繞UI直接API拒絕/全state不變；配對正向PASS。 |
| TDD-UI-02-1 | READY_DEFINITION | BEHAVIOR_RED | wire response text與完整HTML均檢secret；hidden-secret mutant被抓；不等於產品logs/storage安全。 |
| TDD-UI-02-2 | READY_DEFINITION | BEHAVIOR_RED | 真正受控HTTP到AcceptWakeup、testEvent bytes、exact OK及無inbox/lease/run；TEMP ui-health-script PASS。 |
| TDD-UI-02-3 | READY_DEFINITION | BEHAVIOR_RED | 種due pending事件，paused/unpaused同runnerOnline條件；真click持久化，兩個mutants分別抓no-op pause/忽略pause；TEMP正向PASS。 |
| TDD-UI-03-1 | READY_DEFINITION | BEHAVIOR_RED | Exited歷史不再錯套租約；TEMP ui-safe正確顯示PASS，Running顯示mutant被抓。 |
| TDD-UI-03-2 | READY_DEFINITION | BEHAVIOR_RED | exact PR_NOT_MERGED、disabled與直接Approve拒絕/全state不變；配對wrong-reason控制成立。 |
| TDD-UI-03-3 | READY_DEFINITION | BEHAVIOR_RED | 空說明且不顯成功的核心觀察合理；baseline缺空說明。 |
| TDD-INT-01-1 | READY_DEFINITION | BLOCKED_UPSTREAM | 真outbox→wire bytes→ingress→inbox，各失敗stage停止；不再補造事件；baseline止於scheduler。 |
| TDD-INT-01-2 | READY_DEFINITION | BLOCKED_UPSTREAM | 真run marker正常exit、由ledger/lease取completion身分，postcommit loss/reopen設計合理；baseline止於scheduler，下游未驗。 |
| TDD-INT-01-3 | READY_DEFINITION | BLOCKED_UPSTREAM | 獨立可信角色操作後Done與Blue及FIX-3開始均有斷言；baseline止於scheduler，不得移算全鏈路驗證。 |

## 實作前仍需完成

1. 統一current evidence/gate/README/validator metadata並標記舊輪次；本次未擅自修文件。
2. 凍結產品Skeleton、Port簽章、錯誤/儲存/交易契約、允許產品檔案與回歸命令，再取得明確架構/實作授權。16工單productionAllowed=[]仍禁止開始產品實作。
3. 空骨架故障未達與整合上游阻擋維持明列；未來實作後須先證明subject hit，再驗補償/恢復，不能用控制靶代替產品驗收。
4. Module完整契約覆蓋/真Adapter/UI/完整CLI程序樹/安裝與系統回歸依後續獨立驗收執行。
