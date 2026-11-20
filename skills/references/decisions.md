# 規則裁決紀錄（矛盾以本檔為準）

舊版 skills、全域規則與實務做法之間曾有互相矛盾的說法。下表是 2026-11-21 使用者核准的裁決；其他文件若與本表衝突，**以本表為準**，並回報修正那份文件。

| # | 議題 | 舊的矛盾說法 | 裁決 |
|---|---|---|---|
| D1 | 誰能設 Done／藍燈／Released／`approvedBy` | 「高階模型或使用者」vs MCP「那是人的決定」；hook 角色固定 dev-agent | **只有人**。高階模型只能「建議可以標完成」並附證據 |
| D2 | BDD 情境的唯一來源 | `.feature` 檔 vs board.json `bdd[]`；hook 對全 repo 封鎖 `.feature` | **board.json 的 `bdd[]` 是正式來源**。AI 交付 `.feature.txt` 審閱檔，`.feature` 由人落地 |
| D3 | 誰開 PR | 審查者「提交 PR」vs 開發代理填 PR 連結 | **開發代理開 PR**；審查代理只給核准／退回意見 |
| D4 | 情境 Green 的時序 | 送審前情境就要 Green vs 情境 Green 是驗證結論 | 開發代理送 `READY_FOR_TDD`（Task `tdd=Green`）→ 驗證代理實測 PASS → **人**用情境端點標 Green → guard 重跑 |
| D5 | 測試由誰寫 | 預製期寫好 vs 實作者先寫 Red | 預製期寫**測試清單與斷言規格**；實作者寫**測試程式碼**並證明有效 RED；寫好後不得削弱 |
| D6 | GREEN 可否寫死回傳值 | 全域 TDD「允許」vs 實作期「禁止」 | 專案內**禁止**只為過測試寫死回傳值 |
| D7 | 測試命名 | `s_12_1_*` vs `test_should_*` | 情境 ID 前綴 + should 句型：`s_12_1_should_顯示外送員位置` |
| D8 | 看板路徑 | `.ai-pm/board.json` vs 實際 `docs/board.json` | 依 `.ai-pm/project.json` 或看板伺服器登記的 `boardPath`；文件一律寫 `<boardPath>` |
| D9 | 能否直接編輯 board.json | MCP「不要直接編輯」vs pipeline「沒 API 時直接改」vs 實務整份重建 | 有 MCP 只走 MCP；沒有才直接編輯，且**只做局部修改**，不整份重寫 |
| D10 | history 欄位名 | `{…, note}` vs L7 `{…, reason}` | 一律 `{at, from, to, by, reason}` |
| D11 | `RESLICE_REQUIRED` 的燈號 | 燈號表說紅 vs L1 Backlog 只能灰 | 退回 Backlog 時**灰燈**，`lightReason` 寫「待重切：…」 |
| D12 | Task 時間單位 | 「1～2 天」vs「一輪做完」 | AI 代理的 Task 以**一輪（一個代理工作階段）**為上限；工時欄位仍記小時 |
| D13 | 直推預設分支 | 「不能直推 main」vs 規劃卡片直接 commit master；文件寫 main、repo 是 master | 預設分支用 repo 實際名稱。**例外**：只改看板／規劃文件、不對應單一 Task 的 commit 可直推，訊息用 `board:` 前綴；程式碼一律走 PR |
| D14 | 解衝突方式 | 「rebase」vs 禁止 force push | 把預設分支 **merge** 進功能分支（最後會 squash），不 rebase 已推送的分支 |
| D15 | Red 先於 Green 的證據 | 「先提交測試」vs Squash and Merge 會抹掉順序 | 證據以 **PR 的 commit 列表與 evidence 檔**為準，squash 後不追溯主分支歷史 |
| D16 | 密碼雜湊與認證 | readiness 要 Argon2/BCrypt、OAuth2/JWT vs 看板用 PBKDF2 + session cookie | 看板伺服器的 PBKDF2 為**登記例外**（零相依、.NET 內建）；兩套權限系統（PS `$ROLES` 與 TS PermissionMatrix）合一列為技術債。新產品程式仍依 readiness |
| D17 | 技術棧 | skills 寫死 Rust + Tauri | 主規則不寫死技術棧；各棧指令見 `stack-commands.md` |
| D18 | Prototype 階段可否抽象 | 全域 Stage 規則「Prototype 禁止 Port」vs 預製期「骨架就定 Port」 | **DCC 工具專案**依全域 Stage 規則；**GuGuBoard 管理的產品專案**依本套預製期 |

新增矛盾時：在此表追加一列（編號遞增），並同步修改相關文件。
