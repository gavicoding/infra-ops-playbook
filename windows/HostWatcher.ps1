<#
.SYNOPSIS
    Agente leve de observação para servidores/estações Windows (PowerShell 5.1, só leitura).

.DESCRIPTION
    A cada execução (via tarefa agendada a cada 1-5 min) coleta:
      * serviços esperados (estado e tipo de início)
      * processos esperados (rodando ou não, memória)
      * janelas de erro abertas (#32770 = MessageBox; TMessageForm = Delphi) com o texto
      * WerFault ("parou de funcionar")
      * espaço livre e uso por disco, uptime, memória
    e envia um JSON para a API central com token Bearer.

    Segurança:
      * token guardado com DPAPI (escopo LocalMachine) e ACL só SYSTEM/Admins
      * só envia para URL de rede interna (RFC 1918), para o token não sair da rede
      * auto-update SOMENTE se a assinatura RSA-SHA256 bater com a chave pública embutida
        e se o script novo passar no parser do PowerShell
      * nenhuma ação corretiva: o agente só observa

.EXAMPLE
    # 1x, como admin: gravar o token (pede sem eco)
    .\HostWatcher.ps1 -SetToken
    # execução normal (o que a tarefa agendada roda)
    .\HostWatcher.ps1 -ConfigPath C:\ProgramData\HostWatcher\config.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = "$env:ProgramData\HostWatcher\config.json",
    [switch]$SetToken
)

$ErrorActionPreference = 'Stop'
$AgentVersion = '1.0.0'
$BaseDir = Split-Path -Parent $ConfigPath
$TokenFile = Join-Path $BaseDir 'token.bin'

# Chave PÚBLICA do assinador (gerada por Sign-Script.ps1). A privada nunca fica no servidor.
$SigningPublicKeyXml = '<RSAKeyValue><Modulus>REPLACE_WITH_PUBLIC_MODULUS</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

Add-Type -AssemblyName System.Security

# ---------------------------------------------------------------- token (DPAPI)
function Set-AgentToken {
    New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
    $sec = Read-Host -AsSecureString 'Token do agente'
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    $enc = [Security.Cryptography.ProtectedData]::Protect(
        [Text.Encoding]::UTF8.GetBytes($plain), $null, 'LocalMachine')
    [IO.File]::WriteAllBytes($TokenFile, $enc)
    & icacls.exe $TokenFile /inheritance:r /grant:r '*S-1-5-18:(F)' '*S-1-5-32-544:(F)' | Out-Null
    Write-Host "token gravado em $TokenFile"
}

function Get-AgentToken {
    $enc = [IO.File]::ReadAllBytes($TokenFile)
    [Text.Encoding]::UTF8.GetString(
        [Security.Cryptography.ProtectedData]::Unprotect($enc, $null, 'LocalMachine'))
}

if ($SetToken) { Set-AgentToken; return }

# ---------------------------------------------------------------- config
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json
# Exemplo de config.json:
# { "apiUrl": "https://10.0.0.10/api/agents",
#   "services": ["Spooler","SampleIntegrationSvc"],
#   "processes": ["sample-robot"],
#   "diskWarnPercent": 85 }

function Test-InternalUrl([string]$Url) {
    $h = ([Uri]$Url).Host
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($h, [ref]$ip)) {
        try { $ip = [Net.Dns]::GetHostAddresses($h) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1 }
        catch { return $false }
    }
    if (-not $ip) { return $false }
    $b = $ip.GetAddressBytes()
    return ($b[0] -eq 10) -or ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
           ($b[0] -eq 192 -and $b[1] -eq 168) -or ($b[0] -eq 127)
}
if (-not (Test-InternalUrl $cfg.apiUrl)) { throw "apiUrl fora da rede interna: $($cfg.apiUrl)" }

# ---------------------------------------------------------------- janelas de erro
if (-not ('HW.Win' -as [type])) {
    Add-Type -Namespace HW -Name Win -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, System.IntPtr p);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
'@
}

function Get-ErrorWindows {
    # Observação: janelas só são visíveis se a tarefa rodar na sessão do usuário logado.
    $found = New-Object System.Collections.ArrayList
    $cb = [HW.Win+EnumProc] {
        param($h, $p)
        if ([HW.Win]::IsWindowVisible($h)) {
            $cls = New-Object Text.StringBuilder 256; [void][HW.Win]::GetClassName($h, $cls, 256)
            if ($cls.ToString() -in '#32770', 'TMessageForm') {
                $t = New-Object Text.StringBuilder 512; [void][HW.Win]::GetWindowText($h, $t, 512)
                [uint32]$procId = 0; [void][HW.Win]::GetWindowThreadProcessId($h, [ref]$procId)
                $pn = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
                [void]$found.Add([pscustomobject]@{ class = $cls.ToString(); title = $t.ToString(); process = $pn })
            }
        }
        $true
    }
    [void][HW.Win]::EnumWindows($cb, [IntPtr]::Zero)
    , $found
}

# ---------------------------------------------------------------- coleta
$os = Get-CimInstance Win32_OperatingSystem
$report = [ordered]@{
    agentVersion = $AgentVersion
    host         = $env:COMPUTERNAME
    collectedAt  = (Get-Date).ToString('o')
    uptimeHours  = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
    memoryUsedPct = [math]::Round(100 * (1 - $os.FreePhysicalMemory / $os.TotalVisibleMemorySize), 1)
    services     = @(foreach ($s in $cfg.services) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
        [pscustomobject]@{ name = $s; state = if ($svc) { $svc.State } else { 'NotInstalled' }; startMode = $svc.StartMode }
    })
    processes    = @(foreach ($p in $cfg.processes) {
        $procs = @(Get-Process -Name $p -ErrorAction SilentlyContinue)
        [pscustomobject]@{ name = $p; running = $procs.Count; workingSetMB = [math]::Round((($procs | Measure-Object WorkingSet64 -Sum).Sum) / 1MB, 0) }
    })
    werFault     = @(Get-Process -Name WerFault -ErrorAction SilentlyContinue).Count
    errorWindows = @(Get-ErrorWindows)
    disks        = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
        $used = if ($_.Size) { [math]::Round(100 * (1 - $_.FreeSpace / $_.Size), 1) } else { 0 }
        [pscustomobject]@{ drive = $_.DeviceID; freeGB = [math]::Round($_.FreeSpace / 1GB, 1); usedPct = $used; warn = ($used -ge $cfg.diskWarnPercent) }
    })
}

# ---------------------------------------------------------------- envio
$headers = @{ Authorization = "Bearer $(Get-AgentToken)" }
$body = $report | ConvertTo-Json -Depth 5 -Compress
$resp = Invoke-RestMethod -Method Post -Uri $cfg.apiUrl -Headers $headers `
    -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 30

# ---------------------------------------------------------------- auto-update assinado
# A API responde { "latestVersion": "1.0.1" } quando há versão nova; o pacote vem de
# GET {apiUrl}/script -> { "script": "<base64 utf8>", "signature": "<base64>" }
if ($resp.latestVersion -and ([version]$resp.latestVersion -gt [version]$AgentVersion)) {
    $pkg = Invoke-RestMethod -Uri "$($cfg.apiUrl)/script" -Headers $headers -TimeoutSec 60
    $bytes = [Convert]::FromBase64String($pkg.script)
    $sig = [Convert]::FromBase64String($pkg.signature)

    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
    $rsa.FromXmlString($SigningPublicKeyXml)
    $ok = $rsa.VerifyData($bytes, (New-Object Security.Cryptography.SHA256CryptoServiceProvider), $sig)
    if (-not $ok) { Write-Warning 'update recusado: assinatura inválida'; return }

    $text = [Text.Encoding]::UTF8.GetString($bytes)
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { Write-Warning "update recusado: erro de sintaxe ($($errors[0].Message))"; return }

    $self = $MyInvocation.MyCommand.Path
    Copy-Item -LiteralPath $self -Destination "$self.bak" -Force
    [IO.File]::WriteAllBytes($self, $bytes)   # bytes exatos (não reencodar: quebraria a assinatura)
    Write-Host "atualizado para $($resp.latestVersion); vale na próxima execução"
}
