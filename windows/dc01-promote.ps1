#Requires -RunAsAdministrator
<#
.SYNOPSIS
    dc01 - promueve el controlador de dominio y siembra el contenido de la charla.

.DESCRIPTION
    Dos fases, porque la promocion reinicia el equipo:

        Fase 1: red estatica + rol AD DS + promocion  -> reinicia
        Fase 2: OU, usuarios y contenido              -> relanzar despues

    Valores: config/lab.env si el repositorio esta copiado a la VM; si no, los
    parametros; si no, los defaults. Prioridad: parametro > config > default.

.EXAMPLE
    .\dc01-promote.ps1
    .\dc01-promote.ps1 -DomainName lab.local -StaticIp 10.0.0.30
#>
[CmdletBinding()]
param(
    [string] $DomainName,
    [string] $NetbiosName,
    [string] $StaticIp,
    [string] $PrefixLen,
    [string] $Gateway,
    [string] $SafeModePassword,
    [string] $SvcUser,
    [string] $SvcPassword,
    [string] $CrownJewelPath
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# Configuracion
# --------------------------------------------------------------------------- #
$lib = Join-Path $PSScriptRoot '..\config\lab.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    throw ('No se encontro config\lab.ps1. Copia la carpeta config\ junto a windows\ ' +
           'en la VM (ver buildsheets/windows-vms.md).')
}
. $lib
$cfg = Import-BifrostLabConfig -Root $PSScriptRoot

$DomainName       = Resolve-BifrostSetting $DomainName       'BIFROST_DOMAIN'        -Config $cfg -Required
$NetbiosName      = Resolve-BifrostSetting $NetbiosName      'BIFROST_NETBIOS'       -Config $cfg -Required
$StaticIp         = Resolve-BifrostSetting $StaticIp         'BIFROST_IP_DC'         -Config $cfg -Required
$PrefixLen        = Resolve-BifrostSetting $PrefixLen        'BIFROST_PREFIX'        -Config $cfg -Required
$Gateway          = Resolve-BifrostSetting $Gateway          'BIFROST_GATEWAY'       -Config $cfg -Required
$SafeModePassword = Resolve-BifrostSetting $SafeModePassword 'BIFROST_DSRM_PASS'     -Config $cfg -Required
$SvcUser          = Resolve-BifrostSetting $SvcUser          'BIFROST_SVC_USER'      -Config $cfg -Required
$SvcPassword      = Resolve-BifrostSetting $SvcPassword      'BIFROST_SVC_PASS'      -Config $cfg -Required
$CrownJewelPath   = Resolve-BifrostSetting $CrownJewelPath   'BIFROST_CROWN_JEWEL'   -Config $cfg -Required

$baseDn = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','

function Write-Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "   [ OK ] $Text" -ForegroundColor Green }

Write-Host "Dominio=$DomainName  DC=$StaticIp/$PrefixLen  Svc=$SvcUser"

# --------------------------------------------------------------------------- #
# Red estatica
# --------------------------------------------------------------------------- #
Write-Step 'Configurando red estatica'

$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { throw 'No hay adaptador de red activo.' }

$existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
if (-not ($existing | Where-Object IPAddress -eq $StaticIp)) {
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIp `
        -PrefixLength ([int]$PrefixLen) -DefaultGateway $Gateway | Out-Null
}
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '127.0.0.1'
Write-Ok "$StaticIp/$PrefixLen en '$($adapter.Name)'"

if ($env:COMPUTERNAME -ne 'DC01') {
    Write-Host '   Renombrando el equipo a DC01...' -ForegroundColor Yellow
    Rename-Computer -NewName 'DC01' -Force
    Write-Host '   Reinicia y vuelve a lanzar el script.' -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------------- #
# Rol AD DS
# --------------------------------------------------------------------------- #
$adRole = Get-WindowsFeature -Name AD-Domain-Services

if (-not $adRole.Installed) {
    Write-Step 'Instalando AD DS'
    Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null
    Write-Ok 'AD-Domain-Services instalado'
}

# --------------------------------------------------------------------------- #
# Fase 1: promocion
# --------------------------------------------------------------------------- #
$isDc = $false
try { $isDc = (Get-Service NTDS -ErrorAction Stop).Status -eq 'Running' } catch { $isDc = $false }

if (-not $isDc) {
    Write-Step "Promoviendo a controlador de dominio de $DomainName"
    Import-Module ADDSDeployment

    $dsrm = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force

    Install-ADDSForest `
        -DomainName $DomainName `
        -DomainNetbiosName $NetbiosName `
        -InstallDns `
        -SafeModeAdministratorPassword $dsrm `
        -DomainMode WinThreshold `
        -ForestMode WinThreshold `
        -NoRebootOnCompletion:$false `
        -Force

    Write-Host '   Promocion lanzada: el equipo se reinicia en breve.' -ForegroundColor Yellow
    exit 0
}

# --------------------------------------------------------------------------- #
# Fase 2: contenido
# --------------------------------------------------------------------------- #
Write-Step 'Sembrando el dominio'
Import-Module ActiveDirectory

function Ensure-OU {
    param([string] $Name, [string] $Path)
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false | Out-Null
        Write-Ok "OU creada: $Name"
    }
}

Ensure-OU -Name 'Corp' -Path $baseDn
Ensure-OU -Name 'Usuarios' -Path "OU=Corp,$baseDn"
Ensure-OU -Name 'Servidores' -Path "OU=Corp,$baseDn"

$password = ConvertTo-SecureString $SvcPassword -AsPlainText -Force
$users = @(
    @{ Name = $SvcUser;  Given = 'Servicio'; Surname = 'Backup'; Description = 'Cuenta de servicio de copias' },
    @{ Name = 'j.perez'; Given = 'Jose';     Surname = 'Perez';  Description = 'Analista de ventas' },
    @{ Name = 'm.torres';Given = 'Maria';    Surname = 'Torres'; Description = 'Gerente de finanzas' }
)

foreach ($u in $users) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADUser `
            -Name "$($u.Given) $($u.Surname)" `
            -SamAccountName $u.Name `
            -UserPrincipalName "$($u.Name)@$DomainName" `
            -GivenName $u.Given `
            -Surname $u.Surname `
            -Description $u.Description `
            -Path "OU=Usuarios,OU=Corp,$baseDn" `
            -AccountPassword $password `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false | Out-Null
        Write-Ok "Usuario: $($u.Name)"
    }
}

# La cuenta de servicio NO es privilegiada: el valor narrativo esta en que el
# escaner no la distingue de cualquier otro hallazgo "medio".
$svc = Get-ADUser -Identity $SvcUser -ErrorAction SilentlyContinue
if ($svc) {
    Add-ADGroupMember -Identity 'Domain Users' -Members $svc -ErrorAction SilentlyContinue
}

# --------------------------------------------------------------------------- #
# Joya de la corona
# --------------------------------------------------------------------------- #
Write-Step 'Creando la carpeta objetivo'

if (-not (Test-Path $CrownJewelPath)) {
    New-Item -ItemType Directory -Path $CrownJewelPath -Force | Out-Null
}

@'
Proyeccion Q4 2026 - CONFIDENCIAL
Solo para el comite de finanzas. Documento de laboratorio, sin datos reales.
'@ | Set-Content -Path (Join-Path $CrownJewelPath 'Q4_Forecast_2026.txt') -Encoding UTF8

@'
nomina,departamento,monto
j.perez,Ventas,1450.00
m.torres,Finanzas,2100.00
'@ | Set-Content -Path (Join-Path $CrownJewelPath 'payroll_demo.csv') -Encoding UTF8

$acl = New-Object System.Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true, $false)
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)
Set-Acl -Path $CrownJewelPath -AclObject $acl
Write-Ok "$CrownJewelPath (solo Administrators)"

# --------------------------------------------------------------------------- #
# Ajustes de laboratorio
# --------------------------------------------------------------------------- #
Write-Step 'Ajustes de laboratorio'

# AVISO: desactiva Defender. Solo para una VM aislada sin datos reales.
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    Write-Ok 'Defender en tiempo real desactivado (VM aislada)'
}
catch {
    Write-Host "   No se pudo desactivar Defender: $($_.Exception.Message)" -ForegroundColor Yellow
}

# NTLM habilitado: lo necesita la coaccion de autenticacion del puente 4.
$lsa = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
Set-ItemProperty -Path $lsa -Name 'RestrictSendingNTLMTraffic' -Value 0 -Type DWord -ErrorAction SilentlyContinue
Write-Ok 'NTLM sin restricciones de salida'

Set-Service -Name W32Time -StartupType Automatic -ErrorAction SilentlyContinue
Start-Service W32Time -ErrorAction SilentlyContinue

Write-Host @"

============================================================================
 dc01 listo
   Dominio     : $DomainName ($NetbiosName)
   DC          : $StaticIp
   Usuarios    : $SvcUser, j.perez, m.torres
   Joya        : $CrownJewelPath

 Siguiente paso: .\adcs-esc8.ps1
============================================================================
"@ -ForegroundColor Green
