# 各技術棧的指令與工具

> 何時讀：要跑測試、lint、benchmark、安全掃描或升版，且不確定這個專案用什麼指令時。**先用專案已有的**（看 `package.json`、`Cargo.toml`、`tests/` 的 runner），本表只是預設建議（D17）。

| 項目 | Rust | TypeScript | PowerShell（GuGuBoard 本身） | Python / DCC |
|---|---|---|---|---|
| 單元測試 | `cargo test` / `cargo nextest` | Vitest（`npx vitest run`） | Pester（`tests\governance\Run-Tests.ps1` 等） | `pytest` |
| BDD／E2E | `cucumber-rs` | Playwright（可搭 playwright-bdd） | Pester `Describe/It` 對應情境 ID | `pytest-bdd`；DCC 用 headless 啟動 |
| Lint／格式 | `cargo clippy`、`rustfmt` | ESLint、Prettier、`tsc --noEmit` | PSScriptAnalyzer | ruff |
| Benchmark | criterion、`cargo flamegraph` | Vitest bench、DevTools | `Measure-Command` | `pytest-benchmark` |
| SCA | `cargo audit`／`cargo deny` | `npm audit` | — | `pip-audit` |
| 版本檔 | `Cargo.toml` | `package.json` | 安裝程式版本 | `pyproject.toml` |

## GuGuBoard repo 實況
- 看板 `docs/board.json`；看板伺服器與工具是 PowerShell（`serve-*.ps1`、`validate-board.ps1`）；帳號系統是 TS（`src/domain/account/`，Vitest）。
- Pester 3.4（Windows PowerShell 內建）：`powershell -NoProfile -ExecutionPolicy Bypass -File tests\governance\Run-Tests.ps1`。測試用 AST 抽函式載入 `serve-*.ps1`，不啟動 listener。
- 驗證看板：`validate-board.ps1 -Path <新> -OldPath <舊> -Role dev-agent`（要帶 `-OldPath -Role`，否則 L5/L7 與完整性檢查會被略過）。
- 含中文的 `.ps1` 存 UTF-8 BOM。

## Tauri 桌面（選用）
Conventional Commits + commitlint；release-please（或 changesets／cargo-release）升版並產生 CHANGELOG；GitHub Actions + `tauri-action` 建置發布；Windows 程式碼簽章；`tauri-plugin-updater` 做頻道與放量。`Cargo.toml`、`package.json`、`tauri.conf.json` 版本號一致，由同一支工具更新。

## DCC headless
Maya `mayapy script.py`；Houdini `hython script.py`；Blender `blender --background --python script.py`；Unreal `UnrealEditor-Cmd.exe Project.uproject -run=Script`。
