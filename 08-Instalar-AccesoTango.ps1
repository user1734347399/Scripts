<#
Objetivo:
    Instalador del acceso remoto a Tango CSByA (ITSur).
    Verifica que cloudflared este instalado y copia Conectar-Tango.ps1
    y Tango-CSByA.rdp a C:\ITSur\AccesoTango.
Notas:
    Ejecutar UNA VEZ como administrador en el equipo del usuario.
    Dejar los archivos en la misma carpeta que este script.
    El acceso directo y el lanzador (01-Tsclient.ps1) se documentan aparte.
#>

$Destino = "C:\ITSur\AccesoTango"
$Origen  = $PSScriptRoot

# --- Verificar cloudflared --------------------------------------------
$Exe = (Get-Command cloudflared.exe -ErrorAction SilentlyContinue).Source
if (-not $Exe) {
    Write-Host "cloudflared no esta instalado. Instalando..." -ForegroundColor Yellow
    winget install --id Cloudflare.cloudflared --accept-source-agreements --accept-package-agreements
    Write-Host "Cerrar y reabrir PowerShell, luego volver a ejecutar este script." -ForegroundColor Cyan
    exit 0
}
Write-Host "cloudflared encontrado en: $Exe" -ForegroundColor Green

# --- Copiar archivos ---------------------------------------------------
if (-not (Test-Path $Destino)) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
}

Copy-Item (Join-Path $Origen "Conectar-Tango.ps1") -Destination $Destino -Force
Copy-Item (Join-Path $Origen "Tango-CSByA.rdp")    -Destination $Destino -Force

Write-Host "Archivos copiados a $Destino" -ForegroundColor Green

exit
