Feature: 交付後繼續領單
  Background:
    Given 已授權且隔離的測試專案

  Rule: AI Runner遵守交付與角色邊界

    @S-RUN-04-1
    Scenario: S-RUN-04-1 在新工作階段執行下一張
      Given 上一張交付已確認且存在獨立就緒工單
      When 繼續領單
      Then 在新工作階段執行下一張

    @S-RUN-04-2
    Scenario: S-RUN-04-2 不領取相依工單
      Given 下一張相依工單尚未核准合併
      When 繼續領單
      Then 不領取相依工單

    @S-RUN-04-3
    Scenario: S-RUN-04-3 先對帳且不接新工單
      Given 上一張交付結果未知
      When 繼續執行
      Then 先對帳且不接新工單
