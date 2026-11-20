; GuGuBoard 安裝程式 (NSIS / MUI2)
; 由 build-installer.ps1 呼叫 makensis 產生，傳入：
;   /DSTAGEDIR=<已 stage 好的打包目錄>  （含 board\ 與 skills\）
;   /DVERSION=<x.y.z>
;   /DOUTFILE=<輸出 .exe 完整路徑>
; 本檔不直接讀 repo；一切來源都來自 build 腳本 stage 好的內容（可重現）。

Unicode true

!ifndef STAGEDIR
  !error "缺少 /DSTAGEDIR：請由 build-installer.ps1 呼叫 makensis"
!endif
!ifndef VERSION
  !define VERSION "0.0.0"
!endif
!ifndef OUTFILE
  !define OUTFILE "GuGuBoard-Setup.exe"
!endif

!include "MUI2.nsh"
!include "Sections.nsh"
!include "LogicLib.nsh"

Name "GuGuBoard ${VERSION}"
OutFile "${OUTFILE}"
InstallDir "$LOCALAPPDATA\GuGuBoard"
InstallDirRegKey HKCU "Software\GuGuBoard" "InstallDir"
RequestExecutionLevel user          ; 裝在 LOCALAPPDATA，免系統管理員
SetCompressor /SOLID lzma
BrandingText "GuGuBoard ${VERSION}"

VIProductVersion "${VERSION}.0"
VIAddVersionKey "ProductName" "GuGuBoard"
VIAddVersionKey "ProductVersion" "${VERSION}"
VIAddVersionKey "FileDescription" "GuGuBoard 看板安裝程式"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "LegalCopyright" "GuGuBoard"

!define MUI_ICON "${STAGEDIR}\board\gugu.ico"
!define MUI_UNICON "${STAGEDIR}\board\gugu.ico"
!define MUI_ABORTWARNING

; ---- 精靈頁面 ----
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_COMPONENTS
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!define MUI_FINISHPAGE_RUN "$INSTDIR\start-board.cmd"
!define MUI_FINISHPAGE_RUN_TEXT "立即啟動 GuGuBoard 看板"
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "TradChinese"
!insertmacro MUI_LANGUAGE "English"

; =====================================================================
;  安裝前：移除舊版（保留 .ai-board 資料）
; =====================================================================
Function RemovePrev
  ReadRegStr $R1 HKCU "Software\GuGuBoard" "InstallDir"
  StrCmp $R1 "" done
  IfFileExists "$R1\serve-board.ps1" 0 done
    DetailPrint "偵測到舊版於 $R1，清除舊程式檔（保留 .ai-board）…"
    ; 把 .ai-board 先搬到暫存，清掉整個舊目錄，再搬回來
    IfFileExists "$R1\.ai-board\*.*" 0 noData
      RMDir /r "$TEMP\gugu-aiboard-keep"
      Rename "$R1\.ai-board" "$TEMP\gugu-aiboard-keep"
    noData:
    RMDir /r "$R1"
    IfFileExists "$TEMP\gugu-aiboard-keep\*.*" 0 done
      CreateDirectory "$R1"
      Rename "$TEMP\gugu-aiboard-keep" "$R1\.ai-board"
  done:
FunctionEnd

Function .onInit
  Call RemovePrev
FunctionEnd

; =====================================================================
;  Sections
; =====================================================================
Section "GuGuBoard 看板核心" SecBoard
  SectionIn RO
  SetOutPath "$INSTDIR"
  File /r "${STAGEDIR}\board\*.*"

  ; 登錄 + 卸載資訊
  WriteRegStr HKCU "Software\GuGuBoard" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\GuGuBoard" "Version" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "DisplayName" "GuGuBoard ${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "DisplayIcon" "$INSTDIR\gugu.ico"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "UninstallString" "$INSTDIR\uninstall.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "InstallLocation" "$INSTDIR"
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard" "NoRepair" 1
  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "ai-dev 技能（裝進看板目錄）" SecSkillsLocal
  SetOutPath "$INSTDIR\.claude\skills"
  File /r "${STAGEDIR}\skills\*.*"
SectionEnd

Section "ai-dev 技能（供 Claude Code 全域使用）" SecSkillsClaude
  SetOutPath "$PROFILE\.claude\skills"
  File /r "${STAGEDIR}\skills\*.*"
SectionEnd

Section "開始選單／桌面捷徑" SecShortcuts
  CreateDirectory "$SMPROGRAMS\GuGuBoard"
  CreateShortcut "$SMPROGRAMS\GuGuBoard\啟動 GuGuBoard 看板.lnk" "$INSTDIR\start-board.cmd" "" "$INSTDIR\gugu.ico"
  CreateShortcut "$SMPROGRAMS\GuGuBoard\解除安裝 GuGuBoard.lnk" "$INSTDIR\uninstall.exe"
  CreateShortcut "$DESKTOP\GuGuBoard 看板.lnk" "$INSTDIR\start-board.cmd" "" "$INSTDIR\gugu.ico"
SectionEnd

; ---- 元件說明 ----
!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN
  !insertmacro MUI_DESCRIPTION_TEXT ${SecBoard}        "看板伺服器、網頁與治理腳本（必裝）。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecSkillsLocal}  "把 5 支 ai-dev 技能放進看板安裝目錄的 .claude\skills。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecSkillsClaude} "把 5 支 ai-dev 技能複製到 %USERPROFILE%\.claude\skills，讓 Claude Code 全域看得到。"
  !insertmacro MUI_DESCRIPTION_TEXT ${SecShortcuts}    "建立開始選單與桌面捷徑。"
!insertmacro MUI_FUNCTION_DESCRIPTION_END

; =====================================================================
;  Uninstaller
; =====================================================================
Section "Uninstall"
  ; 捷徑
  Delete "$SMPROGRAMS\GuGuBoard\啟動 GuGuBoard 看板.lnk"
  Delete "$SMPROGRAMS\GuGuBoard\解除安裝 GuGuBoard.lnk"
  RMDir  "$SMPROGRAMS\GuGuBoard"
  Delete "$DESKTOP\GuGuBoard 看板.lnk"

  ; 是否一併刪除看板資料（帳號／專案／卡片）
  MessageBox MB_YESNO|MB_ICONQUESTION "是否一併刪除所有看板資料 (.ai-board：帳號／專案／卡片／稽核)？$\n$\n選「否」會保留 .ai-board，方便日後重新安裝。" IDYES uninstAll IDNO keepData

  uninstAll:
    RMDir /r "$INSTDIR"
    Goto afterData
  keepData:
    ; 保留 .ai-board：搬出→清空→搬回
    IfFileExists "$INSTDIR\.ai-board\*.*" 0 noKeep
      RMDir /r "$TEMP\gugu-aiboard-keep"
      Rename "$INSTDIR\.ai-board" "$TEMP\gugu-aiboard-keep"
      RMDir /r "$INSTDIR"
      CreateDirectory "$INSTDIR"
      Rename "$TEMP\gugu-aiboard-keep" "$INSTDIR\.ai-board"
      Goto afterData
    noKeep:
      RMDir /r "$INSTDIR"
  afterData:

  ; 註：全域 %USERPROFILE%\.claude\skills 的 ai-dev 技能為共用資源，卸載時不自動刪除。
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\GuGuBoard"
  DeleteRegKey HKCU "Software\GuGuBoard"
SectionEnd
