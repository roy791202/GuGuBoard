Feature: 排程設定介面
  Background:
    Given 已授權且隔離的測試專案

  Rule: 定時派工遵守交付與角色邊界

    @S-UI-01-1
    Scenario: S-UI-01-1 顯示停用與並行一個的預設值
      Given 管理者開啟新排程
      When 檢視設定
      Then 顯示停用與並行一個的預設值

    @S-UI-01-2
    Scenario: S-UI-01-2 顯示欄位錯誤且保留舊設定
      Given 開始時間無效
      When 儲存設定
      Then 顯示欄位錯誤且保留舊設定

    @S-UI-01-3
    Scenario: S-UI-01-3 無法儲存且顯示權限原因
      Given 唯讀使用者開啟設定
      When 嘗試變更
      Then 無法儲存且顯示權限原因
