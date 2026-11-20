# Git、版本與佈署

> 何時讀：開分支、commit、解衝突、合併、打 tag、發版、回滾、建 Deployment 卡時。

## Git
| 項目 | 規則 |
|---|---|
| 預設分支 | 用 repo 實際名稱（`main` 或 `master`），隨時可佈署 |
| 功能分支 | `feature/<task-id>-<slug>`，一個 Task 一個 PR，**由開發代理開 PR**（D3） |
| 直推例外（D13） | 只改看板／規劃文件、不對應單一 Task 的 commit 可直推預設分支，訊息 `board: …`；程式碼一律走 PR |
| Commit 訊息 | Conventional Commits（`feat:`／`fix:`／`feat!:`）或 `board:` |
| 合併 | 一律 Squash and Merge；Red→Green 證據看 PR commit 列表與 evidence（D15） |
| 衝突（D14） | 把預設分支 **merge** 進功能分支並解衝突，不 rebase 已推送分支；解完**重跑 CI 與 TDD**，不得順手改行為 |
| 回滾 | `git revert`（新 commit），不 force push、不改預設分支歷史 |

## 環境與發布用詞
| 用詞 | 規則 |
|---|---|
| Dev / Staging / Prod | Dev 自測；Staging 完全模擬 Prod，跑 RC 與獨立驗收；Prod 真實使用者。桌面 updater 頻道 `dev`／`beta`／`stable` |
| Hotfix | 從 Prod tag 拉 `hotfix/<version>`，快速通道但**仍要 TDD Green＋獨立驗證**，上線後 merge 回預設分支 |
| Gradual Rollout | 分階段放量（5% → 50% → 100%），每階段健康 Green 才升級 |
| Canary | 先 1% 或內部 beta 頻道，健康 Green 再全量 |
| Feature Flag | 由設定檔開關；旗標寫負責人與移除日期，不做複雜旗標平台 |
| SemVer | 不相容 → Major；相容新功能 → Minor；修正／Hotfix → Patch；RC `v2.5.0-rc.1`；tag 一律 `vX.Y.Z` |

## 流程
- **一般**：PR Green → Squash 合併 → 打 `vX.Y.Z-rc.N` 上 Staging → 獨立驗證代理跑 BDD/E2E 與健康檢查 → **人核准** → 打 `vX.Y.Z` 上 Prod（Canary／Gradual／Flag）→ 健康 Green 且 100% → Released（藍燈，人設）。
- **Hotfix**：從 Prod tag 拉分支 → 寫重現 Bug 的失敗測試 → 修到 Green → 獨立驗證 → 打 Patch tag 上 Prod → merge 回預設分支。
- **回滾**：健康變紅或超出錯誤預算 → 先關 Flag → 不夠就把部署／updater manifest 指回 `rollbackRef` → `git revert`。卡片設 Rolled Back（紅燈），補備註，事後檢討寫進失敗經驗文件，再開 Patch。

## Deployment 卡（level = Deployment）
欄位：`version`、`releaseType`（Major/Minor/Patch/Hotfix/RC）、`environment`、`strategy`（Direct/Canary/Gradual/FeatureFlag）、`rolloutPercent`、`featureFlags`、`includes`、`gitRef`、`commitSha`、`changelogUrl`、`buildUrl`、`healthChecks`、`rollbackPlan`、`rollbackRef`、`deployedAt`、`approvedBy`。
狀態 Planned → Deploying → Verifying → Released／Rolled Back。Prod 必填 `rollbackPlan` 與 `approvedBy`（**人**，D1）。

## 上 Prod 前檢查
- 版本依 SemVer 升對，所有版本檔一致（見 `stack-commands.md`），tag 指向已在 Staging 驗過的同一個 commit。
- CHANGELOG 已更新（Keep a Changelog：Added／Changed／Fixed／Security）。
- 同版 RC 已在 Staging 由獨立驗證代理跑過 BDD/E2E、安全掃描、效能回歸，全 Green。
- 安裝檔已簽章；updater 頻道與放量比例正確。
- 回滾計畫寫好（關哪個 Flag、回到哪版、誰執行）；DB migration 向下相容或有反向 migration。
- 有健康指標、門檻與每階段觀察時間；核准人是人。
