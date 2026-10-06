#Requires -Version 5.1
<#
.SYNOPSIS
    Разворачивает оснастку бенчмарк-прогона в отдельный каталог без git.

.DESCRIPTION
    Прогоны моделей выполняются вне репозитория, поэтому ветки больше не доставляют
    .claude/. Скрипт копирует в указанный каталог минимальный набор: .claude/{skills,agents}
    и PLANE.md. Структура .claude/ сохраняется как в репо, а PLANE.md кладётся в корень —
    поэтому относительные ссылки внутри скилов (../../../PLANE.md) и агентов
    (../../PLANE.md) остаются рабочими.

    CLAUDE.md и .env не копируются: модель получает их иначе. .env в каталоге прогона
    нужен скилу run и агенту run-debugger (гейт 2, npm run dev) — скрипт только
    предупреждает о его отсутствии и никогда его не трогает.

    package.json / tsconfig.json / .env.example / src/ не копируются: их создаёт сам
    промпт по разделу ## PROJECT SETUP в PLANE.md.

.PARAMETER Dest
    Каталог прогона. Создаётся, если не существует; должен быть пуст и лежать вне репозитория.

.PARAMETER NoSkills
    Baseline-прогон «модель без оснастки»: .claude/ не копируется.

.PARAMETER Force
    Разрешить разворачивание в непустой каталог.

.EXAMPLE
    .\scripts\bootstrap-run.ps1 -Dest C:\runs\deepseek-v4-pro

.EXAMPLE
    .\scripts\bootstrap-run.ps1 -Dest C:\runs\deepseek-v4-pro-baseline -NoSkills
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Dest,

    [switch] $NoSkills,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([char]'\', [char]'/')
}

# --- Источник ---------------------------------------------------------------

$repo = Get-NormalizedPath (Split-Path -Parent $PSScriptRoot)

if (-not (Test-Path -LiteralPath (Join-Path $repo 'PLANE.md') -PathType Leaf)) {
    throw "В репозитории нет PLANE.md (ожидался в $repo) — запускайте скрипт из scripts/ внутри репо."
}

# --- Проверка каталога прогона ---------------------------------------------

$destFull = Get-NormalizedPath $Dest

if ($destFull -eq $repo -or $destFull.StartsWith($repo + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Каталог прогона не должен лежать внутри репозитория ($repo) — прогон смешается со scaffolding."
}

if (Test-Path -LiteralPath $destFull -PathType Leaf) {
    throw "$destFull — файл, а не каталог."
}

if (Test-Path -LiteralPath $destFull) {
    $existing = @(Get-ChildItem -LiteralPath $destFull -Force)
    if ($existing.Count -gt 0 -and -not $Force) {
        throw "Каталог $destFull не пуст ($($existing.Count) элементов). Укажите пустой каталог или -Force."
    }
} else {
    New-Item -ItemType Directory -Path $destFull | Out-Null
}

# --- Оснастка ---------------------------------------------------------------

$skillCount = 0
$agentCount = 0

if ($NoSkills) {
    Write-Host 'Оснастка: пропущена (-NoSkills, baseline-прогон).' -ForegroundColor Yellow
} else {
    $destClaude = Join-Path $destFull '.claude'
    if (-not (Test-Path -LiteralPath $destClaude)) {
        New-Item -ItemType Directory -Path $destClaude | Out-Null
    }

    # .claude/worktrees/ не копируется: git-worktree область в не-git каталоге бессмысленна.
    foreach ($dir in 'skills', 'agents') {
        $src = Join-Path (Join-Path $repo '.claude') $dir
        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            throw "В репозитории нет .claude/$dir."
        }
        $target = Join-Path $destClaude $dir
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
        }
        Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
    }

    $skillCount = @(Get-ChildItem -LiteralPath (Join-Path $destClaude 'skills') -Filter 'SKILL.md' -Recurse -File).Count
    $agentCount = @(Get-ChildItem -LiteralPath (Join-Path $destClaude 'agents') -Filter '*.md' -File).Count
}

# --- Спека ------------------------------------------------------------------

Copy-Item -LiteralPath (Join-Path $repo 'PLANE.md') -Destination (Join-Path $destFull 'PLANE.md') -Force

# --- .env: не копируем и не трогаем, только предупреждаем -------------------

$envMissing = -not (Test-Path -LiteralPath (Join-Path $destFull '.env') -PathType Leaf)

# --- Отчёт ------------------------------------------------------------------

Write-Host ''
Write-Host "Каталог прогона: $destFull" -ForegroundColor Cyan
if ($NoSkills) {
    Write-Host '  .claude/       — не разворачивался (baseline)'
} else {
    Write-Host "  .claude/skills — скилов: $skillCount"
    Write-Host "  .claude/agents — агентов: $agentCount"
}
Write-Host '  PLANE.md       — скопирован'

if ($envMissing) {
    Write-Host ''
    Write-Host 'ВНИМАНИЕ: в каталоге прогона нет .env — скрипт его не копирует.' -ForegroundColor Yellow
    Write-Host '  Положите файл с реальными кредами сами, иначе гейт 2 (npm run dev) не запустится.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Дальше:' -ForegroundColor Cyan
Write-Host "  1. Откройте НОВУЮ сессию с рабочим каталогом $destFull —"
Write-Host '     каталог .claude/ читается при старте сессии, на лету не подхватится.'
if (-not $NoSkills) {
    Write-Host '  2. Проверьте подхват вопросом: «какие скилы и агенты тебе доступны?»'
    Write-Host "     Ожидается $skillCount скилов и $agentCount агентов."
    Write-Host '  3. Стартуйте прогон ЯВНО, а не надеясь на автоподхват по description:'
    Write-Host '     «собери клиент через /build-l2, веди цепочку субагентов из раздела'
    Write-Host '      Who owns which step» — иначе прогон не воспроизводится.'
} else {
    Write-Host '  2. Проверьте, что оснастки нет: «какие скилы и агенты тебе доступны?»'
    Write-Host '  3. Дайте модели только единый промпт по PLANE.md.'
}
Write-Host ''
