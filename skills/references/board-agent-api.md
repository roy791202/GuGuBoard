# 看板伺服器、MCP 與領單

> 何時讀：要領單、更新進度、送審、回答驗證者，或設定 MCP／token 時。

## 管道優先順序（D9）
1. **GuGuBoard MCP**（`http://localhost:8765/mcp`）：`get_rules` → `claim_ticket` → `get_ticket` → 每 5 分鐘 `renew_lease` → `update_ticket_progress`（每次都寫 reason）→ `add_ticket_note` → `submit_for_tdd` → `release_ticket`；驗證者提問用 `answer_verifier_question`。
2. **Agent REST API**（`/api/agent/v1`，`Authorization: Bearer <token>`）：`GET /bootstrap` → `POST /claim` → 每 5 分鐘 `POST /heartbeat`（租約 15 分鐘，過期自動釋放）→ `PATCH /tickets/<id>`（必填 `reason`）→ `POST /report` → `POST /release`。
3. 都沒有時才直接局部編輯 `<boardPath>`，照 `board-and-lights.md` 的規則。

- 不可修改別人領取的工單。卡住就改黃／紅燈、寫 `lightReason`，然後釋放。
- 派工器（push）由人開啟；派工 token 不能核准 Done 或佈署。

## token 與連線
- **token 決定專案**：連錯專案幾乎都是 token 用錯（例如橋接 store 的 `default` 指到別的專案）。token 只放在 client 設定或環境變數，不進 repo、不進 log。
- 建 token：看板「⚙ 設定 → MCP」。註冊（使用者自己在終端機跑，代理改自身設定會被擋）：`claude mcp add --transport http -s user guguboard http://localhost:8765/mcp --header "Authorization: Bearer aipm_..."`，或 `guguboard.cmd mcp install <client>`。改完要重啟 client。
- 位址用 `localhost`，不要用 `127.0.0.1`（http.sys 只註冊 localhost，會回 Invalid Hostname）。

## 情境狀態端點（D4）
- `POST /api/p/<pid>/scenario` 設 Story `bdd[]` 的 None/Red/Green：**session cookie 認證**（刻意不接 agent token），角色要 ≥ verifier，且有身分門禁（設定者 ≠ 該情境 Task 的開發者）。
- 實務上由**人**（非開發者的 admin／verifier）登入後標記；驗證代理只回報 PASS 證據。

## 伺服器本身
- 啟動 `start-board.cmd`／`serve-board.ps1`（只聽 localhost:8765）。**正在跑的伺服器是安裝版**（例如 `D:\AI_PM`），改 repo 裡的 `serve-*.ps1` 不會生效，要複製到安裝資料夾並重啟。
- 帳號：`-AddUser <名稱> -Role <viewer|dev-agent|verifier|high-tier|admin> -Project <專案>`；密碼 PBKDF2-SHA256 加鹽（D16 例外），存在 `.ai-board/users.json`（不進 git）。
- 多專案：`-AddProject <id> -Name -BoardPath -GitRepo -GitHubRepo [-RemoteSync]`；帳號預設看不到專案（admin 除外），用 `-GrantUser` 授權。
- 版本歷史：board.json 存檔後自動 commit 到該專案 repo（作者 `file-watch`）。`remoteSync=False` 時只進本機預設分支，origin 會落後 → PR 衝突時先 `git push origin <預設分支>`。
- PR 通知：設定 `githubRepo` 後輪詢 GitHub（token 只從環境變數 `GITHUB_TOKEN` 讀）。
