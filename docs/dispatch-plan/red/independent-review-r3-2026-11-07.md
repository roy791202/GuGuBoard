# R3 獨立測試品質審查

READY_FOR_AI_IMPLEMENTATION: **NO**。兩軸獨立判斷：測試定義/fixture/斷言品質，與空骨架實際執行證據。

審查者 `/root/independent_red_review` 未參與開發。本次僅新增獲授權R3報告；未改來源、原證據、gate、產品、看板或Git。

## 定義

READY_DEFINITION：本案主要BDD斷言與前提未見阻擋性缺陷；不表示整個Module覆蓋完整。PARTIAL_ASSERTION：仍有已知弱斷言。INVALID_FIXTURE：成功/錯誤原因前提不成立。

SUT另列NEGATIVE_PASS、BEHAVIOR_RED、FAULT_UNREACHED、BLOCKED_UPSTREAM；後兩者不能算產品failure-handling或整合已驗證。

定義品質：{'READY_DEFINITION': 43, 'PARTIAL_ASSERTION': 2, 'INVALID_FIXTURE': 3}
SUT證據：{'NEGATIVE_PASS': 2, 'BEHAVIOR_RED': 37, 'FAULT_UNREACHED': 6, 'BLOCKED_UPSTREAM': 3}

## 實際執行

- TEMP fixture_contract_tests.py:11 PASS
- TEMP signed-ack-script RUN-01-2:PASS
- TEMP renew-script RUN-03-1:PASS
- TEMP completion-commit-script CMP-02-1:PASS, real response loss exercised
- TEMP ui-safe UI-03-1:PASS
- TEMP ui-safe UI-02-3:PASS
- TEMP ui-health-script UI-02-2:PASS
- TEMP completion-commit-script CMP-01-1:INVALID_RED KeyError until
- TEMP independently written wrong next-process owner/gen control RUN-04-1:PASS (surviving defect)
- Independent read-only JSON verifier:48 baseline status/checks consistent,21 paired positive PASS and21 new-assertion kills,15 source hashes/protected hashes match

全部48與21配對控制未由本代理全量重跑；其餘依來源、既有觀察及獨立只讀一致性驗證審查。原證據時間：2026-11-07T01:26:40.699677+08:00

## Findings

### R3-01 P1 CMP-01全部案例共用無效current lease，成功案例無法被安全實作滿足

`run_drivers.py:87`

TEMP run_case(CMP-01-1,factory(completion-commit-script)) => INVALID_RED, error until。fixture lease只有owner/generation；Board Renew/Release current contract要求until>now。

共用setup補until=now+900及相符可信run基線；CMP-01-1加入完整成功交付PASS控制，CMP-01-2/3只變欲驗證之失效欄位。

### R3-02 P2 matching lease不變量未比對active run owner/generation，且可由processStatus文字短路

`review_strengthening.py:44`

TEMP RUN-04-1 control: Claim FIX-2 owner dev-1/g1，Process.Start ticket FIX-2 owner intruder/g999、新session真父孫程序 => 整案PASS。

依真實marker判active，再核ticket/run owner/generation與未過期可信lease；歷史Exited只在實體確實退出時豁免。於RUN-04及integration後重新檢查，新增paired wrong-owner/generation mutant。

### R3-03 P2 租約失效workspace隔離只驗snapshot flag，仍可繞過Workspace port/物理marker

`review_strengthening.py:103`

RUN-03-2兩組失效路徑僅quarantinedWorkspaces[workspace]==True；Store.Commit可直接寫此flag，既不要求Workspace.Quarantine trace，也未驗QUARANTINED檔。RUN-03-3已有物理檔斷言但不覆本案。

在成功stop與失敗stop兩組workspace均驗實體marker與正確workspace port目標；增加只寫flag不隔離的mutant。

## R2十項缺陷閉環

| ID | 狀態 | 說明 |
|---|---|---|
| R2-01 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-02 | PARTIAL | Exited錯殺已修；matching lease owner/gen仍有新可重現漏抓。 |
| R2-03 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-04 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-05 | PARTIAL | 活程序Stop故障前提/hit已修；workspace實體隔離斷言未補。 |
| R2-06 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-07 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-08 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-09 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |
| R2-10 | CLOSED_AT_DEFINITION_LAYER | 原R2具體缺陷已修；subject未實作路徑仍另列，不混為測試錯誤。 |

## 48項逐案（R1/R2閉環與證據分軸）

| ID | 測試定義品質 | SUT證據 | R1/R2閉環 | 獨立判斷 |
|---|---|---|---|
| TDD-SCH-01-1 | READY_DEFINITION | NEGATIVE_PASS | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 合法負向PASS；配對忽略時間mutant能被抓。 |
| TDD-SCH-01-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 唯一持久outbox行為缺失，正向script與reject-all對照成立。 |
| TDD-SCH-01-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 無時區、空值、4/3601及合法5/3600各有明確斷言；配對正向成立。 |
| TDD-SCH-02-1 | READY_DEFINITION | NEGATIVE_PASS | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 合法暫停負向PASS；不再以Store呼叫當RED。 |
| TDD-SCH-02-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 重開只評當下、cursor追上、第二次reconcile不多發的定義合理。 |
| TDD-SCH-02-3 | READY_DEFINITION | FAULT_UNREACHED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 提交payload同時含cursor/outbox，失敗保存與恢復重試定義合理；subject Commit未達。 |
| TDD-WH-01-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | HTTP接收、receipt及tickets不變符合BDD；完整first-send安全矩陣仍屬後續module coverage。 |
| TDD-WH-01-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 有實際timeout peer、錯誤分類、attempt與nextAt；空骨架尚未接觸peer。 |
| TDD-WH-01-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 兩個不允許origin各驗零Http呼叫，加允許目標正向配置；可信policy不由client自行指定。 |
| TDD-WH-02-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 實際wire bytes、HMAC、timestamp及宣告10秒timeout斷言合理；physical timeout縮放僅fixture。 |
| TDD-WH-02-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 五次後manual、不再發送的核心負向轉移可觀察。 |
| TDD-WH-02-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 先由subject寫retry再重開；old peer設回ok，固定外部URL合理；subject首次投遞未達。 |
| TDD-RUN-01-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 首次202及同事件200、durable單筆inbox；配對ack控制符合案例範圍。 |
| TDD-RUN-01-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 已修正-300首次202、+300重送200；TEMP signed-ack-script全部PASS。 |
| TDD-RUN-01-3 | READY_DEFINITION | FAULT_UNREACHED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 已保留immutable armed history，滿載原資料完整比較；Store.Commit subject未達。 |
| TDD-RUN-02-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 真claim barrier、獨立trusted contenders、唯一真Process.Start及owner/generation比對；配對wrong-owner mutant成立。 |
| TDD-RUN-02-2 | READY_DEFINITION | FAULT_UNREACHED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | claim/start故障/精確release補償/失敗報告；故障尚未達，不能算failure handling已驗。 |
| TDD-RUN-02-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 空board零lease/process且Idle；正向control及無claim啟動mutant對照成立。 |
| TDD-RUN-03-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | Identity/ledger/lease owner均dev-1；TEMP renew-script PASS，expiry持久更新可觀察。 |
| TDD-RUN-03-2 | PARTIAL_ASSERTION | FAULT_UNREACHED | PARTIAL / PARTIAL | 另起活父孫程序注入Stop失敗，要求hit/stillalive/禁新run；但workspace只驗可由Store偽造的dict，缺物理QUARANTINED或Workspace port斷言。 |
| TDD-RUN-03-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 停止舊父孫、實體quarantine、後續新workspace/session及PID mismatch保護已有定義；這些深層步驟baseline尚未到達。 |
| TDD-CMP-01-1 | INVALID_FIXTURE | BEHAVIOR_RED | OPEN_REGRESSION / OPEN_NEW | fixture current lease缺until，正確completion-commit-script在TEMP KeyError until；安全實作視為LeaseLost，不能滿足成功前提。 |
| TDD-CMP-01-2 | INVALID_FIXTURE | BEHAVIOR_RED | OPEN_REGRESSION / OPEN_NEW | 共用缺until的無效lease，與欲單測證據缺漏同時失效，沒有規格宣告錯誤優先順序；需先確立有效lease再驗Validation。 |
| TDD-CMP-01-3 | INVALID_FIXTURE | BEHAVIOR_RED | OPEN_REGRESSION / OPEN_NEW | 共用缺until的無效lease，遮蔽錯generation/版本/身分的特定拒絕原因；需合法基線。 |
| TDD-CMP-02-1 | READY_DEFINITION | FAULT_UNREACHED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 已補有效相符lease/status；TEMP completion-commit-script通過真postcommit斷線及replay receipt/history斷言；baseline fault仍0。 |
| TDD-CMP-02-2 | READY_DEFINITION | FAULT_UNREACHED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 保留ReviewUpdated journal和有效lease；Release中斷與重開恢復定義合理；subject fault仍0。 |
| TDD-CMP-02-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 相同ID不同有效evidence/digest，完整快照保持與Conflict；未改expected以過關。 |
| TDD-RUN-04-1 | PARTIAL_ASSERTION | BEHAVIOR_RED | PARTIAL / PARTIAL | 真父孫程序/新session檢查已補，但TEMP控制以lease dev-1/g1啟動intruder/g999仍整案PASS；matching lease不變量不足。 |
| TDD-RUN-04-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 相依未完成不得Claim/lease/start，Idle與無dependent lease皆有斷言。 |
| TDD-RUN-04-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 未知completion的durable reconciliation及零lease/no new run符合核心行為。 |
| TDD-GOV-01-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | trusted ledger/session比較與forged client欄位拒絕；有PASS反向control，非client身分自證。 |
| TDD-GOV-01-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 保存verification且tree/session綁可信run、不自動完成；目前缺保存行為。 |
| TDD-GOV-01-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 持久grants完整比較；改用格式合法c*40不同tree，排除僅格式拒絕。 |
| TDD-GOV-02-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 各verification/review/authority/merge缺失及tree不符分別拒絕；principal與grants同步。 |
| TDD-GOV-02-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 完整trusted gate records正向，Done/Blue及matching tree history斷言；仍非真Git服務驗收。 |
| TDD-GOV-02-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 其他gate合格後只變可信actor/role/noApprove，session同步可信principal，完整snapshot不變。 |
| TDD-UI-01-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 預設停用/並行1可讀；readonly是test adapter本身行為，不能移算產品UI。 |
| TDD-UI-01-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 欄位notBefore與具體提示、保留設定；當前缺view/validation實作。 |
| TDD-UI-01-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | viewer-1有一致roleGrant/session，exact reason及繞UI直接API拒絕/全state不變；配對正向PASS。 |
| TDD-UI-02-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | wire response text與完整HTML均檢secret；hidden-secret mutant被抓；不等於產品logs/storage安全。 |
| TDD-UI-02-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 真正受控HTTP到AcceptWakeup、testEvent bytes、exact OK及無inbox/lease/run；TEMP ui-health-script PASS。 |
| TDD-UI-02-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 種due pending事件，paused/unpaused同runnerOnline條件；真click持久化，兩個mutants分別抓no-op pause/忽略pause；TEMP正向PASS。 |
| TDD-UI-03-1 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | Exited歷史不再錯套租約；TEMP ui-safe正確顯示PASS，Running顯示mutant被抓。 |
| TDD-UI-03-2 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | exact PR_NOT_MERGED、disabled與直接Approve拒絕/全state不變；配對wrong-reason控制成立。 |
| TDD-UI-03-3 | READY_DEFINITION | BEHAVIOR_RED | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 空說明且不顯成功的核心觀察合理；baseline缺空說明。 |
| TDD-INT-01-1 | READY_DEFINITION | BLOCKED_UPSTREAM | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 真outbox→wire bytes→ingress→inbox，各失敗stage停止；不再補造事件；baseline止於scheduler。 |
| TDD-INT-01-2 | READY_DEFINITION | BLOCKED_UPSTREAM | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 真run marker正常exit、由ledger/lease取completion身分，postcommit loss/reopen設計合理；baseline止於scheduler，下游未驗。 |
| TDD-INT-01-3 | READY_DEFINITION | BLOCKED_UPSTREAM | CLOSED_AT_DEFINITION_LAYER / CLOSED_AT_DEFINITION_LAYER | 獨立可信角色操作後Done與Blue及FIX-3開始均有斷言；baseline止於scheduler，不得移算全鏈路驗證。 |

## 進入實作前缺口

1. 先修CMP-01有效lease共用前提並新增該成功案PASS控制，防空骨架繼續掩蓋壞fixture。
2. 強化active run與lease owner/generation/fencing，以及兩種lost-stop workspace實體隔離斷言及配對mutants。
3. FAULT_UNREACHED與整合blocked保持明列。設備control的hit不可移算subject hit；READY_DEFINITION不要求空骨架先變產品，但不支持宣稱故障恢復已驗。
4. 產品Skeleton、Ports、交易/錯誤契約與productionAllowed仍未凍結，架構與實作核准未完成；任何測試控制PASS不構成產品授權。
5. 產品UI/真Adapter/完整AI CLI程序樹/安裝與回歸另依獨立驗收流程執行。
