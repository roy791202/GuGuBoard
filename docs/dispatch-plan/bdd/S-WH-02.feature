Feature: 有界重試與恢復
  Background:
    Given 已授權且隔離的測試專案

  Rule: Webhook 投遞遵守交付與角色邊界

    @S-WH-02-1
    Scenario: S-WH-02-1 使用相同事件識別重新投遞
      Given 事件已失敗一次
      When 到達下一重試時間
      Then 使用相同事件識別重新投遞

    @S-WH-02-2
    Scenario: S-WH-02-2 停止自動重試並顯示人工處理
      Given 事件已連續失敗五次
      When 評估重試
      Then 停止自動重試並顯示人工處理

    @S-WH-02-3
    Scenario: S-WH-02-3 保留次數與下次時間
      Given 服務在重試前重啟
      When 恢復投遞
      Then 保留次數與下次時間
