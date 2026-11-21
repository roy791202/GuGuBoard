---
name: ai-dev-production-readiness
description: >-
  上線就緒標準：規劃、實作或審查時，要確認測試策略、資料一致性與併發、可觀測性、安全、效能與記憶體、發布回滾是否到位時使用；本身是索引，指向 .ai-dev/references/ 的細則。
---
# 上線就緒標準（索引）

一律以需求為準，不過度設計：單機桌面 App 不必硬上分散式交易、APM 或 JWT。依你的階段只讀需要的細則。

| 議題 | 預製期要寫進 | 實作期要做到 | 驗收期要檢查 | 細則 |
|---|---|---|---|---|
| 測試策略 | 覆蓋率門檻、整合與 E2E 範圍 | 領域純單元測試、Adapter 整合測試 | 覆蓋率報告、整合／E2E 有跑 | `testing-data-observability.md` |
| 資料與併發 | 交易邊界、鎖策略、可恢復寫入 | 交易在應用層、冪等重試、原子寫檔 | 交易邊界與鎖是否正確 | `testing-data-observability.md` |
| 可觀測性 | 日誌與錯誤格式、監控需求 | 結構化日誌、Trace ID、全域例外處理 | 日誌遮罩、錯誤不外洩 | `testing-data-observability.md` |
| 安全 | 權限模型、敏感資料、安全情境 | 輸入驗證、參數化查詢、預設拒絕、安全儲存 | 分層防禦表、SCA 結果、安全案例 | `security.md` |
| 效能與記憶體 | 效能預算、容量上限 | 先量測、複雜度推導、有界與串流 | 無意外 O(n²)、前後數字、穩定性 | `performance-memory.md` |
| 發布與回滾 | 版本、策略、健康指標、回滾 | Conventional Commits、版本檔一致 | SemVer、CHANGELOG、回滾計畫、人核准 | `release-deploy.md` |

**實作期底線**：不用 print 當日誌、不拼接 SQL 或 shell、不寫死金鑰、不把內部錯誤回傳前端、外部決定大小的配置都有上限。
**CI**：依賴套件的 SCA 掃描在 CI 跑，結果附進 PR 證據。
