Feature: 可靠投遞
  Background:
    Given 已授權且隔離的測試專案

  Rule: Webhook 投遞遵守交付與角色邊界

    @S-WH-01-1
    Scenario: S-WH-01-1 事件標示已接收而非工作完成
      Given 有一筆待投遞事件
      When 接收端可靠接收
      Then 事件標示已接收而非工作完成

    @S-WH-01-2
    Scenario: S-WH-01-2 保留待重試紀錄
      Given 接收端逾時
      When 投遞事件
      Then 保留待重試紀錄

    @S-WH-01-3
    Scenario: S-WH-01-3 拒絕目標且不連線
      Given 目標不在允許清單
      When 儲存目標
      Then 拒絕目標且不連線
