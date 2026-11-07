Feature: 核准與合併關卡
  Background:
    Given 已授權且隔離的測試專案

  Rule: 獨立驗證與核准遵守交付與角色邊界

    @S-GOV-02-1
    Scenario: S-GOV-02-1 拒絕完成
      Given 尚未驗證或尚未合併
      When 要求完成工單
      Then 拒絕完成

    @S-GOV-02-2
    Scenario: S-GOV-02-2 工單設完成與藍燈並保存歷程
      Given 驗證審查核准皆通過且證據對應已合併版本
      When 授權者確認完成
      Then 工單設完成與藍燈並保存歷程

    @S-GOV-02-3
    Scenario: S-GOV-02-3 拒絕且保留狀態
      Given 開發者或派工憑證嘗試核准
      When 要求完成工單
      Then 拒絕且保留狀態
