<#
.SYNOPSIS
    Executa um script de manutenção FORA da árvore de processos do serviço que o disparou.

.DESCRIPTION
    Problema real: um agente rodando como serviço (ex.: via NSSM) recebe o comando
    "desinstale-se" e executa um script filho. A primeira linha do script para o serviço ->
    o gerenciador do serviço encerra a ÁRVORE de processos inteira -> o script morre antes
    de remover serviço, tarefas e pastas, e o guardião restaura tudo.

    Solução: em vez de rodar o script direto, registrar uma tarefa agendada avulsa
    (SYSTEM, RunLevel Highest, gatilho único daqui a N segundos). Quem executa é o
    Agendador de Tarefas, um processo independente, imune ao kill do serviço.
    A tarefa se apaga no fim.

.PARAMETER ScriptPath
    Script .ps1 a executar. Ele é copiado para uma pasta que o serviço não vai apagar.

.PARAMETER DelaySeconds
    Atraso antes de executar (padrão 45 s, dá tempo do chamador responder "ok").

.EXAMPLE
    .\Invoke-OutOfTreeTask.ps1 -ScriptPath 'C:\Program Files\SampleAgent\uninstall.ps1'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ScriptPath,
    [ValidateRange(10, 3600)][int]$DelaySeconds = 45,
    [string]$TaskName = ('OneShot-Maintenance-{0:yyyyMMddHHmmss}' -f (Get-Date))
)

$ErrorActionPreference = 'Stop'

# Pasta de trabalho fora da pasta da aplicação (que pode ser apagada pelo próprio script)
$work = Join-Path $env:ProgramData 'OneShotMaintenance'
New-Item -ItemType Directory -Force -Path $work | Out-Null
# Só SYSTEM e Administradores (por SID) leem/gravam ali
& icacls.exe $work /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null

$script = Join-Path $work ("{0}.ps1" -f $TaskName)
$log = Join-Path $work ("{0}.log" -f $TaskName)
Copy-Item -LiteralPath $ScriptPath -Destination $script -Force

# Wrapper: executa, registra a saída e remove a própria tarefa
$wrapper = @"
`$ErrorActionPreference = 'Continue'
Start-Transcript -Path '$log' -Append | Out-Null
try { & '$script' } catch { Write-Output "ERRO: `$_" }
finally {
    Stop-Transcript | Out-Null
    Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath '$script' -Force -ErrorAction SilentlyContinue
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds($DelaySeconds)
$principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

[pscustomobject]@{
    TaskName = $TaskName
    RunsAt   = (Get-Date).AddSeconds($DelaySeconds)
    Log      = $log
}
