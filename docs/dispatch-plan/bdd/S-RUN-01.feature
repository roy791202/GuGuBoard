Feature: 驗證喚醒與可靠去重
  Background:
    Given 已授權且隔離的測試專案

  Rule: AI Runner遵守交付與角色邊界

    @S-RUN-01-1
    Scenario: S-RUN-01-1 只保存一筆工作
      Given 事件有效且佇列有空位
      When 接收兩次相同事件
      Then 只保存一筆工作

    @S-RUN-01-2
    Scenario: S-RUN-01-2 拒絕且不啟動工作
      Given 事件已被竄改或超過五分鐘
      When 接收事件
      Then 拒絕且不啟動工作

    @S-RUN-01-3
    Scenario: S-RUN-01-3 不回覆成功且不遺失已接受工作
      Given 接收儲存失敗或佇列已滿
      When 接收事件
      Then 不回覆成功且不遺失已接受工作
