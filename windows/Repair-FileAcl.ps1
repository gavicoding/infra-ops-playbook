<#
.SYNOPSIS
    Recupera uma pasta de aplicação/serviço com DACL vazia ou corrompida e religa o serviço.

.DESCRIPTION
    Playbook do caso "serviço não sobe com Acesso negado, nem SYSTEM lê o executável".

    Causa mais comum (e silenciosa):
      icacls <ARQUIVO> /grant "*S-1-5-18:(OI)(CI)F"
    retorna exit 0, mas (OI)(CI) são flags de herança de CONTAINER. Num arquivo a ACE vira
    "inherit-only" e não dá permissão efetiva nenhuma -> DACL efetiva vazia.
    Outra causa: "icacls /inheritance:r /T" seguido de "/grant:r /T" abre, para cada arquivo,
    uma janela de DACL vazia; se o arquivo estiver aberto nesse instante o grant falha.

    Regras aplicadas aqui:
      * Tudo por SID (*S-1-5-18 = SYSTEM, *S-1-5-32-544 = Administradores, *S-1-1-0 = Todos)
        -> funciona em qualquer idioma do Windows e sem consultar o AD.
      * Pasta recebe (OI)(CI)F; ARQUIVO recebe (F) puro.
      * Confere a legibilidade REAL (abre o arquivo) em vez de confiar no exit code.

.PARAMETER Path
    Pasta da aplicação (ex.: C:\Program Files\SampleAgent).

.PARAMETER ServiceName
    Serviço a parar antes e iniciar depois (opcional).

.PARAMETER ScheduledTaskPath
    Pasta de tarefas "guardiãs" a desativar durante o reparo (ex.: \SampleAgent\).

.PARAMETER WritableSubfolder
    Subpasta que precisa continuar gravável por usuários comuns (ex.: temp). Opcional.

.EXAMPLE
    .\Repair-FileAcl.ps1 -Path 'C:\Program Files\SampleAgent' -ServiceName SampleAgent `
        -ScheduledTaskPath '\SampleAgent\' -WritableSubfolder temp -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Container })]
    [string]$Path,
    [string]$ServiceName,
    [string]$ScheduledTaskPath,
    [string]$WritableSubfolder
)

$ErrorActionPreference = 'Stop'
$SID_SYSTEM = '*S-1-5-18'
$SID_ADMINS = '*S-1-5-32-544'
$SID_EVERYONE = '*S-1-1-0'

function Write-Step([string]$Msg) { Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Msg) }

function Test-Readable([string]$File) {
    try { $s = [IO.File]::Open($File, 'Open', 'Read', 'ReadWrite'); $s.Close(); return $true }
    catch { return $false }
}

function Invoke-Icacls([string[]]$IcaclsArgs) {
    $out = & icacls.exe @IcaclsArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "icacls $($IcaclsArgs -join ' ') falhou: $out" }
}

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Execute em um PowerShell elevado (Administrador).'
}

# 1. Tirar quem pode "brigar" com o reparo: tarefas guardiãs e o próprio serviço
if ($ScheduledTaskPath) {
    Get-ScheduledTask -TaskPath $ScheduledTaskPath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.TaskName, 'Desativar tarefa')) {
            Disable-ScheduledTask -InputObject $_ | Out-Null
            Write-Step "tarefa desativada: $($_.TaskPath)$($_.TaskName)"
        }
    }
}
if ($ServiceName -and (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($ServiceName, 'Parar serviço')) {
        Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue
        Write-Step "serviço parado: $ServiceName"
    }
}

# 2. Diagnóstico: quantos arquivos o SYSTEM/admin atual não consegue ler
$files = Get-ChildItem -LiteralPath $Path -Recurse -File -Force
$broken = @($files | Where-Object { -not (Test-Readable $_.FullName) })
Write-Step ("{0} arquivo(s), {1} ilegível(is)" -f $files.Count, $broken.Count)

if ($PSCmdlet.ShouldProcess($Path, 'Retomar posse e reconstruir ACL')) {
    # 3. Posse (o /D Y responde "sim" independentemente do idioma)
    & takeown.exe /F $Path /R /D Y | Out-Null

    # 4. Pasta raiz: herança desligada SEM janela de DACL vazia (/inheritance:d converte
    #    herdadas em explícitas atomicamente) + remove usuários comuns + grants por SID
    Invoke-Icacls @($Path, '/inheritance:d')
    Invoke-Icacls @($Path, '/remove:g', '*S-1-5-11', '*S-1-5-32-545', $SID_EVERYONE)
    Invoke-Icacls @($Path, '/grant:r', "${SID_SYSTEM}:(OI)(CI)F", "${SID_ADMINS}:(OI)(CI)F")

    # 5. Subpastas herdam; arquivos recebem (F) puro, um a um (nunca (OI)(CI) em arquivo)
    Get-ChildItem -LiteralPath $Path -Recurse -Directory -Force | ForEach-Object {
        Invoke-Icacls @($_.FullName, '/reset')
    }
    foreach ($f in $files) {
        Invoke-Icacls @($f.FullName, '/reset')
        if (-not (Test-Readable $f.FullName)) {
            Invoke-Icacls @($f.FullName, '/grant', "${SID_SYSTEM}:(F)", "${SID_ADMINS}:(F)")
        }
    }

    # 6. Subpasta que usuários comuns precisam ler/gravar (ex.: scripts que rodam na sessão)
    if ($WritableSubfolder) {
        $w = Join-Path $Path $WritableSubfolder
        if (Test-Path $w) {
            Invoke-Icacls @($w, '/inheritance:e')
            Invoke-Icacls @($w, '/grant', "${SID_EVERYONE}:(OI)(CI)M", '/T')
            Write-Step "subpasta gravável reaberta: $w"
        }
    }
}

# 7. Conferência final pela legibilidade real
$still = @($files | Where-Object { -not (Test-Readable $_.FullName) })
if ($still.Count -gt 0) {
    $still | ForEach-Object { Write-Warning "continua ilegível: $($_.FullName)" }
    throw "Reparo incompleto ($($still.Count) arquivo(s)). Tarefas/serviço NÃO foram religados."
}
Write-Step 'todos os arquivos legíveis'

# 8. Religar
if ($ServiceName -and (Get-Service $ServiceName -ErrorAction SilentlyContinue)) {
    if ($PSCmdlet.ShouldProcess($ServiceName, 'Iniciar serviço')) {
        Start-Service $ServiceName
        Write-Step "serviço: $((Get-Service $ServiceName).Status)"
    }
}
if ($ScheduledTaskPath) {
    Get-ScheduledTask -TaskPath $ScheduledTaskPath -ErrorAction SilentlyContinue | ForEach-Object {
        if ($PSCmdlet.ShouldProcess($_.TaskName, 'Reativar tarefa')) { Enable-ScheduledTask -InputObject $_ | Out-Null }
    }
}
