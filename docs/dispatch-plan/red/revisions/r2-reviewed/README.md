# 可執行行為驅動與 RED 證據

本次新增其餘 45 項的具體驅動；連同原 SCH-01 三項共 48 項。正式結果以 driver-evidence/all.json 與 report.html 為準，不能使用舊的 initial field assertion 報告替代。

## 執行

需要 Python 3.10+、PowerShell 7、Node.js 與已安裝的 Chrome。測試用 Playwright 固定 1.56.1，只裝在 TEMP/guguboard-red-browser，不修改產品 package 或下載瀏覽器。可設定 GUGU_TEST_PWSH 指向 PowerShell 7；預設使用這台已驗證環境的 Codex runtime 路徑。

```powershell
npm install --prefix "$env:TEMP/guguboard-red-browser" --no-audit --no-fund --ignore-scripts playwright@1.56.1
pwsh -NoProfile -File docs/dispatch-plan/red/Run-Red.ps1
pwsh -NoProfile -File docs/dispatch-plan/red/Run-Red.ps1 -Remaining
pwsh -NoProfile -File docs/dispatch-plan/red/Run-Red.ps1 -Task RUN-02
python docs/dispatch-plan/red/qualify_evidence.py
```

退出碼：0 全部所選斷言通過；1 行為 RED；2 環境、fixture 或驅動錯誤。全套目前預期 1。qualify_evidence.py 為證據完整性檢查，通過返回 0，不是產品 GREEN。

## 實際驅動

- PowerShell Bridge.ps1 以雙向 JSON RPC 接收 use-case 請求，提供可執行 Clock／Store／Http／Board／Process／Identity Ports。scenario ID 與 expected 不傳入骨架。原 Skeleton.ps1 未變，仍沒有產品邏輯。
- 檔案：每案獨立 TemporaryDirectory；真正寫檔、原子替換與重開；新 World 與新 PowerShell 程序從同一檔案恢復。JSON snapshot 比較可觀察未完成交易與回復進度。
- 故障：Store.Commit、Process.Start、Board.Renew、Board.Release 的可執行注入點；HTTP 對端實際逾時與斷線。控制靶 PortProbe.ps1 先證明 RPC 可回傳正常值及注入例外，且不列入 BDD 計數。
- 並行：兩個 thread 經 Barrier 同時啟動兩個獨立 PowerShell 命令程序；共享 Board fake 使用鎖與持久化租約。控制測試能實際觀察唯一領取者。
- 生命週期：建立真正 Python 測試子程序，觀察存活／停止。這是單子程序控制，尚非產品 Windows Job Object／完整孫程序樹實測。
- HTTP：簽原始 UTF-8 payload bytes，實際送往 loopback ingress；重送、竄改、過期、durability failure 與 1000 筆 queue 案例均送出請求。
- UI：Playwright 操作 test-only HTML input adapter，實際 fill、click、reload、讀 DOM；九案各有截圖。測試頁只有轉送與通用投影，沒有補上驗證、權限或預設業務規則。
- 整合：composition driver 依序呼叫各模組 input boundary、HTTP ingress、交付、重建及獨立角色操作，共用測試儲存與 Ports；不把未實作模組稱作已完成產品整合。

## 有效 RED 的精確意義

48 項的骨架可載入、輸入與 fixture 有效、控制設備通過；每項實際呼叫 input boundary，並因缺少指定行為而有可重現的失敗。斷言包含真正的持久化狀態、HTTP 回應與呼叫、並行啟動次數、程序存活、DOM 與不可變條件；不再只比較回傳欄位。

原骨架仍沒有呼叫 Output Ports，所以某些故障注入點尚未命中。此時有效 RED 是「缺少到達該故障點的編排行為」，不是「已驗證故障處理失敗」。每項報告保留 faultHitCounts／missingFaultPaths；控制靶命中不可移算為產品或骨架命中。未來實作後必須先確認故障點真命中，再驗證補償與恢復，不能僅把目前紅字轉綠就聲稱安全。

UI 紅字是對測試 input adapter；產品 DOM、真實 AI CLI、完整程序樹、Windows 安裝及 DCC 均 NOT RUN。沒有產品 GREEN 或架構 conformance／acceptance 證據。

## 關卡與保護

獨立驗證、獨立審查及授權核准均保持 NOT RUN。所有正式卡片／藍燈不動，productionAllowed 仍空，readyForImplementation=false。此階段沒有提交、啟用派工或擴充產品介面。protected-hashes.json 記錄原骨架、產品檔、AGENTS 與原 BDD 的雜湊；證據資格檢查必須比對一致。

先前語法、RPC 與等待錯誤已分類為設備失敗，詳 HARNESS-LESSONS.md；不得列入 RED。報告來源雜湊防止使用修改前的舊結果。Run-InitialContract.ps1 與 red-results*.json 僅保留歷史，不是這階段 gate 證據。
