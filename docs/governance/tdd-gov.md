# E-GOV TDD 清單（看板治理 / BDD 情境驗收）

> 對應 Epic **E-GOV** → Feature **F-GOV-1** → Story **S-GOV-1-1**。
> 測試框架：**Pester 3.4**（Windows PowerShell 內建）。放在 `tests/governance/`，執行：
> `powershell -NoProfile -ExecutionPolicy Bypass -File tests\governance\Run-Tests.ps1`
> 情境對應：board.json 的 `S-GOV-1-1.bdd[]`（S-GOV-1-1-1 ~ S-GOV-1-1-6）＝ operative 情境；
> `docs/governance/S-GOV-1-1.feature.txt` 為人類可讀 Gherkin。
> 規則：先寫失敗測試（RED）→ 最小實作（GREEN）→ 整理（REFACTOR）。每個功能須涵蓋
> 正常 / 邊界 / 非法輸入 / 失敗 四類。驗證角色不得是開發角色。

---

## T-GOV-1a — 後端 scenario endpoint（`tests/governance/SetScenario.Tests.ps1`）

被測對象：`serve-board.ps1` 的 `Invoke-SetScenario`（新增）與其路由
`POST /api/p/<pid>/scenario`。測試以假的 `$req/$res` 與測試用 board.json、
假 session（role 可注入）直接呼叫 handler；副作用斷言讀寫後的 board.json 與回應物件。

**正常 / Happy path**
- **A1**（S-GOV-1-1-1）`It 'verifier 設 Green 回 200 並寫入 bdd 狀態'`：回 200、`body.ok=true`、`body.status='Green'`、board 中 `bdd[scenarioId].status='Green'`。
- **A2**（S-GOV-1-1-1）`It '設定成功會追加 Story history 並更新 updatedAt'`：Story 多一筆 `history{at,from:'bdd:<id>:None',to:'bdd:<id>:Green',by:'<user>（<role>）',reason}`，且 `updatedAt` 變新。
- **A3**（S-GOV-1-1-1）`It '端點不碰 Task.tdd'`：相關 Task 的 `tdd` 與其它欄位不變。
- **A4**（S-GOV-1-1-1）`It '成功後回 committed 並觸發 Push-All history'`：`body.committed` 為布林；mock 的 `Push-All` 被以 `'history'` 呼叫一次。

**角色門禁**
- **A5**（S-GOV-1-1-2）`It 'dev-agent 設情境硬擋 403 且狀態不變'`：role=`dev-agent` → 403，board 完全不變；且此判斷**先於** rank 比較（縱深防禦）。
- **A6**（S-GOV-1-1-3）`It 'viewer（rank<verifier）回 403 E_FORBIDDEN'`：role=`viewer` → 403 `E_FORBIDDEN`，狀態不變。
- **A7**（邊界）`It 'verifier 為允許的最低角色'`：`Get-RoleRank('verifier')` 恰為門檻，verifier 成功、低一階失敗。
- **A8**（S-GOV-1-1-2）`It '未登入回 401 / external 回 403 E_READ_ONLY'`：無 session → 401 `E_UNAUTHENTICATED`；external session → 403 `E_READ_ONLY`。

**身分門禁（dev≠verify，主驗收點）**
- **A9**（S-GOV-1-1-6）`It '開發者本人標自己 Task 情境 Green 被 403'`：設 Green 者 = 該情境所屬 Task（scenarioIds 含此情境者）的 claim／history by → 403，狀態不變。
- **A10**（S-GOV-1-1-6）`It '非開發者的 verifier 標同一情境成功'`：換一個身分 → 200，情境變 Green（證明擋的是身分而非角色）。
- **A11**（邊界）`It '設 Red/None 不受身分門禁限制'`：身分門禁只對「設 Green」生效；同一開發者把情境設 Red 或 None 允許（只有「宣告驗收通過」要擋）。

**非法輸入 / 失敗**
- **A12**（S-GOV-1-1-4）`It 'scenarioId 不存在回 404 E_NOT_FOUND'`。
- **A13**（S-GOV-1-1-4）`It '請求本體非 JSON 回 409 E_BAD_JSON'`。
- **A14**（S-GOV-1-1-4）`It '缺 storyId/scenarioId 或 status 非 Green/Red/None 回 400 E_BAD_REQUEST'`（含 status 大小寫錯誤）。
- **A15**（S-GOV-1-1-4，邊界）`It 'reason 空字串或超過 500 字回 400'`；`It 'reason 恰 500 字可接受'`（max 邊界）。
- **A16**（失敗，S-GOV-1-1-4）`It 'validate 不過時回 422 E_RULES 且不寫入'`：注入會違反共用規則的狀態，`Write-BoardChecked` 回錯 → 422，board 不變（fail-closed）。
- **A17**（S-GOV-1-1-5）`It 'Green→Red→None 逐次成功且各留一筆 history'`：三次呼叫狀態正確退回，history 依序各加一筆，updatedAt 每次更新。
- **A18**（失敗）`It 'storyId 與 scenarioId 不相符（情境不在該 story）回 404'`：scenarioId 存在於別的 story → 視為該 story 下不存在 → 404。

## T-GOV-1b — 前端控制項（`tests/governance/BoardScenarioUI.Tests.ps1` ＋ PR 驗收期實測）

被測對象：`board.html` 情境 `<li>` 渲染（約 474-477）。前端無單元框架時，
以字串／DOM 快照或 PR 驗收期（ai-dev-pr-acceptance）實測截圖為主；可對純函式
（role gate、payload 組裝）抽出做輕量測試。

**role-gated 渲染**
- **B1**（S-GOV-1-1-1）`It 'verifier 於情境列看到 Green/Red/None 鈕與 reason 欄'`：`/api/me` 的 `projects[].role` rank≥verifier 且≠dev-agent → 渲染控制項。
- **B2**（S-GOV-1-1-2）`It 'dev-agent 不顯示控制項'`：role=dev-agent → 只唯讀顯示 ✔/✘/○，無鈕（真正門禁仍在後端）。
- **B3**（S-GOV-1-1-3）`It 'viewer 不顯示控制項'`：rank<verifier → 無鈕。

**送出與即時更新**
- **B4**（S-GOV-1-1-1）`It '點 Green 會 fetch POST /scenario 並帶 X-CSRF'`：送出 body 含 storyId/scenarioId/status/reason，帶現有 CSRF header。
- **B5**（S-GOV-1-1-1）`It '成功後不自行改 DOM，靠 SSE board/history 重繪'`：收到 SSE 事件才更新該情境顯示。
- **B6**（非法 / 失敗）`It 'reason 空時前端擋住並提示；後端 4xx 顯示錯誤不改狀態'`：空 reason 不送出；後端回 4xx 時顯示訊息且情境維持原狀。

---

### 備註
- 後端是唯一事實來源與門禁；前端權限僅 UX。B1-B3 的「隱藏」不可取代 A5/A6/A9 的伺服器強制。
- 驗收由獨立角色執行（不得是本功能的開發代理）；PR 需 spec-change 標籤與核准者審查（`.feature` 落地時）。
- guard.ps1 讀 PR 分支 repo 內的 docs/board.json 判卡片狀態，故本功能最終要能把情境 Green 落到該 PR 分支那份 board.json（即此端點的 commit 行為）。
