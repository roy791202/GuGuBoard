# 看板、工作層級與燈號 L1–L7

> 何時讀：建卡、移卡、改燈號、寫 history，或被看板驗證擋下時。矛盾裁決見 `decisions.md`。

## 工作層級
| 層級 | 含義 | 時間 | 估算 | 範例 |
|---|---|---|---|---|
| Epic | 重大戰略、大版本 | 數月～一年 | 不估 | 建立線上點餐與追蹤系統 |
| Feature | 支撐 Epic 的中型模組 | 1～2 個 Sprint 或一個版本 | 不估 | 即時訂單追蹤 |
| User Story | 使用者視角的價值切片 | 1 個 Sprint 內 | Story Point | 作為消費者，我想要看到外送員的即時位置 |
| Task | 完成 Story 的技術工作 | **一輪（一個代理工作階段）做完並 TDD GREEN**（D12） | 實際工時（小時） | 串接地圖 API |
| PR | Task 的合併請求 | 數小時～數天 | — | `feature/<task-id>-<slug>` |

- 拆解 Epic → Feature → Story → Task → PR；**一個 Task 一個 PR**。
- Story 用 Story Point、Task 用小時；**Task 不可有 storyPoints、Story 不可有 hours**（schema 會擋）。

## 看板檔案
- 看板檔在 `<boardPath>`（D8）：看 `.ai-pm/project.json`，或看板伺服器的專案設定（GuGuBoard 本身是 `docs/board.json`）。範本 `board.example.json`、格式 `board.schema.json`，Markdown 備用 `docs/ai-dev-skills/BOARD-TEMPLATE.md`。
- 欄位：Backlog → Todo → In Progress → In Review / In QA → Done / Shipped。
- 狀態對照：`READY_FOR_TDD` = In Review；`RESLICE_REQUIRED` = 退回 Backlog（灰燈，D11）；Done 只在獨立驗證通過、PR 合併、**由人**標記後（D1）。
- 卡片欄位：層級、ID、標題、上層連結、燈號與 `lightReason`、描述（Story 用「作為…我想要…以便…」）、驗收標準（BDD ID）、估算、狀態、負責角色、Sprint、`tdd`、`prUrl`、`ci`。
- Story 用 `bdd[]`（情境 ID、Given/When/Then 摘要、測試名稱、None/Red/Green）——**這是情境的正式來源**（D2）；Task 用 `scenarioIds` 列出涵蓋的情境。
- `notes[]`（`at`、`by`、`text`）：決策、阻擋、退回、問答都追加一則，不刪改別人的。
- 時間戳 ISO 8601 含時區（`2026-11-01T09:30:00+08:00`）：`createdAt`、`updatedAt`、`startedAt`（進 In Progress）、`completedAt`（進 Done，不可早於 startedAt）。
- 移除工單要在 `removed[]` 留 `{id, title, at, by, reason}`，一次不可移除超過 20%；`revision`、`updatedAt` 不可倒退；不可刪除、搬走或整份重寫看板資料夾內的檔案（D9）。
- 修改管道優先順序（D9）：GuGuBoard MCP 工具 → Agent REST API → 直接局部編輯 board.json。見 `board-agent-api.md`。

## 健康燈號
| 燈號 | 含義 | 何時用 |
|---|---|---|
| ⚪ Gray | 未開始／暫停 | Backlog、Todo；In Progress 暫停時加 `paused: true` 與 `pausedReason` |
| 🟢 Green | 正常 | In Progress、In Review 且無風險 |
| 🟡 Yellow | 有風險 | 工時超過估算、TDD Red 過久、被退回一次、等待開發代理回答驗證者提問 |
| 🔴 Red | 阻擋 | 相依項卡住、CI 失敗、被退回兩次以上 |
| 🔵 Blue | 完成 | 只在 Done／Released，**只有人能設**（D1） |

上層匯總：子項全藍 → 藍；全未開始 → 灰；其餘取進行中子項最差的（紅 > 黃 > 綠）。

## 燈號規則（所有層共用，錯誤訊息帶編號）
- **[L1]** Backlog／Todo（佈署 Planned）只能灰燈。
- **[L2]** In Progress／In Review（Deploying／Verifying）只能綠／黃／紅；灰燈要 `paused: true` + `pausedReason`。
- **[L3]** Done（Released）只能藍燈；藍燈只能在 Done／Released；Rolled Back 必須紅燈。
- **[L4]** 黃燈／紅燈必須填 `lightReason`。
- **[L5]** 開發代理不可設藍燈、移到 Done、設 Released、填 `approvedBy`。
- **[L6]** Task 在 In Review 綠燈時，`tdd` 或 `tests.status` 必須是 Green。
- **[L7]** 燈號或欄位變更要更新 `updatedAt`，並在 `history` 追加 `{at, from, to, by, reason}`（只追加、最多 200 筆，D10）。

被擋時：照訊息裡的規則編號修正後再試，不要繞過。
