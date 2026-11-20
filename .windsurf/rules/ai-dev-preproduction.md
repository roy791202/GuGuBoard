---
trigger: model_decision
description: "預製期（高階 AI 模型）：從零規劃產品或新功能時使用，依序產出需求、UI/UX、架構骨架、Stories/Epics、BDD、測試清單、工單與看板，每步經人確認。"
---
# 預製期（高階 AI 模型）

先讀 `ai-dev-pipeline` 的硬性規則，以及專案的失敗經驗文件（`docs/LESSONS.md` 或既有的），把過去的卡關盲點寫進規格和工單。每一步產出存入 `docs/`，**人確認後才進下一步**。細則在 `.ai-dev/references/`，用到哪步讀哪份。

## 步驟
| # | 產出 | 細則 |
|---|---|---|
| 1 | **需求清單**：使用者、核心情境、功能、非功能需求（平台、效能預算、讀寫比、併發、敏感資料、日誌監控、安全）、範圍外、里程碑、待決問題 | `planning.md`、`testing-data-observability.md`、`security.md` |
| 2 | **UI/UX**：先附 2–3 個參考產品對照表，再做主要畫面、流程、空／載入／錯誤／降級狀態；刪掉超出需求的設計 | `planning.md` |
| 3 | **架構骨架**：選型與理由、替代方案、依賴圖、Ports/Adapters、每個主要 Use Case 的跨層資料流、目錄結構、可在每個目標平台編譯啟動的空殼。另寫交易邊界、鎖策略、日誌與錯誤格式、權限模型 | `architecture.md`、`testing-data-observability.md` |
| 4 | **工作層級**：Epic → Feature → Story（使用者視角、1 Sprint、Story Point），對應模組、層級、畫面 | `board-and-lights.md` |
| 5 | **BDD**：每個 Story 的情境寫進 board.json `bdd[]`（正式來源），並交付 `.feature.txt` 審閱檔請人落地（D2）；含正常、負向、邊界、安全情境 | `bdd-tdd.md` |
| 6 | **測試清單與斷言規格**：每個情境的測試名稱、層級、輸入、預期、fixtures、介面實測步驟（點哪裡、看到什麼、截哪張圖）；含覆蓋率門檻、併發、安全、效能預算、記憶體上限、分層依賴檢查；填追溯表（D5） | `bdd-tdd.md`、`performance-memory.md`、`security.md` |
| 7 | **Task 工單**：一張一個 Task、估小時、列 `scenarioIds`、允許修改的檔案、相依、完成定義；符合切片規則（一輪可完成、可獨立合併、不留半成品） | `planning.md` |
| 8 | **看板**：問人用什麼工單工具；以 `board.example.json` 為範本建 `<boardPath>`（依 `board.schema.json`），新卡 Backlog 灰燈；回報看板連結與啟動方式 | `board-and-lights.md`、`board-agent-api.md` |
| 9 | **發布規劃**：各 Feature／Epic 的版本、Flag、策略、健康指標、回滾；建 Planned 的 Deployment 卡 | `release-deploy.md` |

建卡與規劃文件不對應單一 Task，用 `board:` commit 直接進預設分支（D13）。

## 完成關卡
- 每個 Story 至少一個情境，每個情境都有測試規格，每張 Task 列出涵蓋的情境 ID。
- 架構選型有理由，符合跨平台、非必要不耦合、依賴由外往內。
- UI/UX 有參考產品依據且沒有過度設計。
- 看板已建，層級與估算齊全（Story 用 SP、Task 用小時）。
- 每張工單符合切片規則。
- **人已核准。**
