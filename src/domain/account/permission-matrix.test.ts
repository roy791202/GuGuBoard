import { describe, it, expect } from 'vitest';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { PermissionMatrix, type Permission } from './permission-matrix';
import {
  UnknownPermissionError,
  DuplicateRoleError,
  ForbiddenError,
} from './errors';

const ADMIN = '管理者';
const VIEWER = '檢視者';
const here = dirname(fileURLToPath(import.meta.url));

describe('PermissionMatrix [S-ACC-3-1]', () => {
  it('test_should_load_default_matrix_with_move_done_restricted [S-ACC-3-1-1]', () => {
    const m = PermissionMatrix.default();
    // 預設 6 角色
    expect(m.roles().length).toBe(6);
    // move_done 的允許角色集合恰為 {驗證者, 管理者}
    expect(new Set(m.allowedRoles('move_done'))).toEqual(new Set(['驗證者', '管理者']));
  });

  it('test_should_add_custom_role_and_assign_permission [S-ACC-3-1-2]', () => {
    const base = PermissionMatrix.default();
    const before = base.snapshot();

    const next = base
      .addRole(ADMIN, 'release-manager')
      .grant(ADMIN, 'release-manager', 'approve_deployment');

    // 新角色擁有被指派的權限
    expect(next.has('release-manager', 'approve_deployment')).toBe(true);
    // 不可變：原矩陣完全不受影響
    expect(base.snapshot()).toEqual(before);
    expect(base.roles()).not.toContain('release-manager');
    // 既有角色在新矩陣中權限不變（diff 為空）
    for (const r of base.roles()) {
      expect(next.permissionsOf(r)).toEqual(base.permissionsOf(r));
    }
  });

  it('test_should_reject_unknown_permission_code [S-ACC-3-1-3]', () => {
    const m = PermissionMatrix.default();
    expect(() => m.grant(ADMIN, '管理者', 'do_everything' as Permission)).toThrow(
      UnknownPermissionError,
    );
  });

  it('test_should_reject_duplicate_role_name [S-ACC-3-1-4]', () => {
    const m = PermissionMatrix.default();
    expect(() => m.addRole(ADMIN, '管理者')).toThrow(DuplicateRoleError);
  });

  it('test_should_forbid_non_admin_editing_matrix [S-ACC-3-1-5]', () => {
    const m = PermissionMatrix.default();
    const before = m.snapshot();
    // 檢視者沒有 edit_matrix 權限 → 改矩陣被擋
    expect(() => m.grant(VIEWER, '開發代理', 'move_done')).toThrow(ForbiddenError);
    expect(() => m.addRole(VIEWER, 'x')).toThrow(ForbiddenError);
    // 被擋後矩陣維持不變
    expect(m.snapshot()).toEqual(before);
  });
});

describe('architecture [A1]', () => {
  it('test_domain_has_zero_framework_imports', () => {
    // domain 層不得 import sqlite/node:fs/http/express/argon2/任何 adapter（本測試檔本身不算）
    const forbidden =
      /\bfrom\s*['"](better-sqlite3|sqlite3?|node:fs|fs|node:http|http|express|argon2|[^'"]*\/(infra|adapters)\/)/;
    const files = readdirSync(here).filter(
      (f) => f.endsWith('.ts') && !f.endsWith('.test.ts'),
    );
    expect(files.length).toBeGreaterThan(0);
    for (const f of files) {
      const src = readFileSync(join(here, f), 'utf8');
      expect(src, `${f} 不得 import 框架或基礎設施`).not.toMatch(forbidden);
    }
  });
});
