Feature: 續租與中止恢復
  Background:
    Given 已授權且隔離的測試專案

  Rule: AI Runner遵守交付與角色邊界

    @S-RUN-03-1
    Scenario: S-RUN-03-1 延長租約
      Given 工作仍在執行且持有租約
      When 到達五分鐘續租點
      Then 延長租約

    @S-RUN-03-2
    Scenario: S-RUN-03-2 停止整個受控程序樹且隔離工作區
      Given 續租無法在安全期限內確認
      When 處理租約失效
      Then 停止整個受控程序樹且隔離工作區

    @S-RUN-03-3
    Scenario: S-RUN-03-3 先隔離並確認舊程序停止再允許新執行
      Given Runner 重啟且舊程序狀態未知
      When 執行恢復對帳
      Then 先隔離並確認舊程序停止再允許新執行
