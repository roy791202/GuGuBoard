Feature: Webhook 與 Runner 設定介面
  Background:
    Given 已授權且隔離的測試專案

  Rule: Webhook 投遞遵守交付與角色邊界

    @S-UI-02-1
    Scenario: S-UI-02-1 只顯示金鑰參照且不回傳秘密
      Given 管理者設定金鑰
      When 重新開啟設定
      Then 只顯示金鑰參照且不回傳秘密

    @S-UI-02-2
    Scenario: S-UI-02-2 顯示連線結果且不啟動正式工單
      Given 管理者發出測試事件
      When 檢視結果
      Then 顯示連線結果且不啟動正式工單

    @S-UI-02-3
    Scenario: S-UI-02-3 顯示離線狀態且可暫停投遞
      Given Runner 離線
      When 檢視設定
      Then 顯示離線狀態且可暫停投遞
