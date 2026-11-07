# AI 開發流程規則（GuGuBoard）

> 由 GuGuBoard 安裝程式產生。看板在 `.ai-pm/board.json`；用 GuGuBoard「🤖 AI 提示詞」取得工作提示詞，領單流程與燈號規則 L1–L7 見 ai-dev-pipeline。驗證角色絕對不可以是開發程式角色。

## 技能索引
- **ai-dev-pipeline**：總流程（workflow）：當要用 AI 代理把一個產品或功能從規劃一路做到 PR 時使用，依序串起預製期、實作期、PR 驗收期三個Skill，並設好階段之間的關卡。
- **ai-dev-preproduction**：預製期（高階 AI模型）：當要從零規劃一個產品或新功能時使用，依序產出需求、UI/UX、架構骨架、Stories/Epics、BDD、TDD、工單，並輸入使用者慣用的工單工具。
- **ai-dev-implementation**：實作期（中低階 AI 模型）：當要依已核准的工單、Stories/Epics 與 BDD 實作一張工單時使用。
- **ai-dev-pr-acceptance**：PR 驗收期（中低階 AI 模型實測，高階 AI 模型審查）：當工單標成 READY_FOR_TDD，要依 TDD 實際操作介面驗證、截圖錄影，並審查提交PR 時使用。
- **ai-dev-production-readiness**：上線就緒標準：規劃、實作或審查程式時，要確認測試策略、資料一致性與併發、可觀測性、安全防禦是否到位時使用；由ai-dev-preproduction、ai-dev-implementation、ai-dev-pr-acceptance 引用。

技能完整內容在 `.claude/skills/<id>/SKILL.md`，Claude Code 會依描述自動載入；也可輸入 `/ai-dev-preproduction` 等名稱呼叫。
