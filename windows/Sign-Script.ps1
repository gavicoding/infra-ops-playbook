<#
.SYNOPSIS
    Assina um script (RSA-SHA256) para distribuição via auto-update do HostWatcher.ps1.

.DESCRIPTION
    * Na primeira execução gera um par de chaves RSA 3072 e guarda a PRIVADA em
      %USERPROFILE%\.signing-keys\ (fora do repositório, fora do servidor, fora de nuvem
      sincronizada), com ACL só para o usuário atual.
    * Gera <script>.sig (base64) e imprime o XML da chave PÚBLICA para embutir no agente.
    * Assina os BYTES do arquivo. Marque o script como binário no git para o autocrlf não
      alterar os bytes depois da assinatura:
          .gitattributes ->  windows/HostWatcher.ps1 -text

.EXAMPLE
    .\Sign-Script.ps1 -ScriptPath .\HostWatcher.ps1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ScriptPath,
    [string]$KeyDir = (Join-Path $env:USERPROFILE '.signing-keys')
)

$ErrorActionPreference = 'Stop'
$privFile = Join-Path $KeyDir 'agent-signing.private.xml'
$pubFile = Join-Path $KeyDir 'agent-signing.public.xml'

if (-not (Test-Path $privFile)) {
    New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
    & icacls.exe $KeyDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
    $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider 3072
    $rsa.PersistKeyInCsp = $false
    Set-Content -LiteralPath $privFile -Value $rsa.ToXmlString($true) -Encoding ASCII
    Set-Content -LiteralPath $pubFile -Value $rsa.ToXmlString($false) -Encoding ASCII
    Write-Host "par de chaves criado em $KeyDir (faça backup OFFLINE da chave privada)"
}

$rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
$rsa.PersistKeyInCsp = $false
$rsa.FromXmlString((Get-Content -Raw -LiteralPath $privFile))

$bytes = [IO.File]::ReadAllBytes((Resolve-Path $ScriptPath))
$sig = $rsa.SignData($bytes, (New-Object Security.Cryptography.SHA256CryptoServiceProvider))
$sigFile = "$ScriptPath.sig"
Set-Content -LiteralPath $sigFile -Value ([Convert]::ToBase64String($sig)) -Encoding ASCII

# Autoverificação com a chave pública
$pub = New-Object Security.Cryptography.RSACryptoServiceProvider
$pub.FromXmlString((Get-Content -Raw -LiteralPath $pubFile))
if (-not $pub.VerifyData($bytes, (New-Object Security.Cryptography.SHA256CryptoServiceProvider), $sig)) {
    throw 'falha na autoverificação da assinatura'
}

Write-Host "assinado: $sigFile"
Write-Host "chave pública (embutir em `$SigningPublicKeyXml do agente):"
Get-Content -Raw -LiteralPath $pubFile
