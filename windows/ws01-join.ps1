#Requires -RunAsAdministrator
<#
.SYNOPSIS
    ws01 - estacion de trabajo del dominio, con credenciales "encontrables" y
    una carpeta compartida que sirve de escalon intermedio.

.DESCRIPTION
    Aporta el puente 3: credenciales utiles donde un operador las encontraria
    (configuracion de una app, notas de traspaso, tarea programada de servicio).

    Valores: config/lab.env si esta disponible; parametros si no.

.EXAMPLE
    .\ws01-join.ps1
#>
[CmdletBinding()]
param(
    [string] $DomainName,
    [string] $StaticIp,
    [string] $DnsIp,
    [string] $PrefixLen,
    [string] $Gateway,
    [string] $DomainAdmin,
    [string] $DomainAdminPassword,
    [string] $SvcUser,
    [string] $SvcPassword,
    [string] $SharePath
)

$ErrorActionPreference = 'Stop'

$lib = Join-Path $PSScriptRoot '..\config\lab.ps1'
if (-not (Test-Path -LiteralPath $lib)) {
    throw ('No se encontro config\lab.ps1. Copia la carpeta config\ junto a windows\ ' +
           'en la VM (ver GUIDE.md).')
}
. $lib
$cfg = Import-BifrostLabConfig -Root $PSScriptRoot

$DomainName  = Resolve-BifrostSetting $DomainName  'BIFROST_DOMAIN'       -Config $cfg -Required
$StaticIp    = Resolve-BifrostSetting $StaticIp    'BIFROST_IP_WS'        -Config $cfg -Required
$DnsIp       = Resolve-BifrostSetting $DnsIp       'BIFROST_IP_DC'        -Config $cfg -Required
$PrefixLen   = Resolve-BifrostSetting $PrefixLen   'BIFROST_PREFIX'       -Config $cfg -Required
$Gateway     = Resolve-BifrostSetting $Gateway     'BIFROST_GATEWAY'      -Config $cfg -Required
$DomainAdmin = Resolve-BifrostSetting $DomainAdmin 'BIFROST_DOMAIN_ADMIN' -Config $cfg -Required
$SvcUser     = Resolve-BifrostSetting $SvcUser     'BIFROST_SVC_USER'     -Config $cfg -Required
$SvcPassword = Resolve-BifrostSetting $SvcPassword 'BIFROST_SVC_PASS'     -Config $cfg -Required
$SharePath   = Resolve-BifrostSetting $SharePath   'BIFROST_SHARE_PATH'   -Config $cfg -Required

$baseDn = ($DomainName -split '\.' | ForEach-Object { "DC=$_" }) -join ','

function Write-Step { param([string]$Text) Write-Host "`n== $Text" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Text) Write-Host "   [ OK ] $Text" -ForegroundColor Green }

# --------------------------------------------------------------------------- #
# 1. Credenciales de administrador del dominio
# --------------------------------------------------------------------------- #
$plain = $DomainAdminPassword
if (-not $plain) {
    $plain = Resolve-BifrostSetting $null 'BIFROST_DOMAIN_ADMIN_PASS' '' $cfg
}
if (-not $plain) {
    $sec = Read-Host -AsSecureString "Contrasena de $DomainAdmin"
    $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
}

# --------------------------------------------------------------------------- #
# 2. Red
# --------------------------------------------------------------------------- #
Write-Step 'Configurando red'
$adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
if (-not $adapter) { throw 'No hay adaptador activo.' }

Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

# Re-ejecuciones: la ruta por defecto anterior hace fallar el -DefaultGateway
Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
    Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $StaticIp `
    -PrefixLength ([int]$PrefixLen) -DefaultGateway $Gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsIp
Write-Ok "$StaticIp, DNS $DnsIp"

# --------------------------------------------------------------------------- #
# 3. Union al dominio
# --------------------------------------------------------------------------- #
Write-Step "Uniendo a $DomainName"

$joined = (Get-CimInstance Win32_ComputerSystem).Domain -eq $DomainName
if (-not $joined) {
    if ($env:COMPUTERNAME -ne 'WS01') {
        Rename-Computer -NewName 'WS01' -Force
        Write-Host '   Renombrado a WS01. Reinicia y relanza el script.' -ForegroundColor Yellow
        exit 0
    }

    $cred = New-Object System.Management.Automation.PSCredential(
        $DomainAdmin, (ConvertTo-SecureString $plain -AsPlainText -Force))
    Add-Computer -DomainName $DomainName -Credential $cred -OUPath "OU=Corp,$baseDn" -Force
    Write-Host '   Union completada: reinicia el equipo y relanza el script.' -ForegroundColor Yellow
    exit 0
}
Write-Ok 'Ya esta en el dominio'

# --------------------------------------------------------------------------- #
# 4. Contenido "real": credenciales y carpetas
# --------------------------------------------------------------------------- #
Write-Step 'Sembrando artefactos'

foreach ($dir in @($SharePath, "$SharePath\RRHH", "$SharePath\IT", "$SharePath\Proyectos")) {
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
}

# Configuracion de una app interna con credenciales en claro.
@"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <appSettings>
    <add key="ApiUrl" value="http://web01.$DomainName:8080" />
    <add key="BackupAccount" value="$(($DomainName -split '\.')[0].ToUpper())\$SvcUser" />
    <add key="BackupPassword" value="$SvcPassword" />
  </appSettings>
</configuration>
"@ | Set-Content -Path "$SharePath\IT\backup-client.exe.config" -Encoding UTF8

# Nota de traspaso: el clasico "la contrasena esta en el ticket".
@"
TRASPASO - cliente de copias
--------------------------------
Servidor: web01.$DomainName
Cuenta:   $(($DomainName -split '\.')[0].ToUpper())\$SvcUser
Clave:    $SvcPassword

Pendiente: migrar a la boveda de secretos.
"@ | Set-Content -Path "$SharePath\IT\notas_traspaso.txt" -Encoding UTF8

@'
Resumen de evaluaciones Q3
Equipo de ventas
'@ | Set-Content -Path "$SharePath\RRHH\evaluaciones_Q3.txt" -Encoding UTF8

# Permisos amplios por diseno: es el hallazgo "SMB share permits write".
# Se usa el SID S-1-1-0 (Everyone) para que funcione tambien en Windows en
# espanol, donde la cuenta se muestra como "Todos".
$everyoneSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
$acl = Get-Acl $SharePath
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $everyoneSid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
$acl.AddAccessRule($rule)
Set-Acl -Path $SharePath -AclObject $acl

if (-not (Get-SmbShare -Name 'Compartido' -ErrorAction SilentlyContinue)) {
    $everyoneName = $everyoneSid.Translate([System.Security.Principal.NTAccount]).Value
    New-SmbShare -Name 'Compartido' -Path $SharePath -FullAccess $everyoneName | Out-Null
}

# El share no abre el firewall; SMB-In hace falta para el escaneo y el ataque.
New-NetFirewallRule -DisplayName 'Bifrost SMB-In' -Direction Inbound -Protocol TCP `
    -LocalPort 445 -Action Allow -ErrorAction SilentlyContinue | Out-Null

Write-Ok "$SharePath compartido (Everyone/Todos: Modify)"

# --------------------------------------------------------------------------- #
# 5. Sesion de la cuenta de servicio
# --------------------------------------------------------------------------- #
Write-Step 'Preparando sesion de la cuenta de servicio'
$taskName = 'CorpBackupAgent'
if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
    $action  = New-ScheduledTaskAction -Execute 'cmd.exe' `
        -Argument "/c echo backup > `"$SharePath\IT\last_run.txt`""
    $trigger = New-ScheduledTaskTrigger -Daily -At 3am
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -User "$(($DomainName -split '\.')[0].ToUpper())\$SvcUser" `
        -Password $SvcPassword -RunLevel Highest | Out-Null
    Write-Ok "Tarea programada '$taskName' como $SvcUser"
}

try {
    net use "\\$DnsIp\C$" /user:"$(($DomainName -split '\.')[0].ToUpper())\$SvcUser" $SvcPassword 2>$null | Out-Null
    Write-Ok 'Sesion SMB abierta hacia el DC'
}
catch { }

# --------------------------------------------------------------------------- #
# 6. Ajustes de laboratorio
# --------------------------------------------------------------------------- #
Write-Step 'Ajustes de laboratorio'
try {
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
    Write-Ok 'Defender en tiempo real desactivado (VM aislada)'
}
catch {
    Write-Host "   No se pudo desactivar Defender: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host @"

============================================================================
 ws01 listo
   IP        : $StaticIp
   Dominio   : $DomainName (WS01)
   Share     : \\WS01\Compartido  (Everyone: Modify)
   Creds     : $SharePath\IT\*.config y notas_traspaso.txt
   Sesion    : tarea $taskName como $SvcUser
============================================================================
"@ -ForegroundColor Green
