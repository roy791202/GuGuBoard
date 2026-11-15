// 權限矩陣（domain 層，不可變值物件）。
// 每個受保護動作對應一組「允許角色」；任何變更都回傳新實例，原矩陣不受影響，
// 讓「指派新權限不影響其他角色」「越權變更被擋後維持不變」這類不變量容易驗證。
// 零框架/基礎設施依賴（A1）：只 import 同層的 role / errors。

import { DEFAULT_ROLES, type RoleName } from './role';
import {
  UnknownPermissionError,
  DuplicateRoleError,
  ForbiddenError,
} from './errors';

/** 已知權限白名單。指派不在此列的代碼會丟 UnknownPermissionError。 */
export const KNOWN_PERMISSIONS = [
  'view_board',
  'claim_ticket',
  'update_ticket',
  'submit_for_tdd',
  'move_done',
  'set_blue',
  'approve_deployment',
  'edit_matrix',
  'read_audit',
] as const;

export type Permission = (typeof KNOWN_PERMISSIONS)[number];

/** 預設權限指派。move_done 僅驗證者＋管理者；改矩陣（edit_matrix）僅管理者。 */
const DEFAULT_GRANTS: Readonly<Record<RoleName, readonly Permission[]>> = {
  檢視者: ['view_board'],
  開發代理: ['view_board', 'claim_ticket', 'update_ticket', 'submit_for_tdd'],
  驗證者: ['view_board', 'claim_ticket', 'update_ticket', 'move_done', 'read_audit'],
  稽核者: ['view_board', 'read_audit'],
  高階: ['view_board', 'submit_for_tdd', 'approve_deployment', 'read_audit'],
  管理者: [...KNOWN_PERMISSIONS], // 管理者握有全部權限，含 edit_matrix / move_done / set_blue
};

function isKnownPermission(code: string): code is Permission {
  return (KNOWN_PERMISSIONS as readonly string[]).includes(code);
}

export class PermissionMatrix {
  // 以角色名 → 權限集合保存；對外一律回唯讀視圖或排序陣列，內部 Map 不外洩。
  private constructor(
    private readonly grants: ReadonlyMap<RoleName, ReadonlySet<Permission>>,
  ) {}

  /** 載入預設 6 角色與其權限。 */
  static default(): PermissionMatrix {
    const grants = new Map<RoleName, ReadonlySet<Permission>>();
    for (const role of DEFAULT_ROLES) {
      grants.set(role, new Set(DEFAULT_GRANTS[role] ?? []));
    }
    return new PermissionMatrix(grants);
  }

  /** 角色名稱清單（依加入順序）。 */
  roles(): RoleName[] {
    return [...this.grants.keys()];
  }

  /** 擁有指定權限的角色清單。 */
  allowedRoles(perm: Permission): RoleName[] {
    this.assertKnownPermission(perm);
    return [...this.grants.entries()]
      .filter(([, perms]) => perms.has(perm))
      .map(([role]) => role);
  }

  /** 某角色是否擁有某權限。 */
  has(role: RoleName, perm: Permission): boolean {
    return this.grants.get(role)?.has(perm) ?? false;
  }

  /** 某角色的權限（排序後陣列，便於快照比對）。 */
  permissionsOf(role: RoleName): Permission[] {
    return [...(this.grants.get(role) ?? [])].sort();
  }

  /** 整個矩陣的穩定快照（角色與權限皆排序），用於不變量比對。 */
  snapshot(): Record<RoleName, Permission[]> {
    const out: Record<RoleName, Permission[]> = {};
    for (const role of [...this.grants.keys()].sort()) {
      out[role] = this.permissionsOf(role);
    }
    return out;
  }

  /** 新增角色（回新實例）。呼叫者需有 edit_matrix；重名丟 DuplicateRoleError。 */
  addRole(caller: RoleName, name: RoleName): PermissionMatrix {
    this.assertCanEdit(caller);
    if (this.grants.has(name)) {
      throw new DuplicateRoleError(name);
    }
    const next = this.cloneGrants();
    next.set(name, new Set());
    return new PermissionMatrix(next);
  }

  /** 指派權限給角色（回新實例）。呼叫者需有 edit_matrix；未知權限丟 UnknownPermissionError。 */
  grant(caller: RoleName, role: RoleName, perm: Permission): PermissionMatrix {
    this.assertCanEdit(caller);
    this.assertKnownPermission(perm);
    if (!this.grants.has(role)) {
      // 指派給不存在的角色：視為未知角色，當作重複/未知的保護；這裡選擇丟 DuplicateRole 的反面——
      // 以 ForbiddenError 表達「對象不合法的變更被拒」，避免引入超出本工單範圍的新例外型別。
      throw new ForbiddenError(caller, `grant to unknown role ${role}`);
    }
    const next = this.cloneGrants();
    const perms = new Set(next.get(role));
    perms.add(perm);
    next.set(role, perms);
    return new PermissionMatrix(next);
  }

  // ---- 內部 ----

  private assertKnownPermission(code: string): asserts code is Permission {
    if (!isKnownPermission(code)) {
      throw new UnknownPermissionError(code);
    }
  }

  private assertCanEdit(caller: RoleName): void {
    if (!this.has(caller, 'edit_matrix')) {
      throw new ForbiddenError(caller, 'edit_matrix');
    }
  }

  private cloneGrants(): Map<RoleName, Set<Permission>> {
    return new Map(
      [...this.grants.entries()].map(([role, perms]) => [role, new Set(perms)]),
    );
  }
}
