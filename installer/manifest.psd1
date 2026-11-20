@{
    # GuGuBoard 安裝檔「單一事實來源」。
    # build-installer.ps1 讀這份清單把 repo 檔案 stage 到打包目錄；
    # guguboard.nsi 只負責把 stage 好的內容裝進目標位置。
    # 來源路徑一律相對於 repo 根（-Source）。

    # 板核心：裝到 $INSTDIR
    BoardFiles = @(
        'serve-board.ps1'
        'serve-ext.ps1'
        'serve-mcp.ps1'
        'serve-tools.ps1'
        'validate-board.ps1'
        'deps.ps1'
        'apply-project.ps1'
        'board.html'
        'board.example.json'
        'board.schema.json'
        'guguboard-mcp.ps1'
        'mcp-stdio.ps1'
        'guguboard.cmd'
        'start-board.cmd'
        'start-board.ps1'
        'start-tunnel.cmd'
        'start-tunnel.ps1'
        'gugu-logo.png'
        'gugu-logo.svg'
        'gugu-mark.svg'
        'gugu.ico'
        'AGENTS.md'
        'CLAUDE.md'
        'GEMINI.md'
        'LICENSE'
        'NOTICE'
    )

    # 板核心附帶的整個資料夾（遞迴）：裝到 $INSTDIR\<name>
    BoardDirs = @(
        'docs'
        'project-templates'
        'scripts'
    )

    # 5 支 ai-dev 技能的來源（整個資料夾遞迴）。
    # 裝兩處：$INSTDIR\.claude\skills\（SecSkillsLocal）與 %USERPROFILE%\.claude\skills\（SecSkillsClaude）。
    SkillsSource = '.claude\skills'
    Skills = @(
        'ai-dev-implementation'
        'ai-dev-pipeline'
        'ai-dev-pr-acceptance'
        'ai-dev-preproduction'
        'ai-dev-production-readiness'
    )

    # stage 時一律排除的檔名樣式（避免把備份／狀態／垃圾打包）。
    ExcludePatterns = @(
        '*.bak'
        '*.bak-*'
        '*.tmp'
        '*.pyc'
        '__pycache__'
        '.DS_Store'
        'Thumbs.db'
    )

    # 可選來源不存在時只警告、不失敗（例如 repo 暫缺 LICENSE/NOTICE）。
    Optional = @(
        'LICENSE'
        'NOTICE'
    )
}
