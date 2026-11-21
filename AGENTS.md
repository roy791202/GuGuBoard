# AI 開發流程規則（GuGuBoard）

> 由 GuGuBoard 產生（來源：GuGuBoard `skills/`，用 `scripts/sync-skills.ps1` 同步）。本檔只是**索引**：先讀 `ai-dev-pipeline`，其他技能與細則**需要時才讀**，不要一次讀全部。

## 每次都要遵守
- 驗證角色絕對不可以是開發程式角色；開發、實測、審查是各自啟動的代理。
- Done、藍燈、Released、`approvedBy` 只有人能設。
- 沒有失敗中的測試就不寫產品程式；不改情境、不削弱斷言、不加 skip。
- 不停用或繞過 hook、pre-commit、CI guard；被擋就照訊息修正。
- 看板在 `<boardPath>`（看 `.ai-pm/project.json`）；有 GuGuBoard MCP 就用 MCP 改，遵守燈號規則 L1–L7。
- 規則互相矛盾時以 `.ai-dev/references/decisions.md` 為準。

## 技能（依階段讀一份）
- **ai-dev-pipeline** (`.ai-dev/skills/ai-dev-pipeline/SKILL.md`): 總流程與索引（workflow）：用 AI 代理把產品或功能從規劃一路做到 PR 時先讀這份；列出硬性規則、階段關卡、狀態碼，以及遇到什麼情況該去讀哪一份細則（.ai-dev/references/）。
- **ai-dev-implementation** (`.ai-dev/skills/ai-dev-implementation/SKILL.md`): 實作期（中低階 AI 模型，開發代理）：依已核准的工單、Story 與 BDD 實作一張工單時使用；Red→Green→Refactor，最後送 READY_FOR_TDD。
- **ai-dev-pr-acceptance** (`.ai-dev/skills/ai-dev-pr-acceptance/SKILL.md`): PR 驗收期（中低階模型實測、高階模型審查，皆為獨立代理）：工單標成 READY_FOR_TDD 後，重跑測試、實際操作介面截圖錄影、審查 PR，給出 PASS 或退回。
- **ai-dev-preproduction** (`.ai-dev/skills/ai-dev-preproduction/SKILL.md`): 預製期（高階 AI 模型）：從零規劃產品或新功能時使用，依序產出需求、UI/UX、架構骨架、Stories/Epics、BDD、測試清單、工單與看板，每步經人確認。
- **ai-dev-production-readiness** (`.ai-dev/skills/ai-dev-production-readiness/SKILL.md`): 上線就緒標準：規劃、實作或審查時，要確認測試策略、資料一致性與併發、可觀測性、安全、效能與記憶體、發布回滾是否到位時使用；本身是索引，指向 .ai-dev/references/ 的細則。

## 細則（遇到對應情況才讀）
`.ai-dev/references/` 底下：`decisions`（矛盾裁決）、`board-and-lights`、`board-agent-api`、`enforcement-and-pitfalls`、`bdd-tdd`、`planning`、`architecture`、`clean-code`、`performance-memory`、`security`、`testing-data-observability`、`release-deploy`、`stack-commands`、`verification`。哪種情況讀哪份，見 `ai-dev-pipeline` 的對照表。
