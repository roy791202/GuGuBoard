# 分支保護建議設定（GitHub）

讓 AI 無法繞過流程的最後一道關卡。到 **Settings → Branches → Branch protection rules**（或 Rulesets）對 `main` 設定：

| 設定 | 建議值 | 原因 |
|---|---|---|
| Require a pull request before merging | 開啟 | 不能直接推 main |
| Required approvals | 1（驗證者或高階模型帳號，不可是開發代理） | 驗證角色不可以是開發角色 |
| Dismiss stale approvals when new commits are pushed | 開啟 | 改了程式就要重新審 |
| Require review from Code Owners | 開啟 | `.feature`、hook、CI 修改必須核准者審 |
| Require status checks to pass | `AI Dev Guard / guard`、`AI Dev Guard / tests`，以及原本的 CI | 看板、BDD、TDD 沒過不能合併 |
| Require branches to be up to date | 開啟 | 解完衝突要重跑 CI |
| Allow merge methods | 只開 **Squash and merge** | 一個 Task 一個 commit |
| Allow force pushes / deletions | 關閉 | 回滾用 revert，不改歷史 |
| Do not allow bypassing the above settings | 開啟（含管理員） | 規則對所有人有效 |

## CODEOWNERS 範例（`.github/CODEOWNERS`）

```
# BDD 情境、強制機制只能由核准者修改
*.feature              @kuan-yu
/docs/bdd/             @kuan-yu
/.ai-hooks/            @kuan-yu
/.githooks/            @kuan-yu
/.github/              @kuan-yu
/.cursor/hooks.json    @kuan-yu
/.claude/settings.json @kuan-yu
```

把 `@kuan-yu` 換成你的 GitHub 帳號或團隊。

## 標籤

- `spec-change`：PR 修改 `.feature` 時，由核准者加上（GitHub 標籤權限只給核准者）。
- `guard-change`：PR 修改 hook／CI 設定時，由核准者加上。

## 開發代理的 GitHub 權限

開發代理用的 token 或帳號只給 **Write**（可開 PR），不給 Maintain/Admin，也不要加入 CODEOWNERS，這樣它無法改分支保護、加標籤以外的權限或核准自己的 PR。
