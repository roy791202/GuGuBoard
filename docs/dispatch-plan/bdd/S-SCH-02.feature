Feature: 暫停與重新啟動對帳
  Background:
    Given 已授權且隔離的測試專案

  Rule: 定時派工遵守交付與角色邊界

    @S-SCH-02-1
    Scenario: S-SCH-02-1 不派工
      Given 專案已暫停
      When 到達派工時間
      Then 不派工

    @S-SCH-02-2
    Scenario: S-SCH-02-2 只重新評估目前工作且不補發三批
      Given 服務錯過三個檢查週期
      When 恢復服務
      Then 只重新評估目前工作且不補發三批

    @S-SCH-02-3
    Scenario: S-SCH-02-3 不推進排程游標
      Given 事件保存失敗
      When 評估到期排程
      Then 不推進排程游標
