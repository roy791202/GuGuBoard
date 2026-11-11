Feature: 執行與關卡紀錄介面
  Background:
    Given 已授權且隔離的測試專案

  Rule: 獨立驗證與核准遵守交付與角色邊界

    @S-UI-03-1
    Scenario: S-UI-03-1 分別呈現程序與交付狀態
      Given 程序已結束但交付未確認
      When 檢視工單
      Then 分別呈現程序與交付狀態

    @S-UI-03-2
    Scenario: S-UI-03-2 完成控制停用並說明原因
      Given 尚未合併工單
      When 檢視關卡
      Then 完成控制停用並說明原因

    @S-UI-03-3
    Scenario: S-UI-03-3 呈現空狀態且不顯示成功
      Given 沒有執行紀錄
      When 檢視紀錄
      Then 呈現空狀態且不顯示成功
