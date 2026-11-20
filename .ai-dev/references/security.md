# 安全防禦（Secure Coding）

> 何時讀：處理外部輸入、認證授權、密碼／金鑰／個資、錯誤回應、第三方套件時。原則：依需求，不過度設計（單機桌面 App 不必硬上 JWT）。

## 基本要求
- **輸入驗證**：在 API 層擋不合法輸入（格式、範圍、路徑穿越、指令注入、SQL 注入）；資料庫一律參數化查詢；渲染層防 XSS，不插入未消毒的 HTML。
- **認證與授權**：有帳號時用標準方案（OAuth2／OIDC／JWT）加 RBAC，不自創。Tauri 用 capabilities 只開放需要的 command 與路徑。
- **敏感資料**：密碼用 Argon2／BCrypt 加鹽雜湊；金鑰與 token 存 OS 安全儲存（經 Port），不寫進程式或設定檔；日誌自動遮罩卡號、身分證字號、token。
- **登記例外（D16）**：GuGuBoard 看板伺服器用 PBKDF2-SHA256（.NET 內建、零相依）與 session cookie；兩套權限系統（PS `$ROLES`/`Get-RoleRank` 與 TS `PermissionMatrix`）是分開的 runtime，合一列為技術債。新增例外要記到 `decisions.md`。

## 分層防禦
| 層 | 主要漏洞 | 必要寫法 |
|---|---|---|
| API | SQL 注入、XSS、BFLA | 參數化查詢，絕不拼接 SQL 或 shell；輸出編碼與 HTML 消毒；每個端點／command 明確宣告所需權限，由攔截器統一檢查，**預設拒絕** |
| 應用 | BOLA／IDOR | 不信任客戶端傳來的 ID；身分從 session/token 取；查詢帶擁有者條件或取回後驗證擁有權 |
| 應用＋領域 | 商業邏輯漏洞（負數量、溢位、非法狀態轉換） | 值物件建構時就拒絕不合理數值；衛句阻斷；金額用整數或 decimal 並檢查溢位 |
| 領域／基礎設施 | 敏感資料外洩 | 單向雜湊；敏感欄位遮罩；連線字串與金鑰不進日誌、不回前端；對外只回「系統發生錯誤（Error Code: XXXX）」 |
| 基礎設施／CI | 已知漏洞套件 | CI 跑 SCA（`cargo audit`/`cargo deny`、`npm audit`、`pip-audit`、Dependabot），高風險 CVE 就擋；鎖定版本；新套件寫引入理由 |

## TDD 必含的安全案例
SQL／指令注入字串、XSS 字串、越權呼叫高權限功能、改 ID 存取別人的資料、負數／零／極大值／溢位、錯誤回應不含內部細節、身分門禁（開發者不能驗收自己的工作）。
