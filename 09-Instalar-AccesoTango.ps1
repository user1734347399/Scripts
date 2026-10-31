<#
Objetivo:
    Preparar el equipo para el acceso remoto a Tango CSByA (ITSur):
     1) Verificar / crear la carpeta C:\ITSur\AccesoTango
     2) Verificar cloudflared y, si no esta, instalarlo con winget
Notas:
    Ejecutar UNA VEZ como administrador (lo lanza el CMD con autoelevacion).
    Los archivos (Conectar-Tango.ps1, Tango-CSByA.rdp, 01-Tsclient.ps1)
    se copian a mano a la carpeta.
    Exit 0 = OK / 1 = no se pudo crear la carpeta / 2 = cloudflared no quedo instalado.
#>

$Destino = "C:\ITSur\AccesoTango"

# --- 1) Carpeta de destino ---------------------------------------------
if (Test-Path $Destino) {
    Write-Output "[OK] La carpeta ya existe: $Destino"
} else {
    try {
        New-Item -ItemType Directory -Path $Destino -Force -ErrorAction Stop | Out-Null
        Write-Output "[OK] Carpeta creada: $Destino"
    } catch {
        Write-Output "[ERROR] No se pudo crear $Destino : $($_.Exception.Message)"
        exit 1
    }
}

# --- 2) cloudflared ----------------------------------------------------
function Buscar-Cloudflared {
    $cmd = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($ruta in @("${env:ProgramFiles(x86)}\cloudflared\cloudflared.exe",
                        "$env:ProgramFiles\cloudflared\cloudflared.exe")) {
        if (Test-Path $ruta) { return $ruta }
    }
    return $null
}

$Exe = Buscar-Cloudflared
if ($Exe) {
    Write-Output "[OK] cloudflared ya instalado: $Exe"
    exit 0
}

Write-Output "[..] cloudflared no esta instalado. Instalando con winget..."
if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
    Write-Output "[ERROR] winget no esta disponible en este equipo. Instalar cloudflared a mano."
    exit 2
}

winget install --id Cloudflare.cloudflared -e --silent --accept-source-agreements --accept-package-agreements

# Refrescar el PATH de esta consola para no tener que reabrirla
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')

$Exe = Buscar-Cloudflared
if ($Exe) {
    Write-Output "[OK] cloudflared instalado: $Exe"
    exit 0
}

Write-Output "[ERROR] winget termino pero no se encuentra cloudflared.exe. Revisar la salida de winget."
exit 2
