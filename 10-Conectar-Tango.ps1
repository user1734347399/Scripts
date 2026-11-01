<#
Objetivo:
    Acceso remoto a Tango CSByA en un solo script:
     1) Verificar que exista la carpeta %USERPROFILE%\Tango
     2) Montarla como unidad P: (subst) para que el RDP la redirija
        a TangoCSByA como \\tsclient\P
     3) Levantar el tunel de Cloudflare (cloudflared access rdp)
     4) Abrir la sesion RDP con Tango-CSByA.rdp
Notas:
    Ejecutar SIN elevar (el subst de un proceso elevado no lo ve mstsc).
    Ante cualquier error: lo muestra en consola, espera 3 segundos y
    abre un aviso que queda en pantalla hasta que se acepte.
#>

$HostnameCF  = "rdp-csbya.oilone.net"
$PuertoLocal = 3390
$RdpFile     = Join-Path $PSScriptRoot "Tango-CSByA.rdp"
$TimeoutSeg  = 30
$Carpeta     = Join-Path $env:USERPROFILE "Tango"
$Letra       = "P:"

$Shell = New-Object -ComObject WScript.Shell

function Mostrar-Error($Mensaje) {
    Write-Host ""
    Write-Host "[ERROR] $Mensaje" -ForegroundColor Red
    Start-Sleep -Seconds 3
    try { $Shell.Popup($Mensaje, 0, "Acceso Tango - Error", 16) | Out-Null } catch {}
    exit 1
}

function Test-Listener {
    $c = Get-NetTCPConnection -LocalPort $PuertoLocal -State Listen -ErrorAction SilentlyContinue
    return ($null -ne $c)
}

# --- 1) Verificar la carpeta -------------------------------------------
if (-not (Test-Path -LiteralPath $Carpeta -PathType Container)) {
    Mostrar-Error "No existe la carpeta: $Carpeta`n`nContactar a soporte de ITSur."
}

# --- 2) Montar la carpeta como P: --------------------------------------
try {
    $null = & subst.exe $Letra /D 2>&1
    $salida = & subst.exe $Letra $Carpeta 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$Letra\")) {
        Mostrar-Error "No se pudo montar la unidad $Letra en $Carpeta.`n$salida`n`nContactar a soporte de ITSur."
    }
} catch {
    Mostrar-Error "Error al montar la unidad $Letra : $($_.Exception.Message)`n`nContactar a soporte de ITSur."
}

# --- 3) Ubicar cloudflared ---------------------------------------------
$Exe = (Get-Command cloudflared.exe -ErrorAction SilentlyContinue).Source

if (-not $Exe) {
    $Rutas = @(
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\cloudflared.exe"
    )
    foreach ($r in $Rutas) {
        if (Test-Path $r) { $Exe = $r; break }
    }
}

if (-not $Exe) {
    Mostrar-Error "No se encontro cloudflared en esta PC.`n`nContactar a soporte de ITSur."
}

if (-not (Test-Path -LiteralPath $RdpFile)) {
    Mostrar-Error "Falta el archivo: $RdpFile`n`nContactar a soporte de ITSur."
}

# --- 4) Levantar el tunel si no esta activo ----------------------------
if (-not (Test-Listener)) {

    $ArgsCF = @(
        "access", "rdp",
        "--hostname", $HostnameCF,
        "--url", "rdp://localhost:$PuertoLocal"
    )

    try {
        Start-Process -FilePath $Exe -ArgumentList $ArgsCF -WindowStyle Hidden -ErrorAction Stop
    } catch {
        Mostrar-Error "No se pudo iniciar cloudflared: $($_.Exception.Message)`n`nContactar a soporte de ITSur."
    }

    $Esperado = 0
    while ((-not (Test-Listener)) -and ($Esperado -lt $TimeoutSeg)) {
        Start-Sleep -Seconds 1
        $Esperado++
    }

    if (-not (Test-Listener)) {
        Mostrar-Error ("No se pudo establecer la conexion en $TimeoutSeg segundos.`n`n" +
                       "Verificar que haya internet. Si el problema persiste, " +
                       "contactar a soporte de ITSur.")
    }
}

# --- 5) Abrir la sesion RDP --------------------------------------------
try {
    Start-Process -FilePath "mstsc.exe" -ArgumentList "`"$RdpFile`"" -ErrorAction Stop
} catch {
    Mostrar-Error "No se pudo abrir el Escritorio remoto: $($_.Exception.Message)`n`nContactar a soporte de ITSur."
}

exit 0
