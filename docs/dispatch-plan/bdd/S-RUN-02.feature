Feature: 領單後隔離啟動
  Background:
    Given 已授權且隔離的測試專案

  Rule: AI Runner遵守交付與角色邊界

    @S-RUN-02-1
    Scenario: S-RUN-02-1 只有有效租約持有人啟動
      Given 有兩個 Runner 同時要求一張工作
      When 領取工作
      Then 只有有效租約持有人啟動

    @S-RUN-02-2
    Scenario: S-RUN-02-2 回報失敗並釋放租約
      Given 領取成功但程序無法啟動
      When 開始工作
      Then 回報失敗並釋放租約

    @S-RUN-02-3
    Scenario: S-RUN-02-3 進入等待且不啟動程序
      Given 沒有可領工單
      When 請求工作
      Then 進入等待且不啟動程序
