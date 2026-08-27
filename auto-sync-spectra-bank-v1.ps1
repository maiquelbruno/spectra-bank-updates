param(
    [string]$RepoPath = "",
    [switch]$Once
)

# ============================================================
# Spectra Bank - Sincronizador Automatico V1
# ============================================================
# Monitora todo o repositorio publico local e publica automaticamente
# arquivos novos, alterados, removidos e movidos.
#
# O commit e o push so acontecem depois que o estado do repositorio e
# o tamanho/data dos arquivos permanecem estaveis por alguns segundos.
# ============================================================

$ErrorActionPreference = "Continue"

# ---------------- CONFIGURACAO ----------------

$repo = if ([string]::IsNullOrWhiteSpace($RepoPath)) {
    "E:\Github\spectra-bank-updates\Spectra_Bank_Pub"
} else {
    [System.IO.Path]::GetFullPath($RepoPath)
}
$branch = "main"
$checkSeconds = 2
$commitDelaySeconds = 5
$stabilityRecheckMilliseconds = 400
$releaseLockName = ".spectra-bank-release.lock"
$releaseLockPath = Join-Path $repo $releaseLockName

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
} catch {}

# ---------------- VALIDACAO ----------------

if (-not (Test-Path -LiteralPath $repo -PathType Container)) {
    Write-Host ""
    Write-Host "ERRO: repositorio nao encontrado:" -ForegroundColor Red
    Write-Host $repo -ForegroundColor Red
    Write-Host ""
    Read-Host "Pressione Enter para sair"
    exit 1
}

Set-Location -LiteralPath $repo

git rev-parse --is-inside-work-tree *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERRO: esta pasta nao e um repositorio Git." -ForegroundColor Red
    Write-Host $repo -ForegroundColor Red
    Write-Host ""
    Read-Host "Pressione Enter para sair"
    exit 1
}

# ---------------- FUNCOES DE LEITURA ----------------

function Get-GitStatus {
    $status = @(git status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0) {
        return @()
    }
    return $status
}

function Get-UnpushedCommitCount {
    $upstream = git rev-parse --abbrev-ref "$branch@{upstream}" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($upstream -join ""))) {
        return 0
    }

    $countText = git rev-list --count "$($upstream -join '')..HEAD" 2>$null
    if ($LASTEXITCODE -ne 0) {
        return 0
    }

    $count = 0
    if ([int]::TryParse(($countText -join "").Trim(), [ref]$count)) {
        return $count
    }
    return 0
}

function Get-WorkspaceFileSignature {
    $gitDir = (Join-Path $repo ".git").TrimEnd('\') + '\'
    $files = @(
        Get-ChildItem -LiteralPath $repo -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "$gitDir*" } |
            Sort-Object FullName
    )

    $parts = @(
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($repo.Length).TrimStart('\','/')
            "$relative|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
        }
    )
    return ($parts -join "`n")
}

function Test-WorkspaceFilesAvailable {
    $gitDir = (Join-Path $repo ".git").TrimEnd('\') + '\'
    $files = @(
        Get-ChildItem -LiteralPath $repo -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike "$gitDir*" }
    )
    foreach ($file in $files) {
        $stream = $null
        try {
            # A abertura exclusiva falha enquanto outro processo ainda estiver gravando.
            $stream = [System.IO.File]::Open($file.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        } catch {
            return $false
        } finally {
            if ($stream) { $stream.Dispose() }
        }
    }
    return $true
}

function Get-WorkspaceSignature {
    $status = Get-GitStatus
    $statusText = if ($status.Count -gt 0) { $status -join "`n" } else { "" }
    $unpushed = Get-UnpushedCommitCount
    $fileSignature = Get-WorkspaceFileSignature
    return "STATUS`n$statusText`nUNPUSHED=$unpushed`nFILES`n$fileSignature"
}

function Test-ReleaseLock {
    return Test-Path -LiteralPath $releaseLockPath -PathType Leaf
}

function Show-PendingFiles {
    $status = Get-GitStatus
    $unpushed = Get-UnpushedCommitCount

    if ($status.Count -eq 0 -and $unpushed -eq 0) {
        Write-Host "Nenhuma alteracao pendente." -ForegroundColor Green
        return $false
    }

    Write-Host ""
    if ($status.Count -gt 0) {
        Write-Host "Arquivos com alteracoes detectadas:" -ForegroundColor Yellow
        foreach ($line in $status) {
            Write-Host "  $line" -ForegroundColor DarkYellow
        }
    }
    if ($unpushed -gt 0) {
        Write-Host "Commits locais aguardando envio: $unpushed" -ForegroundColor Yellow
    }
    Write-Host ""
    return $true
}

function Wait-ForStableWorkspace {
    $previous = Get-WorkspaceSignature
    $stableSince = Get-Date

    while ($true) {
        Start-Sleep -Seconds $checkSeconds
        $current = Get-WorkspaceSignature
        if ($current -eq $previous) {
            if (((Get-Date) - $stableSince).TotalSeconds -ge $commitDelaySeconds -and (Test-WorkspaceFilesAvailable)) {
                return $current
            }
        } else {
            $previous = $current
            $stableSince = Get-Date
            Write-Host "Aguardando os arquivos terminarem de ser gravados..." -ForegroundColor DarkGray
        }
    }
}

# ---------------- PUBLICACAO ----------------

function Publish-All {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PUBLICANDO O REPOSITORIO SPECTRA BANK" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""

    git add -A
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO ao executar git add -A." -ForegroundColor Red
        return $false
    }

    git diff --cached --quiet
    $hasStagedChanges = ($LASTEXITCODE -ne 0)
    if (-not $hasStagedChanges) {
        Write-Host "Nenhum arquivo novo ou alterado para criar commit." -ForegroundColor DarkGray
    } else {
        Write-Host "Arquivos que entrarao neste commit:" -ForegroundColor Yellow
        git diff --cached --name-status
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $commitMessage = "Spectra Bank automatic sync - $timestamp"
        Write-Host "Commit: $commitMessage" -ForegroundColor Cyan
        git commit -m $commitMessage
        if ($LASTEXITCODE -ne 0) {
            Write-Host "ERRO ao criar o commit." -ForegroundColor Red
            return $false
        }
    }

    $unpushed = Get-UnpushedCommitCount
    if ($unpushed -eq 0) {
        Write-Host "Nenhum commit local aguardando push." -ForegroundColor Green
        return $true
    }

    Write-Host "Enviando objetos Git LFS para origin/$branch..." -ForegroundColor Cyan
    git lfs push origin $branch
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERRO ao enviar objetos Git LFS." -ForegroundColor Red
        return $false
    }

    Write-Host "Enviando $unpushed commit(s) para origin/$branch..." -ForegroundColor Cyan
    git push origin $branch
    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host " PUBLICADO COM SUCESSO!" -ForegroundColor Green
        Write-Host "============================================================" -ForegroundColor Green
        Write-Host ""
        return $true
    }

    Write-Host "ERRO no git push. O commit local foi preservado e sera tentado novamente." -ForegroundColor Red
    Write-Host "Verifique a conexao ou a autenticacao do GitHub." -ForegroundColor Red
    Write-Host ""
    return $false
}

# ---------------- INICIO ----------------

Clear-Host
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "       SPECTRA BANK - SINCRONIZADOR AUTOMATICO V1" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Repositorio : $repo"
Write-Host "Escopo      : todos os arquivos e subpastas"
Write-Host "Branch      : $branch"
Write-Host "Verificacao : a cada $checkSeconds segundos"
Write-Host "Espera      : $commitDelaySeconds segundos de estabilidade"
Write-Host ""
Write-Host "O script respeita o .gitignore, se existir." -ForegroundColor DarkGray
Write-Host "Ele so publica depois que tamanho, data e estado Git ficam estaveis." -ForegroundColor Magenta
Write-Host ""

if (Show-PendingFiles) {
    while (Test-ReleaseLock) {
        Write-Host "Bloqueio de release detectado; aguardando a montagem completa dos artefatos..." -ForegroundColor DarkGray
        Start-Sleep -Seconds $checkSeconds
    }
    Write-Host "Aguardando estabilidade antes da publicacao inicial..." -ForegroundColor Cyan
    [void](Wait-ForStableWorkspace)
    $published = Publish-All
    if (-not $published -and $Once) {
        exit 1
    }
}

if ($Once) {
    Write-Host "Execucao unica concluida." -ForegroundColor Green
    exit 0
}

Write-Host ""
Write-Host "Monitorando o repositorio inteiro..." -ForegroundColor Green
Write-Host "Pressione Ctrl+C para encerrar." -ForegroundColor DarkGray
Write-Host ""

$observedSignature = Get-WorkspaceSignature
$stableSince = if ((Get-GitStatus).Count -gt 0 -or (Get-UnpushedCommitCount) -gt 0) { Get-Date } else { $null }
$processing = $false

# ---------------- MONITORAMENTO ----------------

while ($true) {
    try {
        if (Test-ReleaseLock) {
            if ($stableSince -ne $null) {
                $stableSince = $null
                $observedSignature = Get-WorkspaceSignature
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Publicacao pausada durante a montagem da release." -ForegroundColor DarkGray
            Start-Sleep -Seconds $checkSeconds
            continue
        }

        $currentSignature = Get-WorkspaceSignature

        if ($currentSignature -ne $observedSignature) {
            $observedSignature = $currentSignature
            $stableSince = Get-Date
            Write-Host ""
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Alteracao detectada." -ForegroundColor Yellow
            foreach ($line in (Get-GitStatus)) {
                Write-Host "  $line" -ForegroundColor DarkYellow
            }
            $pendingCommits = Get-UnpushedCommitCount
            if ($pendingCommits -gt 0) {
                Write-Host "  Commits locais aguardando push: $pendingCommits" -ForegroundColor DarkYellow
            }
            Write-Host "Aguardando estabilidade por $commitDelaySeconds segundos..." -ForegroundColor DarkGray
        }
        elseif ($stableSince -ne $null -and ((Get-Date) - $stableSince).TotalSeconds -ge $commitDelaySeconds -and -not $processing) {
            $processing = $true
            $checkBeforePublish = Get-WorkspaceSignature
            Start-Sleep -Milliseconds $stabilityRecheckMilliseconds
            $checkAfterPublish = Get-WorkspaceSignature

            if ($checkBeforePublish -eq $checkAfterPublish -and (Test-WorkspaceFilesAvailable)) {
                $published = Publish-All
                $observedSignature = Get-WorkspaceSignature
                if ($published -and (Get-GitStatus).Count -eq 0 -and (Get-UnpushedCommitCount) -eq 0) {
                    $stableSince = $null
                } else {
                    $stableSince = Get-Date
                }
            } else {
                $observedSignature = $checkAfterPublish
                $stableSince = Get-Date
                Write-Host "Novas alteracoes chegaram durante a espera; aguardando novamente." -ForegroundColor Yellow
            }
            $processing = $false
        }
    }
    catch {
        Write-Host ""
        Write-Host "ERRO no monitoramento: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ""
        $processing = $false
        $stableSince = Get-Date
    }

    Start-Sleep -Seconds $checkSeconds
}
