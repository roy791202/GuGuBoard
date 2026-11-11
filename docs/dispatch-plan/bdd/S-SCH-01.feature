Feature: 到期與唯一派工意圖
  Background:
    Given 已授權且隔離的測試專案

  Rule: 定時派工遵守交付與角色邊界

    @S-SCH-01-1
    Scenario: S-SCH-01-1 不產生事件
      Given 有效排程在開始前一秒
      When 評估派工
      Then 不產生事件

    @S-SCH-01-2
    Scenario: S-SCH-01-2 只保存一個派工意圖
      Given 有效排程剛好到期
      When 連續評估兩次
      Then 只保存一個派工意圖

    @S-SCH-01-3
    Scenario: S-SCH-01-3 拒絕設定且保留舊值
      Given 時間未含時區或間隔小於五秒
      When 儲存設定
      Then 拒絕設定且保留舊值
