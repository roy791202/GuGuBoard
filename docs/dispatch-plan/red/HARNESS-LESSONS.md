# 測試驅動失敗經驗（2026-11-07）

這些是本次測試設備問題，不是產品缺陷，也不列有效 RED。

1. RPC request 用 Write-Output 時被 PowerShell 函式回傳管線攔住，造成互等。改用 Console.WriteLine；新增 PortProbe 控制靶實際呼叫 Clock 與注入 Store.Commit，兩者控制通過後才放行 BDD 證據。PortProbe 不參與 BDD 計數。
2. Browser evaluate 多餘括號造成語法錯誤；先 node --check，再執行。早期 INVALID_RED 結果已被最終 canonical run 取代，不可算行為失敗。
3. 完成標記是隱藏 DOM，預設 visible 等待會逾時。改用 attached 同步條件，保留實際頁面操作，不延長 timeout 掩蓋錯誤。
4. Windows 預設 cp950 無法解碼錯誤日誌。Node subprocess 明確 UTF-8，設備例外一律 INVALID_RED／exit 2。
5. 同時跑不同版本可能覆寫非正式切片報告。正式證據只採來源凍結後的 driver-evidence/all.json，qualify_evidence.py 驗證來源雜湊、48 案完整性與原 BDD／產品檔雜湊。

命令過長曾未能啟動；確認檔案不存在後改分批寫入，未當作自動核准拒絕或產品錯誤。
