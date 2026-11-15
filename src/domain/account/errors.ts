// 帳號系統領域例外（domain 層，零框架/基礎設施依賴）。
// 用領域例外而非 ValueError/Error 字串，讓上層能精準分辨並對應 HTTP 狀態與稽核事件。

export class DomainError extends Error {
  constructor(message: string) {
    super(message);
    // 讓 instanceof 與 error.name 在轉譯/繼承後仍正確
    this.name = new.target.name;
  }
}

/** 指派了不在白名單內的權限代碼。 */
export class UnknownPermissionError extends DomainError {
  constructor(public readonly permission: string) {
    super(`未知的權限代碼：${permission}`);
  }
}

/** 新增了已存在的角色名稱。 */
export class DuplicateRoleError extends DomainError {
  constructor(public readonly role: string) {
    super(`角色已存在：${role}`);
  }
}

/** 呼叫者沒有權限執行此矩陣變更（預設只有管理者可改矩陣）。 */
export class ForbiddenError extends DomainError {
  constructor(
    public readonly caller: string,
    public readonly action: string,
  ) {
    super(`角色「${caller}」無權執行：${action}`);
  }
}
