Feature: 驗證交付回報
  Background:
    Given 已授權且隔離的測試專案

  Rule: 交付回報遵守交付與角色邊界

    @S-CMP-01-1
    Scenario: S-CMP-01-1 工單進入審查中並保存證據
      Given 測試全綠且證據完整
      When 提交交付
      Then 工單進入審查中並保存證據

    @S-CMP-01-2
    Scenario: S-CMP-01-2 拒絕成功交付且不設完成
      Given 程序正常結束但缺測試證據
      When 提交交付
      Then 拒絕成功交付且不設完成

    @S-CMP-01-3
    Scenario: S-CMP-01-3 拒絕回報且保留原工單
      Given 交付內容來自其他租約或版本
      When 提交交付
      Then 拒絕回報且保留原工單
