Feature: 角色與工作階段分離
  Background:
    Given 已授權且隔離的測試專案

  Rule: 獨立驗證與核准遵守交付與角色邊界

    @S-GOV-01-1
    Scenario: S-GOV-01-1 拒絕驗收
      Given 驗證者是原開發者或同一工作階段
      When 提交驗證
      Then 拒絕驗收

    @S-GOV-01-2
    Scenario: S-GOV-01-2 保存驗證結果但不自動完成
      Given 獨立驗證者完成實測
      When 提交證據
      Then 保存驗證結果但不自動完成

    @S-GOV-01-3
    Scenario: S-GOV-01-3 保存審查結果且不提升角色
      Given 獨立審查者與開發者身分不同
      When 提交審查
      Then 保存審查結果且不提升角色
