# BDD + TDD 細則

> 何時讀：寫情境、列測試清單、寫測試、或檢查測試證據時。

## 分工（D5）
| 階段 | 誰 | 產出 |
|---|---|---|
| 預製期 | 高階模型，使用者核准 | Story 的 BDD 情境（寫進 board.json `bdd[]`，D2）＋人類可讀 `.feature.txt`；每個情境的**測試清單與斷言規格**（名稱、層級、輸入、預期、fixtures、介面實測步驟） |
| 實作期 | 開發代理 | 依規格寫**測試程式碼**，跑出有效 RED，再實作到 GREEN |
| 驗收期 | 獨立驗證代理 | 重跑、補破口測試、確認測試可信 |

## 情境
- 情境 ID：`<Story ID>-<序號>`（例 `S-12-1`、`S-GOV-1-1-6`）。
- 每個 Story 要含正常、負向（錯誤輸入、依賴失效）、邊界值、安全（越權、注入）情境；只寫可觀察行為，不寫實作細節。
- `.feature` 範本：`docs/ai-dev-skills/templates/story.feature.template`；落地位置 `docs/bdd/<story-id>.feature` 或專案既有的 `tests/features/`，由人落地（D2）。
- **情境不可為了過關而修改**：開發代理不得改情境、削弱斷言、改預期值、加 skip／ignore／only。覺得情境錯 → 回報 `SPEC_CONFLICT`。

## 測試
- 命名（D7）：`s_12_1_should_<行為>`（依語言慣例調整大小寫與分隔符），一個情境對應一個以上測試。
- 每類都要涵蓋：正常、邊界（min、min+1、max−1、max、0、空）、非法輸入（null、錯誤型別、超範圍）、失敗（例外、外部依賴失效）。
- 領域層用不依賴框架的純單元測試；應用層用假的 Port；每個 Adapter 至少一組對真實依賴的整合測試；主要流程有 E2E。
- 加上分層依賴檢查（內層不得引用外層）。

## Red → Green → Refactor（每個測試都照做）
1. **Red**：寫測試，跑，確認因「功能還沒做」失敗（不是編譯錯或打錯字），失敗輸出存到 evidence。
2. **Green**：只寫讓它通過的最少**正確**程式——**禁止只為過測試寫死回傳值**（D6）。
3. **Refactor**：保持 Green 整理程式，全部測試再跑一次。
- 先 commit 測試（Red）再 commit 實作（Green）；這個順序以 **PR commit 列表與 evidence 檔**為證據（D15，squash 後不追溯）。
- Task 只有兩種結局：涵蓋的情境全部 Green，或回報 `RESLICE_REQUIRED`。

## 狀態時序（D4）
開發代理 Task `tdd=Green`、送 `READY_FOR_TDD` → 獨立驗證代理實測 PASS → **人**用情境端點把 `bdd[]` 標 Green → guard 重跑 → 人合併並標 Done。

## 追溯表（Story 卡或 `docs/bdd/TRACE.md`）
| Story | 情境 | 測試 | Task | PR |
|---|---|---|---|---|
| S-12 | S-12-1 顯示即時位置 | `s_12_1_should_*`（單元）、`S-12.feature`（E2E） | T-31 | #45 |
