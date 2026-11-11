Feature: 交付重入與對帳
  Background:
    Given 已授權且隔離的測試專案

  Rule: 交付回報遵守交付與角色邊界

    @S-CMP-02-1
    Scenario: S-CMP-02-1 回傳原結果且不重複追加交付
      Given 交付已保存但回應遺失
      When 重送相同交付
      Then 回傳原結果且不重複追加交付

    @S-CMP-02-2
    Scenario: S-CMP-02-2 完成釋放並確認交付
      Given 工單已進審查中但釋放失敗
      When 重試交付
      Then 完成釋放並確認交付

    @S-CMP-02-3
    Scenario: S-CMP-02-3 回報衝突且不覆寫原證據
      Given 相同交付識別帶不同內容
      When 重新提交
      Then 回報衝突且不覆寫原證據
