Feature: 完整派工與恢復
  Background:
    Given 已授權且隔離的測試專案

  Rule: 派工整合遵守交付與角色邊界

    @S-INT-01-1
    Scenario: S-INT-01-1 第二張開始且第一張等待獨立驗證並不領第三張
      Given 兩張獨立已就緒工作與一張未解除相依工作
      When 完成第一張交付
      Then 第二張開始且第一張等待獨立驗證並不領第三張

    @S-INT-01-2
    Scenario: S-INT-01-2 不重複執行且能確認交付
      Given 事件重送且交付中途斷線
      When 服務恢復對帳
      Then 不重複執行且能確認交付

    @S-INT-01-3
    Scenario: S-INT-01-3 僅此時變藍並解除相依
      Given 開發完成後由不同身分驗證審查並核准已合併版本
      When 完成驗收
      Then 僅此時變藍並解除相依
