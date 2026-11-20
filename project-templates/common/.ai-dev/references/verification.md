# 驗證與審查細則

> 何時讀：擔任實測代理或審查代理時。

## 怎麼測
1. **先讀懂再測**：讀工單、`bdd[]` 情境與測試清單，列出要驗的行為、邊界與錯誤情境，決定層級（單元 → 整合 → E2E → 介面實測）。
2. **自己跑、看真實輸出**：重跑專案的測試指令，讀失敗訊息與堆疊。不採信開發代理的「已測過」。
3. **主動找破口**：空值、極大值、非法輸入、重複操作、並發／重入、斷網或逾時、權限不足。沒被測到的情境記為缺漏退回。
4. **確認測試可信**：斷言真的檢查結果、要驗的邏輯沒被 mock 掉；做一次變異測試（刪掉或改壞被測程式，測試要變 Red）。
5. **可重現**：每個 FAIL 附重現步驟、輸入、預期、實際、截圖或日誌。
6. 無法在某平台執行的記 NOT RUN，**不得偽造 PASS**。

## 提問協定
看不懂或可疑的寫法不要猜、不要自己改：在工單備註或 PR 留言寫明檔案、行號、你的理解與疑慮，問「為什麼這樣寫？」。提問期間燈號維持黃燈（「等待開發代理說明」）。理由成立 → 請它補一行白話註解或測試；不成立或答不出 → 退回。問答記入工單備註。

## 審查清單（明顯違反就退回；小問題列建議不擋）
| 面向 | 檢查 | 參考 |
|---|---|---|
| 範圍 | 只改允許範圍的檔案；PR 對應唯一 Task；沒有半成品、TODO 樁、被 skip 的測試 | `planning.md` |
| 架構 | 沒寫死平台路徑／API；沒繞過 Port；沒有無理由的耦合；依賴只由外往內、沒跳層、沒外漏內部型別 | `architecture.md` |
| 寫法 | 命名、函式長度、巢狀、錯誤碼／null、`unwrap`、在服務內 new 依賴、貧血模型、魔法數字、過度設計、越界的童子軍修改 | `clean-code.md` |
| 註解 | 關鍵處有白話的「為什麼」；沒有重述程式、過時、被註解掉的程式、沒工單號的 TODO | `clean-code.md` |
| 上線就緒 | 覆蓋率、整合／E2E、交易邊界、併發鎖、日誌遮罩、錯誤外洩、輸入驗證、權限、SCA 結果 | `testing-data-observability.md`、`security.md` |
| 效能與記憶體 | 複雜度推導、無意外 O(n²)、效能宣稱有前後數字、容量上限、串流、資源釋放、有界佇列 | `performance-memory.md` |
| BDD＋TDD | 追溯表完整；自己重跑涵蓋情境全 Green；有 Red 先於 Green 的證據；沒改情境、沒削弱斷言、沒新增 skip | `bdd-tdd.md` |
| Hook 與 CI | 沒改或停用 `.ai-hooks`、`.githooks`、`.github/workflows`、`.claude/settings.json`（除非工單就是改它且有核准）；`.ai-hooks/logs/hooks.log` 被擋的指令都有交代；沒有 `--no-verify` 痕跡；AI Dev Guard 與 tests 都通過 | `enforcement-and-pitfalls.md` |
| 看板 | 卡片有上層連結、PR 連結、正確分支名；`tdd`／`ci` Green；Task 沒有 Story Point；燈號與實況相符（CI 失敗卻綠燈、黃紅沒原因、匯總錯誤都算不符）；只由對應角色移動 | `board-and-lights.md` |
| 版本 | Conventional Commits；發版時 SemVer、版本檔一致、CHANGELOG；Prod 卡有 `rollbackPlan` 與人的 `approvedBy`；Hotfix 有重現測試與 merge 回預設分支計畫 | `release-deploy.md` |

## 驗收紀錄
寫明開發代理與驗證代理身分（兩者相同 → 無效）、執行的指令與輸出、PASS／FAIL／NOT RUN、證據路徑（截圖、錄影、日誌）。
