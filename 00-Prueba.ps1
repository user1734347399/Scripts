<#
Objetivo:
    Script de prueba: muestra con qué identidad corre (whoami) y la versión de
    PowerShell, para verificar el contexto de ejecución (SYSTEM en Action1).
Notas:
    No modifica nada en el equipo.
#>

$ErrorActionPreference = 'Stop'
$TiempoMaximoTotalSeg = 60
$TimeoutPasoSeg       = 15
$reloj = [Diagnostics.Stopwatch]::StartNew()

function Test-TiempoTotal {
    if ($reloj.Elapsed.TotalSeconds -gt $TiempoMaximoTotalSeg) {
        Write-Output "ERROR: se superó el tiempo máximo total ($TiempoMaximoTotalSeg s)."
        exit 2
    }
}

try {
    # Paso 1: whoami (proceso externo, con timeout)
    Write-Output '== Paso 1: whoami =='
    $salida = Join-Path $env:TEMP ("whoami_{0}.txt" -f [guid]::NewGuid())
    $p = Start-Process -FilePath "$env:SystemRoot\System32\whoami.exe" -NoNewWindow -PassThru `
        -RedirectStandardOutput $salida
    if (-not $p.WaitForExit($TimeoutPasoSeg * 1000)) {
        $p.Kill()
        throw "whoami superó el timeout de $TimeoutPasoSeg s."
    }
    Write-Output ("whoami: {0}" -f (Get-Content $salida -Raw).Trim())
    Remove-Item $salida -Force -ErrorAction SilentlyContinue
    Test-TiempoTotal

    # Paso 2: versión de PowerShell
    Write-Output '== Paso 2: versión de PowerShell =='
    Write-Output ("PSVersion: {0}" -f $PSVersionTable.PSVersion)
    Write-Output ("PSEdition: {0}" -f $PSVersionTable.PSEdition)
    Write-Output ("Proceso 64 bits: {0}" -f [Environment]::Is64BitProcess)
    Test-TiempoTotal

    Write-Output ("OK en {0:N1} s." -f $reloj.Elapsed.TotalSeconds)
    exit 0
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}
