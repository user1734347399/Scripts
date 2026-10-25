<#
Objetivo:
    Instala WireGuard (MSI empaquetado junto a este script) si no esta presente,
    y luego da a los usuarios NO administradores los permisos para ver y usar el
    icono de WireGuard en la barra: los agrega al grupo local "Operadores de red"
    (por SID, independiente del idioma) y escribe la clave de registro
    LimitedOperatorUI. Recorre todos los perfiles de usuario de la PC.
Notas:
    - Consola limpia ("Por favor espere...") + resumen final; el detalle va al log.
    - Log: C:\ProgramData\IT\Wireguard\log.txt
    - El instalador wireguard.msi debe estar junto a este script (lo extrae el SFX).
    - Instalacion silenciosa con timeout, no cuelga. Requiere permisos de admin.
    - Despues de correrlo, reiniciar la PC.
    - Usa ADSI por SID para no romperse con SIDs huerfanos (evita el error 1789).
#>

# Version: cambiar solo este numero al sacar una nueva version (alimenta el titulo y el log)
$version = "06"
try { $Host.UI.RawUI.WindowTitle = $version } catch {}

# --- Configuracion ---
$groupSID = "S-1-5-32-556"  # Operadores de red
$adminSID = "S-1-5-32-544"  # Administradores
$regPath  = "HKLM:\Software\WireGuard"
$logDir   = "C:\ProgramData\IT\Wireguard"
$logPath  = Join-Path $logDir "log.txt"
$msiPath  = Join-Path $PSScriptRoot "wireguard.msi"
$InstallTimeoutSeg    = 180
$TiempoMaximoTotalSeg = 300
$reloj = [Diagnostics.Stopwatch]::StartNew()

# --- Preparar log ---
try { if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } } catch {}
function Write-Log($msg) {
    try { ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) | Add-Content -Path $logPath -Encoding utf8 } catch {}
}
("===== WireGuard - Instalar + Agregar permisos (v{0}) =====" -f $version) | Set-Content -Path $logPath -Encoding utf8 -ErrorAction SilentlyContinue
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

# --- Deteccion robusta: varias señales ---
function Test-WireGuardInstalado {
    # 1) Binario principal (ancla)
    $exe = Test-Path (Join-Path $env:ProgramFiles "WireGuard\wireguard.exe")
    # 2) Clave de desinstalacion por GUID dinamico: busca por DisplayName, NO por nombre de clave
    #    (el servicio de WireGuard cambia de nombre entre versiones, por eso no se usa como senal)
    $clave = $false
    foreach ($raiz in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )) {
        try {
            if (Get-ItemProperty $raiz -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "WireGuard*" }) { $clave = $true; break }
        } catch { }
    }
    [ordered]@{
        Ejecutable     = $exe
        ClaveUninstall = $clave
    }
}

# ===================== PASO 1: Instalacion =====================
$s = Test-WireGuardInstalado
Write-Log ("Deteccion -> Ejecutable={0}  ClaveUninstall={1}" -f $s.Ejecutable, $s.ClaveUninstall)
$instalado = $s.Ejecutable -or $s.ClaveUninstall

$estadoInstalacion = ""   # para el resumen
if ($instalado) {
    Write-Log "WireGuard ya estaba instalado, se omite la instalacion"
    $estadoInstalacion = "WireGuard ya estaba instalado."
} else {
    Write-Log "WireGuard no detectado, se procede a instalar"
    if (-not (Test-Path $msiPath)) {
        Salir-ConError "No se encontro el instalador (wireguard.msi) junto al script."
    }
    try {
        $p = Start-Process -FilePath "msiexec.exe" -ArgumentList @('/i', ('"{0}"' -f $msiPath), '/qn', '/norestart') -PassThru -WindowStyle Hidden
    } catch {
        Salir-ConError ("No se pudo iniciar la instalacion: {0}" -f $_.Exception.Message)
    }
    if (-not $p.WaitForExit($InstallTimeoutSeg * 1000)) {
        try { $p.Kill() } catch {}
        Salir-ConError ("La instalacion supero el tiempo limite de {0}s." -f $InstallTimeoutSeg)
    }
    $code = $p.ExitCode
    Write-Log ("msiexec exit code: {0}" -f $code)
    if ($code -eq 0 -or $code -eq 3010) {
        $estadoInstalacion = "WireGuard instalado correctamente."
        Write-Log "WireGuard instalado"
    } elseif ($code -eq 1638) {
        $estadoInstalacion = "WireGuard ya estaba instalado (otra version)."
        Write-Log "Ya habia una version instalada (1638)"
    } else {
        Salir-ConError ("Fallo la instalacion de WireGuard (codigo {0})." -f $code)
    }
    # Re-verificar que quedo
    $s2 = Test-WireGuardInstalado
    Write-Log ("Re-deteccion -> Ejecutable={0}  ClaveUninstall={1}" -f $s2.Ejecutable, $s2.ClaveUninstall)
    if (-not ($s2.Ejecutable -or $s2.ClaveUninstall)) {
        Salir-ConError "Despues de instalar no se detecta WireGuard en la PC."
    }
}

# ===================== PASO 2: Permisos =====================
try {
    $groupName      = (Get-LocalGroup | Where-Object { $_.SID -eq $groupSID }).Name
    $adminGroupName = (Get-LocalGroup | Where-Object { $_.SID -eq $adminSID }).Name
    if (-not $groupName -or -not $adminGroupName) { throw }
} catch {
    Salir-ConError "No se encontraron los grupos locales necesarios."
}
Write-Log ("Grupo destino: {0}" -f $groupName)

try {
    $groupADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
    $adminADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
    $adminSIDs = Get-MiembrosSID $adminADSI
    $groupSIDs = Get-MiembrosSID $groupADSI
} catch {
    Salir-ConError "No se pudo leer la membresia de los grupos locales."
}

$profiles = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue | Where-Object {
    $_.PSChildName -like "S-1-5-21-*" -and
    $_.PSChildName -notlike "*.bak" -and
    $_.PSChildName -notlike "*-500"
}
Write-Log ("Perfiles encontrados: {0}" -f @($profiles).Count)

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

# --- Verificacion de la membresia ---
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

# ===================== Resumen en consola =====================
# Linea de instalacion
Write-Host ("`n{0}" -f $estadoInstalacion) -ForegroundColor Green

# Linea de permisos
if ($noSePudo.Count -gt 0) {
    Write-Host "Permisos: se completo con observaciones." -ForegroundColor Yellow
} elseif ($agregados.Count -eq 0 -and $yaTenian.Count -gt 0) {
    Write-Host "Permisos: los usuarios ya los tenian." -ForegroundColor Green
} elseif ($agregados.Count -eq 0 -and $yaTenian.Count -eq 0) {
    Write-Host "Permisos: no habia usuarios para agregar." -ForegroundColor Yellow
} else {
    Write-Host "Permisos aplicados correctamente." -ForegroundColor Green
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
