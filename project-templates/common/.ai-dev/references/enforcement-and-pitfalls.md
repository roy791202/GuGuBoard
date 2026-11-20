# 強制機制（四層）與已知坑

> 何時讀：被 hook／pre-commit／CI guard 擋下、要 commit 或開 PR、或在 worktree 裡工作時。

## 四層強制
| 層 | 機制 | 擋什麼 | 繞過時 |
|---|---|---|---|
| 1 規則 | skills、`AGENTS.md`／`CLAUDE.md`／各工具規則檔 | 讓 AI 知道流程 | 只靠自律 |
| 2 AI Hooks | `.ai-hooks/ai-hook.ps1`（Cursor、Claude Code） | 看板不合 L1–L7（與看板同一套 `validate-board.ps1`）；開發代理設 Done／藍燈／Released／approvedBy；改 `.feature`、hook、CI 設定；`--no-verify`、改 `core.hooksPath`；危險指令與讀機密檔；改了程式卻沒更新卡片 | 檢查本身出錯一律阻擋（fail closed） |
| 3 Git Hooks + CI Guard | `.githooks`（pre-commit、commit-msg）、`.github/workflows/ai-dev-guard.yml` | Conventional Commits、新增 skip/only/ignore、版本號不同步、PR 沒對應 In Review＋TDD Green 的 Task、情境沒 Green、未經 spec-change 標籤改 `.feature`、發版沒改 CHANGELOG；並跑測試 | 本機 `--no-verify` 可跳過，但 CI 一定會跑 |
| 4 分支保護 | GitHub 分支保護＋CODEOWNERS（`docs/ai-dev-skills/BRANCH-PROTECTION.md`） | 程式碼不能直推預設分支（D13 例外：`board:` 規劃 commit）、必要檢查沒過不能合併、`.feature`／hook／CI 修改要核准者審、禁止 force push | 管理員也不可略過 |

- 角色由啟動 AI 的人設定（`.ai-hooks/config.json` 的 `role` 或環境變數 `AI_AGENT_ROLE`），預設 `dev-agent`；AI 不可以自己改。人執行的腳本可設 `$env:AIPM_ROLE='admin'` 通過 pre-commit。
- 不得停用、繞過或修改任何一層；遇到阻擋照訊息修正，規則有問題回報給高階模型或使用者。hook 通過**不等於驗收**。

## AI Hooks 何時動作
- **執行指令前**：擋危險指令（`rm -rf /`、`git push --force`、`git reset --hard`、`format`、`del /s`、`curl … | sh`、讀 `.env`）；推送、遞迴刪除、發布套件要人確認。
- **讀檔前**：禁止讀機密檔（`.env`、`*.pem`、`id_rsa`）。
- **改檔後**：對該檔跑格式化與 guard（`unwrap()`/`expect()`、`console.log`、寫死的機密）。
- **結束前**：本輪有改檔就跑測試，失敗會要求繼續修；改了程式卻沒更新看板也會提醒（看板已 commit 時可視為誤報）。

## dev-agent hook 的實際範圍
- **硬擋寫入**：`*.feature`、`.ai-hooks/`、`.github/workflows/`、`.githooks/`、`.cursor/hooks.json`、`.claude/settings*.json`。
- **Shell 規則**：指令同時出現「受保護路徑字樣」**與**「寫入運算子」就擋——包括 `>`（所以 `2>/dev/null` 也算）、`Set-Content`、`Out-File`、`rm`、`mv`、`cp`、`sed -i`、`tee`、`git config`。只是要讀這些路徑時，改用 Read／Glob／Grep 工具，或拿掉重導向。
- 需要交付 `.feature` 時：寫成 `.feature.txt` 審閱檔，請人落地（D2）。
- board.json：新增 Backlog 灰燈卡允許；只擋 Done／藍燈／Released／approvedBy 與刪卡、revision 倒退。

## CI guard 的坑
- guard 讀的是 **PR 分支上的 `<boardPath>`**，只透過 MCP／伺服器改看板不夠——看板變更要真的 commit 進功能分支。tests 綠、guard 紅，幾乎都是這個原因。
- guard 要求 PR 對應單一 Task（分支 `feature/<task-id>-*` 或標題含 Task ID）。規劃／建卡的變更無法對應 → 走 D13 例外直接 commit。
- 改了 PR 分支但 guard 沒重跑：推一個 `git commit --allow-empty` 觸發。

## Git 與環境的坑
- 主 checkout 可能有使用者故意 staged 的檔案：**一律用明確路徑 commit**（`git commit -- <paths>`），先看 `git diff --cached --name-only`。
- `.githooks/` 若沒追蹤，worktree 裡的 pre-commit 會因找不到 `<worktree>/.githooks/check.ps1` 失敗（路徑問題，不是驗證失敗）——回報給使用者處理，不要用 `--no-verify`。
- Windows PowerShell 5.1：含中文的 `.ps1` 要 **UTF-8 BOM**，否則用系統碼頁解碼成亂碼。
- pwsh 7 的 `ConvertFrom-Json` 會把 ISO 日期轉成 `[DateTime]`，丟掉毫秒與時區——拿 `updatedAt` 當樂觀鎖版本時要用保留字串的解析。
- 寫看板合併邏輯的測試，fixture 要有**非空**的 history／notes，並斷言 history 內容（from/to/reason）。
- 測試設備問題（輸出管線互卡、編碼 cp950、隱藏 DOM 等待）記為 INVALID_RED，不算有效 RED；正式證據只採來源凍結後的那次執行。
