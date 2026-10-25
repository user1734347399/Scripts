<#
Objetivo:
    Dar a los usuarios NO administradores los permisos para ver y usar el icono
    de WireGuard en la barra: los agrega al grupo local "Operadores de red"
    (por SID, independiente del idioma) y escribe la clave de registro
    LimitedOperatorUI. Recorre todos los perfiles de usuario de la PC.
Notas:
    - Consola limpia ("Por favor espere...") + resumen final; el detalle va al log.
    - Log: C:\ProgramData\IT\Wireguard\log.txt
    - Requiere permisos de administrador. Despues de correrlo, reiniciar la PC.
    - Usa ADSI por SID para no romperse con SIDs huerfanos (evita el error 1789).
#>

# Version: cambiar solo este numero al sacar una nueva version (alimenta el titulo y el log)
$version = "05"
try { $Host.UI.RawUI.WindowTitle = $version } catch {}

# --- Configuracion ---
$groupSID = "S-1-5-32-556"  # Operadores de red
$adminSID = "S-1-5-32-544"  # Administradores
$regPath  = "HKLM:\Software\WireGuard"
$logDir   = "C:\ProgramData\IT\Wireguard"
$logPath  = Join-Path $logDir "log.txt"
$TiempoMaximoTotalSeg = 120
$reloj = [Diagnostics.Stopwatch]::StartNew()

# --- Preparar log ---
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
function Write-Log($msg) {
    try { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) | Add-Content -Path $logPath -Encoding utf8 } catch {}
}
("===== WireGuard - Agregar permisos (v{0}) =====" -f $version) | Set-Content -Path $logPath -Encoding utf8 -ErrorAction SilentlyContinue
Write-Log ("Equipo: {0}  Contexto: {1}" -f $env:COMPUTERNAME, [Security.Principal.WindowsIdentity]::GetCurrent().Name)

# --- Consola: unico mensaje durante el proceso ---
Write-Host "`nPor favor espere..." -ForegroundColor Yellow

function Salir-ConError($mensaje) {
    Write-Log ("ERROR FATAL: {0}" -f $mensaje)
    Write-Host "`nERROR: no se pudo completar." -ForegroundColor Red
    Write-Host $mensaje -ForegroundColor Red
    Write-Host ("`nRevisa el detalle en: {0}" -f $logPath) -ForegroundColor Red
    Start-Sleep -Seconds 4
    exit 1
}

function Get-MiembrosSID($grupoADSI) {
    $sids = @()
    try { $miembros = @($grupoADSI.Invoke("Members")) } catch { $miembros = @() }
    foreach ($m in $miembros) {
        try {
            $bytes = $m.GetType().InvokeMember("objectSid", 'GetProperty', $null, $m, $null)
            $sids += (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
        } catch { }
    }
    return $sids
}

# --- Resolver grupos por SID ---
try {
    $groupName      = (Get-LocalGroup | Where-Object { $_.SID -eq $groupSID }).Name
    $adminGroupName = (Get-LocalGroup | Where-Object { $_.SID -eq $adminSID }).Name
    if (-not $groupName -or -not $adminGroupName) { throw }
} catch {
    Salir-ConError "No se encontraron los grupos locales necesarios."
}
Write-Log ("Grupo destino: {0}" -f $groupName)

# --- Instanciar grupos y leer membresias (por SID) ---
try {
    $groupADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    $adminADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
    $adminSIDs = Get-MiembrosSID $adminADSI
    $groupSIDs = Get-MiembrosSID $groupADSI
} catch {
    Salir-ConError "No se pudo leer la membresia de los grupos locales."
}

# --- Buscar perfiles de usuario ---
$profiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue | Where-Object {
    $_.PSChildName -like "S-1-5-21-*" -and
    $_.PSChildName -notlike "*.bak" -and
    $_.PSChildName -notlike "*-500"
}
Write-Log ("Perfiles encontrados: {0}" -f @($profiles).Count)

# --- Procesar ---
$agregados = @()
$yaTenian  = @()
$noSePudo  = @()

foreach ($prof in $profiles) {
    if ($reloj.Elapsed.TotalSeconds -gt $TiempoMaximoTotalSeg) {
        Write-Log "Se supero el tiempo maximo total; se corta el procesamiento."
        break
    }
    $userSID = $prof.PSChildName
    $nombre  = Split-Path -Leaf $prof.ProfileImagePath

    if ($adminSIDs -contains $userSID) {
        Write-Log ("{0} -> es administrador, se omite" -f $nombre)
        continue
    }
    if ($groupSIDs -contains $userSID) {
        Write-Log ("{0} -> ya tenia permisos" -f $nombre)
        $yaTenian += $nombre
        continue
    }
    try {
        $groupADSI.Add("WinNT://$userSID")
        Write-Log ("{0} -> agregado" -f $nombre)
        $agregados += $nombre
    } catch {
        Write-Log ("{0} -> ERROR al agregar: {1}" -f $nombre, $_.Exception.Message)
        $noSePudo += $nombre
    }
}

# --- Clave de registro ---
$regOK = $false
try {
    if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
    New-ItemProperty -Path $regPath -Name "LimitedOperatorUI" -Value 1 -PropertyType DWORD -Force | Out-Null
    $regOK = $true
    Write-Log "Registro LimitedOperatorUI = 1"
} catch {
    Write-Log ("ERROR al escribir el registro: {0}" -f $_.Exception.Message)
}

# --- Verificacion: releer el grupo y confirmar lo agregado ---
try {
    $groupSIDsFinal = Get-MiembrosSID ([ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group")
    foreach ($prof in $profiles) {
        $nombre = Split-Path -Leaf $prof.ProfileImagePath
        if (($agregados -contains $nombre) -and ($groupSIDsFinal -notcontains $prof.PSChildName)) {
            $agregados = $agregados | Where-Object { $_ -ne $nombre }
            $noSePudo += $nombre
            Write-Log ("{0} -> VERIFICACION: no quedo en el grupo" -f $nombre)
        }
    }
} catch {
    Write-Log ("No se pudo verificar la membresia final: {0}" -f $_.Exception.Message)
}

Write-Log ("Resultado: {0} agregados, {1} ya tenian, {2} con error" -f $agregados.Count, $yaTenian.Count, $noSePudo.Count)

# --- Resumen en consola ---
if ($noSePudo.Count -gt 0) {
    Write-Host "`nSe completo con observaciones." -ForegroundColor Yellow
} elseif ($agregados.Count -eq 0 -and $yaTenian.Count -gt 0) {
    Write-Host "`nLos usuarios ya tenian los permisos." -ForegroundColor Green
} elseif ($agregados.Count -eq 0 -and $yaTenian.Count -eq 0) {
    Write-Host "`nNo habia usuarios para agregar." -ForegroundColor Yellow
} else {
    Write-Host "`nPermisos de WireGuard aplicados correctamente." -ForegroundColor Green
}

if ($agregados.Count -gt 0) {
    Write-Host ("`n{0} usuarios agregados:" -f $agregados.Count) -ForegroundColor Green
    $agregados | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Green }
}
if ($yaTenian.Count -gt 0) {
    Write-Host ("`n{0} ya tenian permisos:" -f $yaTenian.Count) -ForegroundColor Cyan
    $yaTenian | ForEach-Object { Write-Host ("  - {0}" -f $_) -ForegroundColor Cyan }
}
if ($noSePudo.Count -gt 0) {
    Write-Host ("`n{0} no se pudo agregar:" -f $noSePudo.Count) -ForegroundColor Yellow
    $noSePudo | ForEach-Object { Write-Host ("  - {0}  (ver log)" -f $_) -ForegroundColor Yellow }
}

if ($regOK) {
    Write-Host "`nClave de registro: OK" -ForegroundColor Green
} else {
    Write-Host "`nClave de registro: ERROR (ver log)" -ForegroundColor Yellow
}

Write-Host ("Log: {0}" -f $logPath) -ForegroundColor Gray
Write-Host "`nFalta reiniciar la PC." -ForegroundColor Green

Start-Sleep -Seconds 4
if ($noSePudo.Count -gt 0 -or -not $regOK) { exit 2 } else { exit 0 }
