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
<!-- SKILLS -->

## 細則（遇到對應情況才讀）
`.ai-dev/references/` 底下：`decisions`（矛盾裁決）、`board-and-lights`、`board-agent-api`、`enforcement-and-pitfalls`、`bdd-tdd`、`planning`、`architecture`、`clean-code`、`performance-memory`、`security`、`testing-data-observability`、`release-deploy`、`stack-commands`、`verification`。哪種情況讀哪份，見 `ai-dev-pipeline` 的對照表。
