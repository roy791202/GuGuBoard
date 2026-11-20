<#
.SYNOPSIS
  Generate every per-tool rule/skill file from the single source in skills/.
.DESCRIPTION
  Source of truth:
    skills/<id>/SKILL.md      phase skills (frontmatter name + description)
    skills/references/*.md    on-demand detail docs
    skills/INDEX.md           index template; <!-- SKILLS --> is replaced by the skill list
  Output (project-templates/ is what apply-project.ps1 copies into a repo):
    common/.ai-dev/skills/<id>/SKILL.md, common/.ai-dev/references/*.md   (all tools)
    claude/.claude/skills/<id>/SKILL.md + claude/CLAUDE.md                (index only)
    cursor/.cursor/skills/<id>/SKILL.md + cursor/.cursor/rules/<id>.mdc
    windsurf/.windsurf/rules/<id>.md, cline/.clinerules/<id>.md
    codex/AGENTS.md, gemini/GEMINI.md, copilot/.github/copilot-instructions.md (index only)
  The same files are mirrored into this repo root when the root copy already exists,
  and .ai-dev/ is always written at the root.
.PARAMETER Check
  Do not write; list files that are out of date and exit 1 if any.
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\sync-skills.ps1
#>
param([switch]$Check)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'skills'
$tpl = Join-Path $root 'project-templates'
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-Text([string]$p) { ([IO.File]::ReadAllText($p, $utf8)) -replace "`r`n", "`n" }

function Get-Skill([string]$dir) {
  $text = Read-Text (Join-Path $dir 'SKILL.md')
  if ($text -notmatch '(?s)^---\n(.*?)\n---\n(.*)$') { throw "No frontmatter: $dir" }
  $front = $Matches[1]; $body = $Matches[2].TrimStart("`n")
  $desc = @(); $inDesc = $false
  foreach ($line in $front -split "`n") {
    if ($line -match '^description:\s*(.*)$') {
      $inDesc = $true; $v = $Matches[1].Trim()
      if ($v -and $v -notmatch '^[>|]-?$') { $desc += $v }
      continue
    }
    if ($inDesc -and $line -match '^\s+\S') { $desc += $line.Trim() } elseif ($inDesc) { $inDesc = $false }
  }
  [pscustomobject]@{ id = (Split-Path $dir -Leaf); text = $text; body = $body; desc = (($desc -join '') -replace '"', '\"') }
}

$skills = @(Get-ChildItem -LiteralPath $src -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'SKILL.md') } | Sort-Object @{ Expression = { $_.Name -ne 'ai-dev-pipeline' } }, Name | ForEach-Object { Get-Skill $_.FullName })
$refs = @(Get-ChildItem -LiteralPath (Join-Path $src 'references') -Filter *.md | Sort-Object Name)
if (-not $skills.Count) { throw "No skills found under $src" }

$out = [ordered]@{}   # template-relative path -> content
foreach ($s in $skills) {
  $out["common/.ai-dev/skills/$($s.id)/SKILL.md"] = $s.text
  $out["claude/.claude/skills/$($s.id)/SKILL.md"] = $s.text
  $out["cursor/.cursor/skills/$($s.id)/SKILL.md"] = $s.text
  $out["cursor/.cursor/rules/$($s.id).mdc"] = "---`ndescription: `"$($s.desc)`"`nglobs:`nalwaysApply: false`n---`n$($s.body)"
  $out["windsurf/.windsurf/rules/$($s.id).md"] = "---`ntrigger: model_decision`ndescription: `"$($s.desc)`"`n---`n$($s.body)"
  $out["cline/.clinerules/$($s.id).md"] = $s.body
}
foreach ($r in $refs) { $out["common/.ai-dev/references/$($r.Name)"] = Read-Text $r.FullName }

$index = Read-Text (Join-Path $src 'INDEX.md')
$list = ($skills | ForEach-Object { "- **$($_.id)** (``.ai-dev/skills/$($_.id)/SKILL.md``): $($_.desc -replace '\\"', '"')" }) -join "`n"
$generic = $index.Replace('<!-- SKILLS -->', $list)
$claudeList = ($skills | ForEach-Object { "- **$($_.id)** (``.claude/skills/$($_.id)/SKILL.md``, ``/$($_.id)``): $($_.desc -replace '\\"', '"')" }) -join "`n"
$out['claude/CLAUDE.md'] = $index.Replace('<!-- SKILLS -->', $claudeList)
$out['codex/AGENTS.md'] = $generic
$out['gemini/GEMINI.md'] = $generic
$out['copilot/.github/copilot-instructions.md'] = $generic

$changed = @()
function Write-IfChanged([string]$path, [string]$content) {
  $old = $null; if (Test-Path -LiteralPath $path) { $old = Read-Text $path }
  if ($old -ceq $content) { return }
  $script:changed += $path
  if (-not $Check) {
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [IO.File]::WriteAllText($path, $content, $utf8)
  }
}
foreach ($k in $out.Keys) {
  Write-IfChanged (Join-Path $tpl $k) $out[$k]
  $rel = $k.Substring($k.IndexOf('/') + 1)          # drop the tool folder
  $rootPath = Join-Path $root $rel
  if ($k -like 'common/*' -or (Test-Path -LiteralPath $rootPath)) { Write-IfChanged $rootPath $out[$k] }
}

# Remove generated files whose source skill or reference no longer exists.
$known = @{}; foreach ($k in $out.Keys) { $known[(Join-Path $tpl $k).ToLower()] = $true }
$stale = @(Get-ChildItem -LiteralPath (Join-Path $tpl 'common\.ai-dev') -Recurse -File -ErrorAction SilentlyContinue | Where-Object { -not $known[$_.FullName.ToLower()] })
foreach ($f in $stale) { $changed += $f.FullName; if (-not $Check) { Remove-Item -LiteralPath $f.FullName -Force } }

$rootDir = $root.TrimEnd('\') + '\'
$changed | ForEach-Object { $_.Replace($rootDir, '') }
if ($Check) { if ($changed.Count) { Write-Output "OUT OF DATE: $($changed.Count) file(s)"; exit 1 } else { Write-Output 'UP TO DATE' } }
else { Write-Output "Synced $($skills.Count) skills, $($refs.Count) references; $($changed.Count) file(s) written." }
