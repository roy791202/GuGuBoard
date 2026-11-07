# 進度看板（BOARD.md）

> 層級：Epic → Feature → User Story → Task → PR。Story 估 Story Point，Task 估小時（不給 SP）。
> 欄位：Backlog → Todo → In Progress → In Review / In QA（自動化測試 Green）→ Done / Shipped
> Done 只在獨立驗證代理通過且 PR 已合併後；`RESLICE_REQUIRED` 退回 Backlog。

## 層級清單
| 層級 | ID | 標題 | 上層 | 估算 | Sprint |
|---|---|---|---|---|---|
| Epic | E-1 | 建立線上點餐與追蹤系統 | — | — | — |
| Feature | F-1 | 即時訂單追蹤功能 | E-1 | — | S1–S2 |
| Story | S-1 | 作為消費者，我想要在地圖上看到外送員的即時位置 | F-1 | 5 SP | S1 |
| Task | T-1 | 串接 Google Maps API | S-1 | 6 h | S1 |

## Backlog

## Todo

## In Progress

## In Review / In QA
<!-- 卡片格式：
- **T-1** 串接 Google Maps API（Story: S-1）
  - 驗收：BDD-MAP-001｜估算：6 h｜Sprint：S1
  - 負責：開發 dev-agent-A｜驗證 verify-agent-B
  - TDD：Green｜PR：feature/T-1-map-api #12｜CI：Green
-->

## Done / Shipped
