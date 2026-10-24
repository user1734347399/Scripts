<#
Objetivo:
    Probar 10-Instalar-Cortex.ps1 en el runner SIN instalar Cortex:
      1) Sintaxis con el parser de PowerShell 5.1.
      2) Copia en modo prueba ($TestMode = $true): descarga + extraccion reales, sin instalar.
      3) Copia que salta directo al bloque de aviso + reinicio (simula instalacion OK),
         corrida con PowerShell de 32 bits como Action1. Se verifica que el reinicio
         quedo programado y se cancela con shutdown /a.
Notas:
    Las copias se generan en $env:TEMP y se borran al final. Exit 0 = todo OK.
#>

$ErrorActionPreference = 'Stop'
$TiempoMaximoTotalSeg = 560
$reloj = [Diagnostics.Stopwatch]::StartNew()

$Script   = Join-Path $PSScriptRoot '10-Instalar-Cortex.ps1'
$Ps32     = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
$Ps64     = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Shutdown = Join-Path $env:WINDIR 'System32\shutdown.exe'
$Fallos   = New-Object System.Collections.Generic.List[string]
$Temps    = New-Object System.Collections.Generic.List[string]

function Test-TiempoTotal {
    if ($reloj.Elapsed.TotalSeconds -gt $TiempoMaximoTotalSeg) {
        Write-Output "ERROR: se supero el tiempo maximo total ($TiempoMaximoTotalSeg s)."
        & $Shutdown /a 2>$null
        exit 2
    }
}

function Invoke-Copia {
    # Corre una copia modificada del script y devuelve exit code + salida
    param([string]$Contenido, [string]$PsExe, [int]$TimeoutSeg)
    $id  = [guid]::NewGuid().ToString('N')
    $ps1 = Join-Path $env:TEMP "cortex10_$id.ps1"
    $out = Join-Path $env:TEMP "cortex10_$id.out"
    $err = Join-Path $env:TEMP "cortex10_$id.err"
    $Temps.Add($ps1); $Temps.Add($out); $Temps.Add($err)
    Set-Content -LiteralPath $ps1 -Value $Contenido -Encoding ascii
    $p = Start-Process -FilePath $PsExe -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ps1`"" `
        -NoNewWindow -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $p.Handle
    if (-not $p.WaitForExit($TimeoutSeg * 1000)) {
        try { $p.Kill() } catch {}
        $code = 'TIMEOUT'
    } else {
        $code = $p.ExitCode
    }
    $texto = ''
    if (Test-Path $out) { $texto += (Get-Content -LiteralPath $out -Raw) }
    if (Test-Path $err) { $texto += (Get-Content -LiteralPath $err -Raw) }
    [pscustomobject]@{ Code = $code; Salida = $texto }
}

function Set-Reemplazo {
    # Reemplazo de texto literal que falla si el texto no esta (evita probar una copia sin modificar)
    param([string]$Texto, [string]$Viejo, [string]$Nuevo)
    if (-not $Texto.Contains($Viejo)) { throw "No se encontro en el script: $Viejo" }
    $Texto.Replace($Viejo, $Nuevo)
}

try {
    Write-Output "Proceso 64 bits: $([Environment]::Is64BitProcess) / Usuario: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
    if (-not (Test-Path $Script)) { throw "No existe $Script" }
    $original = Get-Content -LiteralPath $Script -Raw

    # ---------- 1) Sintaxis ----------
    Write-Output '== Paso 1: sintaxis (parser PS 5.1) =='
    $tokens = $null; $errores = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$tokens, [ref]$errores)
    if ($errores.Count -gt 0) {
        $errores | ForEach-Object { Write-Output ("  linea {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
        $Fallos.Add('Sintaxis')
    } else {
        Write-Output 'Sintaxis OK.'
    }
    $noAscii = [Text.Encoding]::UTF8.GetBytes($original) | Where-Object { $_ -gt 127 } | Select-Object -First 1
    if ($noAscii) { Write-Output 'AVISO: el script tiene caracteres no ASCII.' } else { Write-Output 'Solo ASCII: OK.' }
    Test-TiempoTotal

    # ---------- 2) Modo prueba: descarga + extraccion (32 bits) ----------
    Write-Output '== Paso 2: modo prueba (descarga + extraccion, PowerShell 32 bits) =='
    $c2 = Set-Reemplazo $original '$TestMode         = $false' '$TestMode         = $true'
    $r2 = Invoke-Copia -Contenido $c2 -PsExe $Ps32 -TimeoutSeg 420
    Write-Output $r2.Salida
    Write-Output "Exit code: $($r2.Code)"
    if ($r2.Code -ne 0 -or $r2.Salida -notmatch 'RESULTADO \(MODO PRUEBA\): descarga y extraccion OK') { $Fallos.Add('Modo prueba') }
    if ($r2.Salida -match 'Reinicio forzado programado') { $Fallos.Add('Modo prueba programo un reinicio (no deberia)') }
    Test-TiempoTotal

    # ---------- 3) Aviso + reinicio (simula instalacion OK, 32 bits) ----------
    Write-Output '== Paso 3: aviso + reinicio (simulando instalacion OK, PowerShell 32 bits) =='
    & $Shutdown /a 2>$null   # por si quedo algo programado de antes
    $c3 = Set-Reemplazo $original '    # ---------- Exclusion mutua con la limpieza ----------' `
        "    `$InstaladoOk = `$true; `$ExitCode = 0; Write-Log 'PRUEBA: se simula instalacion OK'; return`r`n    # ---------- Exclusion mutua con la limpieza ----------"
    $r3 = Invoke-Copia -Contenido $c3 -PsExe $Ps32 -TimeoutSeg 90
    Write-Output $r3.Salida
    Write-Output "Exit code: $($r3.Code)"
    # Si el reinicio quedo programado, shutdown /a devuelve 0. Si no habia nada, 1116.
    $abort = Start-Process -FilePath $Shutdown -ArgumentList '/a' -NoNewWindow -PassThru -Wait
    Write-Output "shutdown /a -> codigo $($abort.ExitCode) (0 = habia un reinicio programado y se cancelo)"
    if ($r3.Code -ne 0)                                          { $Fallos.Add('Reinicio: exit code distinto de 0') }
    if ($r3.Salida -notmatch 'Reinicio forzado programado en 300 s') { $Fallos.Add('Reinicio: no se logueo la programacion') }
    if ($abort.ExitCode -ne 0)                                   { $Fallos.Add('Reinicio: no habia reinicio pendiente para cancelar') }
    if ($r3.Salida -match 'msg.exe no existe')                   { $Fallos.Add('msg.exe no encontrado desde 32 bits (Sysnative)') }

    # Control: desde 32 bits, System32\msg.exe NO deberia verse (por eso se usa Sysnative)
    $ver32 = Invoke-Copia -Contenido "Write-Output ('System32 msg: ' + (Test-Path `"`$env:WINDIR\System32\msg.exe`")); Write-Output ('Sysnative msg: ' + (Test-Path `"`$env:WINDIR\Sysnative\msg.exe`"))" -PsExe $Ps32 -TimeoutSeg 30
    Write-Output "Control 32 bits -> $($ver32.Salida.Trim() -replace '\s+', ' | ')"
    Test-TiempoTotal
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    $Fallos.Add('Excepcion')
}
finally {
    Start-Process -FilePath $Shutdown -ArgumentList '/a' -NoNewWindow -Wait -ErrorAction SilentlyContinue
    $Temps | ForEach-Object { Remove-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue }
}

if ($Fallos.Count -gt 0) {
    Write-Output ("FALLO: {0}" -f ($Fallos -join '; '))
    exit 1
}
Write-Output ("TODO OK en {0:N1} s." -f $reloj.Elapsed.TotalSeconds)
exit 0
