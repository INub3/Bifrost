#Requires -Version 5.1
<#
.SYNOPSIS
    Bifrost - control de ciclo de vida del laboratorio sobre VMware Workstation/Fusion.

.DESCRIPTION
    Todos los valores salen de config/lab.env. No hay rutas ni IPs incrustadas
    en este archivo: si algo no cuadra, se corrige en la configuracion.

.EXAMPLE
    .\bifrost.ps1 preflight
    .\bifrost.ps1 config
    .\bifrost.ps1 start all
    .\bifrost.ps1 snapshot all
    .\bifrost.ps1 reset all
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Command = 'help',

    [Parameter(Position = 1)]
    [string] $Target,

    [string] $Label,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Rest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --------------------------------------------------------------------------- #
# Configuracion
# --------------------------------------------------------------------------- #

. (Join-Path $PSScriptRoot 'config/lab.ps1')

$script:Cfg = Import-BifrostLabConfig -Root $PSScriptRoot
$script:LabRoot = Get-BifrostVmDir -Config $script:Cfg
$script:SnapshotLabel = if ($Label) { $Label } else { $script:Cfg['BIFROST_SNAPSHOT'] }
$script:DiskBudgetGB = [int] $script:Cfg['BIFROST_DISK_BUDGET_GB']

$script:IsMac = Test-Path -LiteralPath '/Applications/VMware Fusion.app'
$script:VmwareType = if ($script:IsMac) { 'fusion' } elseif ($env:BIFROST_VMWARE_TYPE) {
    $env:BIFROST_VMWARE_TYPE
} else {
    $script:Cfg['BIFROST_VMWARE_TYPE']
}

# --------------------------------------------------------------------------- #
# Salida
# --------------------------------------------------------------------------- #

function Write-Section {
    param([string] $Text)
    Write-Host ''
    Write-Host "== $Text " -ForegroundColor Cyan -NoNewline
    Write-Host ('-' * [Math]::Max(0, 60 - $Text.Length)) -ForegroundColor DarkCyan
}

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')]
        [string] $Status,
        [string] $Message,
        [string] $Hint
    )
    $color = @{ OK = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Gray' }[$Status]
    Write-Host ('  [{0,-4}] {1}' -f $Status, $Message) -ForegroundColor $color
    if ($Hint) {
        Write-Host ('         -> {0}' -f $Hint) -ForegroundColor DarkGray
    }
}

# --------------------------------------------------------------------------- #
# vmrun
# --------------------------------------------------------------------------- #

function Find-Vmrun {
    $candidates = New-Object System.Collections.Generic.List[string]

    if ($env:BIFROST_VMRUN) { $candidates.Add($env:BIFROST_VMRUN) }
    if ($script:Cfg['BIFROST_VMRUN']) { $candidates.Add($script:Cfg['BIFROST_VMRUN']) }

    $found = Get-Command vmrun -ErrorAction SilentlyContinue
    if ($found) { $candidates.Add($found.Source) }

    if ($env:OS -eq 'Windows_NT') {
        $candidates.Add('C:\Program Files (x86)\VMware\VMware Workstation\vmrun.exe')
        $candidates.Add('C:\Program Files\VMware\VMware Workstation\vmrun.exe')
        $candidates.Add('C:\Program Files (x86)\VMware\VMware Player\vmrun.exe')
    }
    if ($script:IsMac) {
        $candidates.Add('/Applications/VMware Fusion.app/Contents/Public/vmrun')
    }
    $candidates.Add('/usr/bin/vmrun')
    $candidates.Add('/usr/lib/vmware/bin/vmrun')

    $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

$script:Vmrun = Find-Vmrun

function Invoke-Vmrun {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [switch] $AllowFail
    )

    if (-not $script:Vmrun) {
        throw 'vmrun no encontrado. Define BIFROST_VMRUN en config/lab.env o en el entorno.'
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & $script:Vmrun -T $script:VmwareType @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $lines = @($raw | ForEach-Object { "$_" })

    if ($code -ne 0 -and -not $AllowFail) {
        throw ("vmrun {0} fallo (exit {1}):`n{2}" -f ($Arguments -join ' '), $code, ($lines -join "`n"))
    }

    [pscustomobject]@{
        ExitCode = $code
        Lines    = $lines
        Text     = ($lines -join "`n")
    }
}

# --------------------------------------------------------------------------- #
# Inventario
# --------------------------------------------------------------------------- #

function Get-LabVms {
    if (-not (Test-Path -LiteralPath $script:LabRoot)) { return @() }

    Get-ChildItem -LiteralPath $script:LabRoot -Filter '*.vmx' -Recurse -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            [pscustomobject]@{ Name = $_.BaseName; Path = $_.FullName }
        } |
        Sort-Object Name
}

function Resolve-LabVm {
    param([string] $Name)

    $vms = @(Get-LabVms)
    if ($vms.Count -eq 0) {
        throw "No hay VMs en '$script:LabRoot'. Construyelas segun buildsheets/."
    }

    $vm = $vms | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if (-not $vm) {
        throw "VM '$Name' no encontrada. Disponibles: $($vms.Name -join ', ')"
    }
    $vm
}

function Get-RunningVms {
    if (-not $script:Vmrun) { return @() }
    $result = Invoke-Vmrun -Arguments @('list') -AllowFail
    $result.Lines |
        Where-Object { $_ -and $_ -notmatch '^Total running VMs' -and (Test-Path -LiteralPath $_) }
}

function Get-VmSnapshots {
    param([string] $VmxPath)

    $result = Invoke-Vmrun -Arguments @('listSnapshots', $VmxPath) -AllowFail
    if ($result.ExitCode -ne 0) { return @() }
    $result.Lines | Where-Object { $_ -and $_ -notmatch '^Total snapshots' }
}

# --------------------------------------------------------------------------- #
# Comandos
# --------------------------------------------------------------------------- #

function Invoke-Config {
    Write-Section "Configuracion ($($script:Cfg['__PATH__']))"

    foreach ($key in ($script:Cfg.Keys | Sort-Object)) {
        if ($key.StartsWith('__')) { continue }
        $value = $script:Cfg[$key]
        if ($key -match 'PASS|SECRET|_API_KEY') { $value = '******' }
        Write-Host ('  {0,-30} {1}' -f $key, $value)
    }
}

function Invoke-Preflight {
    Write-Section "Bifrost $($script:Cfg['BIFROST_VERSION']) preflight"
    $failures = 0
    $warnings = 0

    Write-Check OK "Configuracion: $($script:Cfg['__PATH__'])"

    if ($script:Vmrun) {
        Write-Check OK "vmrun ($script:VmwareType): $script:Vmrun"
    }
    else {
        Write-Check FAIL 'vmrun no encontrado' 'Instala VMware Workstation/Fusion o define BIFROST_VMRUN'
        $failures++
    }

    # Red host-only
    $hostOnly = $null
    if ($env:OS -eq 'Windows_NT') {
        $hostOnly = @(Get-NetAdapter -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'VMnet*' }) | Select-Object -First 1
    }
    else {
        $hostOnly = @(Get-ChildItem '/sys/class/net' -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'vmnet*' }) | Select-Object -First 1
    }

    if ($hostOnly) {
        Write-Check OK "Red host-only presente: $($hostOnly.Name)"
    }
    else {
        Write-Check FAIL 'No hay red host-only (VMnet1)' 'Virtual Network Editor -> Add Network -> Host-only'
        $failures++
    }

    # Carpeta de VMs
    if (Test-Path -LiteralPath $script:LabRoot) {
        Write-Check OK "Carpeta de VMs: $script:LabRoot"
    }
    else {
        Write-Check WARN "Carpeta de VMs no existe: $script:LabRoot" 'Se crea al construir la primera VM'
        $warnings++
    }

    # Disco
    try {
        $probe = if (Test-Path -LiteralPath $script:LabRoot) { $script:LabRoot } else { $PSScriptRoot }
        $rootPath = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($probe))
        $freeGB = [Math]::Round((New-Object System.IO.DriveInfo($rootPath)).AvailableFreeSpace / 1GB, 1)

        if ($freeGB -ge $script:DiskBudgetGB) {
            Write-Check OK "Espacio libre en ${rootPath}: $freeGB GB"
        }
        elseif ($freeGB -ge 30) {
            Write-Check WARN ("Espacio libre en {0}: {1} GB (el lab completo pide ~{2} GB)" -f $rootPath, $freeGB, $script:DiskBudgetGB) 'Alcanza para Lab Lite; apunta BIFROST_VM_DIR a un disco mayor'
            $warnings++
        }
        else {
            Write-Check FAIL "Espacio libre en ${rootPath}: $freeGB GB" 'Mueve BIFROST_VM_DIR a un disco con espacio'
            $failures++
        }
    }
    catch {
        Write-Check INFO 'No se pudo medir el espacio libre' $_.Exception.Message
    }

    # RAM
    try {
        $ramGB = [Math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
        if ($ramGB -ge 32) { Write-Check OK "RAM total: $ramGB GB" }
        elseif ($ramGB -ge 14) {
            Write-Check WARN "RAM total: $ramGB GB" 'Suficiente con arranque escalonado'
            $warnings++
        }
        else {
            Write-Check FAIL "RAM total: $ramGB GB" 'Menos de 14 GB no sostiene la cadena completa'
            $failures++
        }
    }
    catch {
        Write-Check INFO 'RAM no verificable en este sistema'
    }

    # Python
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }

    if ($python) {
        Write-Check OK "Python: $($python.Source)"

        $requestsCode = -1
        $requestsOutput = ''
        $previousEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $requestsOutput = (& $python.Source -c 'import requests; print(requests.__version__)' 2>&1) -join ' '
            $requestsCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousEap
        }

        if ($requestsCode -eq 0) {
            Write-Check OK "requests $($requestsOutput.Trim())"
        }
        else {
            Write-Check WARN 'Paquete requests ausente' 'pip install requests'
            $warnings++
        }
    }
    else {
        Write-Check FAIL 'Python no encontrado' 'Necesario para tenable_scan.py'
        $failures++
    }

    if (Get-Command ssh -ErrorAction SilentlyContinue) {
        Write-Check OK 'Cliente OpenSSH disponible'
    }
    else {
        Write-Check WARN 'Cliente ssh no encontrado' 'Opcional: se puede provisionar desde kali'
        $warnings++
    }

    $vms = @(Get-LabVms)
    Write-Check INFO ("VMs detectadas: {0}" -f $(if ($vms.Count) { ($vms.Name -join ', ') } else { 'ninguna todavia' }))

    Write-Host ''
    if ($failures -gt 0) {
        Write-Host "  VEREDICTO: $failures bloqueante(s), $warnings advertencia(s)." -ForegroundColor Red
        exit 1
    }
    if ($warnings -gt 0) {
        Write-Host "  VEREDICTO: listo con $warnings advertencia(s)." -ForegroundColor Yellow
        exit 0
    }
    Write-Host '  VEREDICTO: entorno listo.' -ForegroundColor Green
    exit 0
}

function Invoke-Status {
    Write-Section 'VMs del laboratorio'
    $vms = @(Get-LabVms)
    if ($vms.Count -eq 0) {
        Write-Check WARN "Sin VMs en $script:LabRoot" 'Sigue buildsheets/'
        return
    }

    $running = @(Get-RunningVms)

    foreach ($vm in $vms) {
        $state = if ($running -contains $vm.Path) { 'ENCENDIDA' } else { 'apagada' }
        $snaps = @(Get-VmSnapshots -VmxPath $vm.Path)
        $snapText = if ($snaps.Count) { $snaps -join ', ' } else { 'sin snapshots' }
        $color = if ($running -contains $vm.Path) { 'Green' } else { 'DarkGray' }
        Write-Host ('  {0,-10} {1,-12} {2}' -f $vm.Name, $state, $snapText) -ForegroundColor $color
    }
}

function Get-TargetVms {
    if (-not $Target) { throw "Indica una VM o 'all'." }
    if ($Target -eq 'all') { return @(Get-LabVms) }
    return @(Resolve-LabVm -Name $Target)
}

function Invoke-Start {
    foreach ($vm in (Get-TargetVms)) {
        Write-Host "  encendiendo $($vm.Name)..." -NoNewline
        $r = Invoke-Vmrun -Arguments @('start', $vm.Path, 'nogui') -AllowFail
        if ($r.ExitCode -eq 0) { Write-Host ' OK' -ForegroundColor Green }
        else {
            Write-Host ' FALLO' -ForegroundColor Red
            Write-Host "    $($r.Text)" -ForegroundColor DarkRed
        }
    }
}

function Invoke-Stop {
    foreach ($vm in (Get-TargetVms)) {
        Write-Host "  apagando $($vm.Name)..." -NoNewline
        $r = Invoke-Vmrun -Arguments @('stop', $vm.Path, 'soft') -AllowFail
        if ($r.ExitCode -ne 0) {
            $r = Invoke-Vmrun -Arguments @('stop', $vm.Path, 'hard') -AllowFail
        }
        if ($r.ExitCode -eq 0) { Write-Host ' OK' -ForegroundColor Green }
        else {
            Write-Host ' FALLO' -ForegroundColor Red
            Write-Host "    $($r.Text)" -ForegroundColor DarkRed
        }
    }
}

function Invoke-Snapshot {
    foreach ($vm in (Get-TargetVms)) {
        $existing = @(Get-VmSnapshots -VmxPath $vm.Path)
        if ($existing -contains $script:SnapshotLabel) {
            Write-Check WARN "$($vm.Name): el snapshot '$script:SnapshotLabel' ya existe" 'Se conserva; usa otro nombre si quieres rehacerlo'
            continue
        }
        Write-Host "  snapshot $($vm.Name) -> $script:SnapshotLabel ..." -NoNewline
        $r = Invoke-Vmrun -Arguments @('snapshot', $vm.Path, $script:SnapshotLabel) -AllowFail
        if ($r.ExitCode -eq 0) { Write-Host ' OK' -ForegroundColor Green }
        else {
            Write-Host ' FALLO' -ForegroundColor Red
            Write-Host "    $($r.Text)" -ForegroundColor DarkRed
        }
    }
}

function Invoke-Reset {
    $running = @(Get-RunningVms)

    foreach ($vm in (Get-TargetVms)) {
        $existing = @(Get-VmSnapshots -VmxPath $vm.Path)
        if ($existing -notcontains $script:SnapshotLabel) {
            Write-Check FAIL "$($vm.Name): no existe el snapshot '$script:SnapshotLabel'" "Crealo primero: .\bifrost.ps1 snapshot $($vm.Name)"
            continue
        }

        Write-Host "  revirtiendo $($vm.Name) a '$script:SnapshotLabel'..." -NoNewline
        if ($running -contains $vm.Path) {
            Invoke-Vmrun -Arguments @('stop', $vm.Path, 'hard') -AllowFail | Out-Null
        }
        $r = Invoke-Vmrun -Arguments @('revertToSnapshot', $vm.Path, $script:SnapshotLabel) -AllowFail
        if ($r.ExitCode -eq 0) { Write-Host ' OK' -ForegroundColor Green }
        else {
            Write-Host ' FALLO' -ForegroundColor Red
            Write-Host "    $($r.Text)" -ForegroundColor DarkRed
        }
    }
    Write-Host ''
    Write-Check INFO 'Las VMs quedan apagadas en el estado del snapshot.'
}

function Invoke-Ip {
    foreach ($vm in (Get-TargetVms)) {
        $r = Invoke-Vmrun -Arguments @('getGuestIPAddress', $vm.Path, '-wait') -AllowFail
        $ip = if ($r.ExitCode -eq 0 -and $r.Lines.Count) { $r.Lines[0] } else { 'sin IP (VM apagada o sin VMware Tools)' }
        Write-Host ('  {0,-10} {1}' -f $vm.Name, $ip)
    }
}

function Invoke-Scan {
    $script_ = Join-Path $PSScriptRoot 'tenable/tenable_scan.py'
    if (-not (Test-Path -LiteralPath $script_)) { throw "No existe $script_" }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $python) { throw 'Python no encontrado.' }

    & $python.Source $script_ @Rest
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #

switch ($Command.ToLowerInvariant()) {
    'preflight' { Invoke-Preflight }
    'config' { Invoke-Config }
    'status' { Invoke-Status }
    'start' { Invoke-Start }
    'stop' { Invoke-Stop }
    'snapshot' { Invoke-Snapshot }
    'snap' { Invoke-Snapshot }
    'reset' { Invoke-Reset }
    'revert' { Invoke-Reset }
    'ip' { Invoke-Ip }
    'scan' { Invoke-Scan }
    'list' { Get-LabVms | Format-Table Name, Path -AutoSize }
    default {
        Write-Host @"
Bifrost - control del laboratorio (VMware Workstation / Fusion)

  .\bifrost.ps1 preflight            Verifica entorno, red y disco
  .\bifrost.ps1 config               Valores efectivos (secretos ocultos)
  .\bifrost.ps1 status               VMs y snapshots
  .\bifrost.ps1 start <vm|all>       Enciende sin GUI
  .\bifrost.ps1 stop <vm|all>        Apaga
  .\bifrost.ps1 snapshot <vm|all>    Crea snapshot (etiqueta: BIFROST_SNAPSHOT)
  .\bifrost.ps1 reset <vm|all>       Revierte al snapshot
  .\bifrost.ps1 ip <vm|all>          IP de la VM
  .\bifrost.ps1 scan -- <args>       Pasa argumentos a tenable_scan.py

Valores: config/lab.env  (unica fuente de verdad)
"@ -ForegroundColor Gray
    }
}
