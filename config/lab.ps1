#Requires -Version 5.1
<#
.SYNOPSIS
    config/lab.ps1 - carga de config/lab.env para todos los scripts PowerShell.

.DESCRIPTION
    Parser deliberadamente simple: CLAVE="valor", comentarios con #, sin secciones.
    Devuelve una hashtable con las mismas claves que ve bash, para que los valores
    del laboratorio sean identicos en los dos ecosistemas.

.EXAMPLE
    . .\config\lab.ps1
    $cfg = Import-BifrostLabConfig -Root $PSScriptRoot
    $cfg['BIFROST_IP_WEB']
#>

$script:BifrostRequiredKeys = @(
    'BIFROST_NETWORK', 'BIFROST_PREFIX', 'BIFROST_GATEWAY',
    'BIFROST_IP_KALI', 'BIFROST_IP_SCANNER', 'BIFROST_IP_WEB',
    'BIFROST_IP_APP', 'BIFROST_IP_DC', 'BIFROST_IP_WS',
    'BIFROST_DOMAIN', 'BIFROST_NETBIOS',
    'BIFROST_SVC_USER', 'BIFROST_SVC_PASS',
    'BIFROST_APP_USER', 'BIFROST_APP_PASS',
    'BIFROST_CROWN_JEWEL', 'BIFROST_SHARE_PATH',
    'BIFROST_SOLR_PORT', 'BIFROST_LDAP_PORT', 'BIFROST_HTTP_PORT',
    'BIFROST_REVSHELL_PORT', 'BIFROST_PROBE_PORT',
    'BIFROST_SOLR_VERSION', 'BIFROST_VM_DIR', 'BIFROST_SNAPSHOT'
)

function Import-BifrostLabConfig {
    [CmdletBinding()]
    param(
        [string] $Root = '',
        [string] $Path
    )

    if (-not $Root) { $Root = (Get-Location).Path }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($Path) { $candidates.Add($Path) }
    if ($env:BIFROST_CONFIG) { $candidates.Add($env:BIFROST_CONFIG) }

    # Desde la raiz del repo y desde un subdirectorio (p.ej. windows/).
    $dir = $Root
    for ($i = 0; $i -lt 5; $i++) {
        $candidates.Add((Join-Path $dir 'config/lab.env'))
        $candidates.Add((Join-Path $dir 'lab.env'))
        $parent = Split-Path -Parent $dir
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    $candidates.Add('/tmp/bifrost-lab.env')

    $file = $candidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1

    if (-not $file) {
        throw ("No se encontro config/lab.env. Definie BIFROST_CONFIG o ejecuta " +
               "desde la raiz del repositorio.")
    }

    $config = @{}
    foreach ($line in (Get-Content -LiteralPath $file -Encoding UTF8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) { continue }

        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { continue }

        $key = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim()

        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }
        $config[$key] = $value
    }

    $missing = $script:BifrostRequiredKeys | Where-Object {
        -not $config.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($config[$_])
    }
    if ($missing) {
        throw ("Faltan claves obligatorias en ${file}: " + ($missing -join ', '))
    }

    $config['__PATH__'] = $file
    $config['__ROOT__'] = Split-Path -Parent (Split-Path -Parent $file)
    return $config
}

function Resolve-BifrostSetting {
    <#
        Prioridad: parametro explicito > config/lab.env > valor por defecto.
        Con -Required no hay valor por defecto: si no hay configuracion, falla con
        instrucciones. Asi ningun script de Windows duplica valores del laboratorio.
    #>
    [CmdletBinding()]
    param(
        [string] $Explicit,
        [string] $Key,
        [string] $Default,
        [hashtable] $Config,
        [switch] $Required
    )

    if ($Explicit) { return $Explicit }
    if ($Config -and $Config.ContainsKey($Key) -and $Config[$Key]) { return $Config[$Key] }
    if ($Default) { return $Default }
    if ($Required) {
        throw ("Falta '$Key'. Copia la carpeta config\ junto a windows\ en la VM " +
               "(ver buildsheets/windows-vms.md) o pasa el parametro equivalente.")
    }
    return ''
}

function Get-BifrostVmDir {
    [CmdletBinding()]
    param([hashtable] $Config)

    $raw = if ($env:BIFROST_VM_DIR) { $env:BIFROST_VM_DIR } else { $Config['BIFROST_VM_DIR'] }
    $root = $Config['__ROOT__']

    if ([System.IO.Path]::IsPathRooted($raw)) { return $raw }
    return [System.IO.Path]::GetFullPath((Join-Path $root $raw))
}
