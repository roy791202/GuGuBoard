// 角色（domain 層）。角色以名稱識別；預設 6 個系統角色對應 GuGuBoard 既有層級。
// Ubiquitous Language：直接用中文角色名當識別碼，與看板 L1–L7 一致。

export type RoleName = string;

/** 預設 6 個系統角色（檢視者 < 開發代理 < 驗證者 ≈ 稽核者 < 高階 < 管理者）。 */
export const DEFAULT_ROLES = [
  '檢視者',
  '開發代理',
  '驗證者',
  '稽核者',
  '高階',
  '管理者',
] as const;

export type DefaultRole = (typeof DEFAULT_ROLES)[number];

export const ADMIN_ROLE: DefaultRole = '管理者';
