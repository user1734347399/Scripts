<#
Objetivo:
    Instala Cortex XDR 9.2 (descarga SFX, extrae e instala el MSI en silencio) y,
    solo si la instalacion se confirma en esta corrida, avisa al usuario y
    programa un reinicio forzado en 5 minutos.
Notas:
    Corre como SYSTEM desde Action1. Tope global de 15 min. No instala si hay un
    Cortex anterior o restos (requiere limpieza). Codigos de salida abajo.
#>

#  Instalacion Cortex XDR 9.2 - v19
#  Cambios respecto de v18:
#   - Si Cortex se instalo en ESTA corrida (exito o pendiente de reinicio), se avisa
#     al usuario con msg.exe y se programa un reinicio forzado en 5 minutos.
#     No se reinicia si ya tenia 9.2+, si fallo o en modo prueba.
#  Cambios de v18 respecto de v17:
#   - El codigo de salida ahora llega SIEMPRE a Action1 
#     Antes, las salidas con 'return' terminaban con codigo 0 y Action1 mostraba
#     Success aunque hubiera fallado.
#   - Exclusion mutua con otra instalacion en curso (INSTALAR.lock propio).
#     Evita choques entre la ejecucion programada y un Run Now.
#  Codigos de salida:
#   0  = instalado OK / ya tenia 9.2+ / pendiente de reinicio
#   15 = sin espacio o MSI ocupado      20 = falla de descarga
#   30 = falla de extraccion            40 = msiexec fallo
#   50 = no se confirmo la instalacion  60 = tope global alcanzado
#   70 = Cortex anterior (requiere limpieza)
#   72 = restos de Cortex (limpieza + reinicio)
#   73 = limpieza corriendo             74 = otra instalacion corriendo
#   99 = error inesperado


# ===================== CONFIGURACION =====================
$TestMode         = $false  # $true = solo descarga y extrae

$Url              = 'https://github.com/user1734347399/install/releases/download/agent/Cortex92-SFX.exe'
$SfxPass          = 'Kx7mQ2vR_9hTzP4wN-bY8cFj3sLd'
$TargetVersion    = [version]'9.2'
$BaseDir          = 'C:\ProgramData\SGA\Cortex'
$LogDir           = 'C:\ProgramData\SGA\Logs'
$MinSizeMB        = 10      # tamanio minimo esperado del SFX descargado
$MinFreeGB        = 2       # espacio libre minimo en C:
$GlobalTimeoutMin = 15      # TOPE TOTAL del script (minutos). Al llegar, el script termina.
$SgaDir           = 'C:\ProgramData\SGA'
$MsiBusyMaxSec    = 90      # espera maxima si hay otra instalacion MSI
$DownloadMaxSec   = 240     # tope de la descarga
$SfxMaxSec        = 120     # tope de la extraccion
$VerifyReserveSec = 60      # tiempo que se reserva para verificar despues de msiexec
$PollSec          = 15
$LockFreshMin     = 20      # v18: un INSTALAR.lock mas nuevo que esto = hay otra instalacion corriendo
$RebootDelaySec   = 300     # v19: reinicio forzado X segundos despues de instalar OK
$MsgTimeSec       = 900     # v19: cuanto queda visible el aviso en pantalla
$MsgTexto         = 'El sistema se reiniciara automaticamente en 5 minutos para finalizar una actualizacion. Por favor, guarde su trabajo.'


$ErrorActionPreference = 'Stop'
$GlobalDeadline = (Get-Date).AddMinutes($GlobalTimeoutMin)
$Stamp      = Get-Date -Format 'yyyyMMdd_HHmmss'
$ScriptLog  = Join-Path $LogDir "Cortex-Install_$Stamp.log"
$MsiLog     = Join-Path $LogDir "Cortex-MSI_$Stamp.log"
$SfxPath    = Join-Path $BaseDir 'Cortex92-SFX.exe'
$ExtractDir = Join-Path $BaseDir 'extract'
$ExitCode   = 99
$MsiStillRunning = $false
$LockPuesto = $false
$InstaladoOk = $false   # v19: solo $true si Cortex se instalo en esta corrida

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Msg
    Write-Output $line
    try { Add-Content -Path $ScriptLog -Value $line -ErrorAction Stop } catch {}
}

function Get-RemainingSec {
    [math]::Max(0, [int]($GlobalDeadline - (Get-Date)).TotalSeconds)
}

function Get-Budget {
    # Tiempo para una fase: su tope propio, recortado a lo que queda del tope global
    param([int]$PhaseSec)
    $rem = Get-RemainingSec
    if ($rem -lt 5) { throw 'GLOBAL_TIMEOUT' }
    [math]::Min($PhaseSec, $rem)
}

function Get-CortexInfo {
    # Lee el registro en vista 64 y 32 bits (sirve aunque Action1 corra PowerShell de 32)
    $found = @()
    foreach ($view in 'Registry64', 'Registry32') {
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view)
            $un = $base.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if ($un) {
                foreach ($name in $un.GetSubKeyNames()) {
                    $k = $un.OpenSubKey($name)
                    if (-not $k) { continue }
                    $dn = [string]$k.GetValue('DisplayName')
                    if ($dn -match 'Cortex XDR|Traps') {
                        $raw = [string]$k.GetValue('DisplayVersion')
                        $v = $null
                        [void][version]::TryParse($raw, [ref]$v)
                        $found += [pscustomobject]@{ Name = $dn; Version = $v; RawVersion = $raw }
                    }
                    $k.Close()
                }
                $un.Close()
            }
            $base.Close()
        } catch {}
    }
    $found | Sort-Object { if ($_.Version) { $_.Version } else { [version]'0.0' } } -Descending | Select-Object -First 1
}

function Get-CortexRestos {
    # Chequeo RAPIDO de restos, solo registro. Lee vista 64 y 32 bits (Action1 corre PS de 32).
    # NO mira HKLM\SYSTEM\Cyvera: es una clave vacia protegida que no se puede borrar y es inofensiva.
    $restos  = New-Object System.Collections.Generic.List[string]
    $drivers = 'cyserver','cyverak','cyvrfsfd','cyvrlpc','cyvrmtgn','tdevflt','tedrdrv','telam','xdrhealth'
    foreach ($view in 'Registry64', 'Registry32') {
        $base = $null
        try { $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', $view) } catch { continue }
        try {
            # 1) Servicios / drivers por nombre exacto (+ tedrpers-<version>)
            $svcRoot = $base.OpenSubKey('SYSTEM\CurrentControlSet\Services')
            if ($svcRoot) {
                foreach ($n in $svcRoot.GetSubKeyNames()) {
                    if (($drivers -contains $n) -or ($n -like 'tedrpers-*')) { $restos.Add("Servicio: $n") }
                }
                $svcRoot.Close()
            }
            # 2) Clave del agente
            $k = $base.OpenSubKey('SOFTWARE\Cyvera\Client')
            if ($k) { $restos.Add('Clave: HKLM\SOFTWARE\Cyvera\Client'); $k.Close() }
            # 3) Filtros de clase (tdevflt colgado = incidente de teclado/mouse USB)
            $cls = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\Class')
            if ($cls) {
                foreach ($g in $cls.GetSubKeyNames()) {
                    try {
                        $gk = $cls.OpenSubKey($g)
                        if (-not $gk) { continue }
                        foreach ($f in 'UpperFilters', 'LowerFilters') {
                            foreach ($item in @($gk.GetValue($f))) {
                                if ($item -and (($drivers -contains $item) -or ($item -like 'tedrpers*'))) {
                                    $restos.Add("Filtro: Class\$g $f=$item")
                                }
                            }
                        }
                        $gk.Close()
                    } catch {}
                }
                $cls.Close()
            }
        } catch {
        } finally {
            if ($base) { $base.Close() }
        }
    }
    $restos | Select-Object -Unique
}

function Get-CortexService {
    Get-Service -Name 'cyserver' -ErrorAction SilentlyContinue
}

function Test-MsiBusy {
    try {
        $m = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
        $m.Dispose()
        return $true
    } catch { return $false }
}

# Ultimo arranque con 3 fuentes de respaldo (en algunos equipos CIM devuelve vacio via Action1)
function Get-UltimoArranque {
    try { $b = (Get-CimInstance Win32_OperatingSystem -OperationTimeoutSec 20 -ErrorAction Stop).LastBootUpTime; if ($b) { return [datetime]$b } } catch {}
    try { $o = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop; if ($o -and $o.LastBootUpTime) { return $o.ConvertToDateTime($o.LastBootUpTime) } } catch {}
    try { $e = Get-WinEvent -FilterHashtable @{ LogName='System'; ProviderName='Microsoft-Windows-Kernel-General'; Id=12 } -MaxEvents 1 -ErrorAction Stop; if ($e) { return $e.TimeCreated } } catch {}
    return $null
}

function Get-System32Exe {
    # Action1 puede correr PowerShell de 32 bits: ahi System32 se redirige a SysWOW64,
    # donde msg.exe NO existe. Sysnative apunta al System32 real.
    param([string]$Exe)
    $nativo = Join-Path $env:WINDIR "Sysnative\$Exe"
    if (Test-Path $nativo) { return $nativo }
    Join-Path $env:WINDIR "System32\$Exe"
}

function Start-WithTimeout {
    param([string]$File, [string]$ArgString, [int]$TimeoutSec)
    $p = Start-Process -FilePath $File -ArgumentList $ArgString -PassThru -WindowStyle Hidden
    $null = $p.Handle   # necesario para poder leer ExitCode en PS 5.1
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        return [pscustomobject]@{ TimedOut = $true; Code = $null; Process = $p }
    }
    [pscustomobject]@{ TimedOut = $false; Code = $p.ExitCode; Process = $p }
}

try {
    # ---------- Exclusion mutua con la limpieza ----------
    $lockLimp = Join-Path $SgaDir 'LIMPIEZA.lock'
    $lockInst = Join-Path $SgaDir 'INSTALAR.lock'
    if (-not $TestMode -and (Test-Path $lockLimp) -and (((Get-Date) - (Get-Item $lockLimp).LastWriteTime).TotalMinutes -lt 15)) {
        Write-Output "La limpieza esta corriendo en este momento (LIMPIEZA.lock fresco). No instalo; reintenta la proxima corrida."
        $ExitCode = 73
        return
    }

    # ---------- v18: Exclusion mutua con OTRA instalacion ----------
    # Va antes de poner el lock propio, asi esta corrida no borra el lock de la otra al salir.
    if (-not $TestMode -and (Test-Path $lockInst) -and (((Get-Date) - (Get-Item $lockInst).LastWriteTime).TotalMinutes -lt $LockFreshMin)) {
        Write-Output "Ya hay una instalacion en curso (INSTALAR.lock fresco). No hago nada; reintenta la proxima corrida."
        $ExitCode = 74
        return
    }

    New-Item -Path $SgaDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    Set-Content -Path $lockInst -Value (Get-Date) -Force -ErrorAction SilentlyContinue
    $LockPuesto = $true

    # ---------- Carpetas ----------
    foreach ($d in $BaseDir, $LogDir) {
        if (-not (Test-Path $d)) { New-Item -Path $d -ItemType Directory -Force | Out-Null }
    }
    Get-ChildItem $LogDir -Filter 'Cortex-*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 20 |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Log "Inicio instalacion Cortex XDR $TargetVersion en $env:COMPUTERNAME (tope global $GlobalTimeoutMin min)"

    if ($TestMode) { Write-Log '*** MODO PRUEBA: solo descarga y extraccion, NO se instala ***' 'WARN' }

    # ---------- Pre-chequeo minimo ----------
    $pre = if ($TestMode) { $null } else { Get-CortexInfo }
    if ($pre -and $pre.Version -and $pre.Version -ge $TargetVersion) {
        Write-Log "Ya tiene $($pre.Name) (version $($pre.RawVersion)). Nada que hacer. (Para probar descarga/extraccion igual: `$TestMode = `$true)"
        $ExitCode = 0
        return
    }
    # GUARDA: si hay un Cortex ANTERIOR 
    if ($pre) {
        Write-Log "Hay un Cortex anterior ($($pre.Name) $($pre.RawVersion)). Requiere LIMPIEZA previa (v4). NO se instala encima de un 7.x/8.x." 'ERROR'
        $ExitCode = 70
        return
    }

    #  Servicios/drivers, clave Cyvera\Client y filtros de clase. Si hay algo, NO instala.
    $restos = @(Get-CortexRestos)
    if ($restos.Count -gt 0) {
        $nivel = if ($TestMode) { 'WARN' } else { 'ERROR' }
        Write-Log "Se encontraron $($restos.Count) restos de Cortex:" $nivel
        $restos | ForEach-Object { Write-Log "  $_" $nivel }
        if (-not $TestMode) {
            Write-Log 'Hay restos de Cortex. NO instalo (primero limpieza + reinicio).' 'ERROR'
            $ExitCode = 72
            return
        }
        Write-Log 'MODO PRUEBA: se informan los restos pero se sigue con descarga/extraccion.' 'WARN'
    } else {
        Write-Log 'Chequeo de restos: limpio (sin servicios, claves ni filtros de Cortex). Equipo apto para instalar.'
    }

    # ---------- Espacio en disco ----------
    $freeBytes = $null
    try { $freeBytes = ([System.IO.DriveInfo]'C').AvailableFreeSpace } catch {}
    if (-not $freeBytes) {
        try { $freeBytes = (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -OperationTimeoutSec 20).FreeSpace } catch {}
    }
    if (-not $freeBytes) {
        Write-Log 'No se pudo determinar el espacio libre en C:. Se continua igual.' 'WARN'
        $freeGB = $null
    } else {
        $freeGB = [math]::Round($freeBytes / 1GB, 1)
        Write-Log "Espacio libre en C: $freeGB GB"
    }
    if ($freeGB -ne $null -and $freeGB -lt $MinFreeGB) {
        Write-Log "Espacio libre en C: insuficiente ($freeGB GB, minimo $MinFreeGB GB)." 'ERROR'
        $ExitCode = 15
        return
    }

    # ---------- Otra instalacion MSI en curso (no aplica en modo prueba) ----------
    if (-not $TestMode) {
        $busyDeadline = (Get-Date).AddSeconds((Get-Budget $MsiBusyMaxSec))
        while ((Test-MsiBusy) -and (Get-Date) -lt $busyDeadline) {
            Write-Log 'Hay otra instalacion MSI en curso, esperando...' 'WARN'
            Start-Sleep -Seconds 15
        }
    }
    if (-not $TestMode -and (Test-MsiBusy)) {
        Write-Log 'Sigue habiendo otra instalacion MSI en curso. Abortando.' 'ERROR'
        $ExitCode = 15
        return
    }

    # ---------- Descarga con curl ----------
    $curl = Join-Path $env:WINDIR 'System32\curl.exe'
    if (-not (Test-Path $curl)) {
        Write-Log 'No existe curl.exe en System32 (Windows 10 anterior a 1803).' 'ERROR'
        $ExitCode = 20
        return
    }
    if (Test-Path $SfxPath) { Remove-Item $SfxPath -Force }

    $dlBudget = Get-Budget $DownloadMaxSec
    Write-Log "Descargando $Url (max $dlBudget s)"
    $curlArgs = "-L --fail --retry 2 --retry-delay 5 --connect-timeout 30 --max-time $dlBudget -sS -o `"$SfxPath`" `"$Url`""
    $dl = Start-WithTimeout -File $curl -ArgString $curlArgs -TimeoutSec ($dlBudget + 10)
    if ($dl.TimedOut) {
        try { $dl.Process.Kill() } catch {}
        Write-Log 'La descarga supero el tiempo maximo.' 'ERROR'
        $ExitCode = 20
        return
    }
    if ($dl.Code -ne 0) {
        Write-Log "curl termino con codigo $($dl.Code) (6=DNS, 7=sin conexion, 22=HTTP error/404, 28=timeout, 35=SSL)." 'ERROR'
        $ExitCode = 20
        return
    }
    $sizeMB = [math]::Round((Get-Item $SfxPath).Length / 1MB, 1)
    if ($sizeMB -lt $MinSizeMB) {
        Write-Log "El archivo descargado pesa $sizeMB MB (minimo esperado $MinSizeMB MB). Descarga invalida." 'ERROR'
        $ExitCode = 20
        return
    }
    Unblock-File -Path $SfxPath -ErrorAction SilentlyContinue
    Write-Log "Descarga OK ($sizeMB MB). Quedan $(Get-RemainingSec) s."

    # ---------- Extraccion con el propio SFX ----------
    if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $ExtractDir -ItemType Directory -Force | Out-Null

    $sfxBudget = Get-Budget $SfxMaxSec
    Write-Log "Extrayendo SFX (max $sfxBudget s)..."
    $ex = Start-WithTimeout -File $SfxPath -ArgString "-y -p$SfxPass `"-o$ExtractDir`"" -TimeoutSec $sfxBudget
    if ($ex.TimedOut) {
        try { $ex.Process.Kill() } catch {}
        Write-Log 'La extraccion supero el tiempo maximo.' 'ERROR'
        $ExitCode = 30
        return
    }
    if ($ex.Code -ne 0) {
        Write-Log "El SFX termino con codigo $($ex.Code) (2 = error fatal / clave incorrecta / archivo danado)." 'ERROR'
        $ExitCode = 30
        return
    }
    $msi = Get-ChildItem -Path $ExtractDir -Filter '*.msi' -Recurse | Select-Object -First 1
    if (-not $msi) {
        Write-Log 'No se encontro ningun .msi despues de extraer.' 'ERROR'
        $ExitCode = 30
        return
    }
    Write-Log "Extraido: $($msi.Name)"

    # ---------- Fin del modo prueba ----------
    if ($TestMode) {
        $msiMB = [math]::Round($msi.Length / 1MB, 1)
        Write-Log "RESULTADO (MODO PRUEBA): descarga y extraccion OK. MSI: $($msi.FullName) ($msiMB MB). No se instalo."
        $ExitCode = 0
        return
    }

    # ---------- Instalacion ----------
    # msiexec usa lo que queda del tope global, menos una reserva para verificar
    $msiBudget = (Get-RemainingSec) - $VerifyReserveSec
    if ($msiBudget -lt 60) { throw 'GLOBAL_TIMEOUT' }
    Write-Log "Instalando (max $msiBudget s). Log MSI: $MsiLog"
    $msiArgs = "/i `"$($msi.FullName)`" /qn /norestart /l*v `"$MsiLog`""
    $inst = Start-WithTimeout -File (Join-Path $env:WINDIR 'System32\msiexec.exe') -ArgString $msiArgs -TimeoutSec $msiBudget

    $RebootRequired = $false
    if ($inst.TimedOut) {
        # No se mata msiexec: queda instalando en segundo plano
        $MsiStillRunning = $true
        Write-Log 'msiexec sigue corriendo. No se interrumpe; se verifica con el tiempo restante.' 'WARN'
    } else {
        switch ($inst.Code) {
            0    { Write-Log 'msiexec termino OK (0).' }
            3010 { Write-Log 'msiexec termino OK, requiere reinicio (3010).' 'WARN'; $RebootRequired = $true }
            1641 { Write-Log 'msiexec termino OK, inicio reinicio (1641).' 'WARN'; $RebootRequired = $true }
            1618 { Write-Log 'msiexec 1618: otra instalacion en curso.' 'ERROR'; $ExitCode = 40; return }
            default {
                Write-Log "msiexec fallo con codigo $($inst.Code)." 'ERROR'
                try {
                    $ctx = Select-String -Path $MsiLog -Pattern 'Return value 3' -Context 12, 0 -ErrorAction Stop | Select-Object -First 1
                    if ($ctx) {
                        Write-Log '--- Extracto del log MSI (antes de Return value 3) ---' 'ERROR'
                        $ctx.Context.PreContext + $ctx.Line | ForEach-Object { Write-Log $_ 'MSI' }
                    }
                } catch {}
                $ExitCode = 40
                return
            }
        }
    }

    # ---------- Espera inteligente / verificacion (hasta el tope global) ----------
    Write-Log "Verificando instalacion (quedan $(Get-RemainingSec) s, chequeo cada $PollSec s)..."
    $verOk = $false; $svcOk = $false; $info = $null
    do {
        $info  = Get-CortexInfo
        $svc   = Get-CortexService
        $verOk = [bool]($info -and $info.Version -and $info.Version -ge $TargetVersion)
        $svcOk = [bool]($svc -and $svc.Status -eq 'Running')
        if ($verOk -and $svcOk) { break }
        Write-Log ("Esperando... version={0} servicio={1}" -f $(if ($info) { $info.RawVersion } else { 'ninguna' }), $(if ($svc) { $svc.Status } else { 'no existe' }))
        Start-Sleep -Seconds ([math]::Min($PollSec, [math]::Max(1, (Get-RemainingSec))))
    } while ((Get-RemainingSec) -gt 0)

    if ($verOk -and $svcOk) {
        Write-Log "RESULTADO: Cortex XDR $($info.RawVersion) instalado y servicio cyserver en ejecucion."
        $ExitCode = 0
        $InstaladoOk = $true
    } elseif ($verOk -and $RebootRequired) {
        Write-Log "RESULTADO: Cortex XDR $($info.RawVersion) instalado, servicio no activo: PENDIENTE DE REINICIO." 'WARN'
        $ExitCode = 0
        $InstaladoOk = $true
    } elseif ($MsiStillRunning) {
        throw 'GLOBAL_TIMEOUT'
    } else {
        Write-Log "RESULTADO: msiexec termino pero no se confirmo la instalacion (version OK=$verOk, servicio OK=$svcOk). Revisar $MsiLog" 'ERROR'
        $ExitCode = 50
    }
}
catch {
    if ($_.Exception.Message -eq 'GLOBAL_TIMEOUT') {
        $extra = if ($MsiStillRunning) { ' msiexec sigue instalando en segundo plano; la auditoria lo va a confirmar.' } else { '' }
        Write-Log "RESULTADO: se alcanzo el tope global de $GlobalTimeoutMin min.$extra" 'ERROR'
        $ExitCode = 60
    } else {
        Write-Log "Error inesperado: $($_.Exception.Message) (linea $($_.InvocationInfo.ScriptLineNumber))" 'ERROR'
        $ExitCode = 99
    }
}
finally {
    # Limpieza de instaladores (los logs quedan). Si msiexec sigue corriendo,
    # no se toca la carpeta extraida porque el MSI esta en uso.
    # En modo prueba el MSI extraido se conserva para revisarlo.
    if (Test-Path $SfxPath) { Remove-Item $SfxPath -Force -ErrorAction SilentlyContinue }
    if (-not $MsiStillRunning -and -not $TestMode -and (Test-Path $ExtractDir)) {
        Remove-Item $ExtractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    # Si msiexec sigue en segundo plano, el lock QUEDA (expira solo) para que la limpieza no toque nada
    if ($LockPuesto -and -not $MsiStillRunning) { Remove-Item (Join-Path $SgaDir 'INSTALAR.lock') -Force -ErrorAction SilentlyContinue }

    # v19: aviso + reinicio forzado, SOLO si se instalo en esta corrida.
    # Va en try/catch propio: una falla aca no cambia el codigo de salida de la instalacion.
    if ($InstaladoOk -and $ExitCode -eq 0 -and -not $TestMode) {
        # Se usa Start-WithTimeout y no '& exe 2>&1': en PS 5.1 con ErrorActionPreference=Stop
        # cualquier texto en stderr de un exe nativo se convierte en excepcion.
        try {
            $msgExe = Get-System32Exe 'msg.exe'
            if (Test-Path $msgExe) {
                $m = Start-WithTimeout -File $msgExe -ArgString "* /time:$MsgTimeSec `"$MsgTexto`"" -TimeoutSec 15
                if ($m.TimedOut) {
                    try { $m.Process.Kill() } catch {}
                    Write-Log 'msg.exe supero el tiempo maximo. Se sigue con el reinicio.' 'WARN'
                } elseif ($m.Code -eq 0) {
                    Write-Log 'Aviso de reinicio enviado a los usuarios.'
                } else {
                    Write-Log "msg.exe termino con codigo $($m.Code) (puede no haber usuarios logueados)." 'WARN'
                }
            } else {
                Write-Log 'msg.exe no existe en este equipo (Windows Home). Se reinicia sin aviso de msg.exe.' 'WARN'
            }
        } catch {
            Write-Log "No se pudo mostrar el aviso: $($_.Exception.Message)" 'WARN'
        }
        try {
            $sd = Start-WithTimeout -File (Get-System32Exe 'shutdown.exe') -ArgString "/r /f /t $RebootDelaySec /d p:2:17 /c `"$MsgTexto`"" -TimeoutSec 15
            if ($sd.TimedOut) {
                try { $sd.Process.Kill() } catch {}
                Write-Log 'shutdown.exe supero el tiempo maximo. Reinicio NO confirmado.' 'WARN'
            } else {
                switch ($sd.Code) {
                    0       { Write-Log "Reinicio forzado programado en $RebootDelaySec s." }
                    1190    { Write-Log 'Ya habia un reinicio/apagado programado (1190). Se deja ese.' 'WARN' }
                    default { Write-Log "shutdown.exe termino con codigo $($sd.Code). Reinicio NO programado." 'WARN' }
                }
            }
        } catch {
            Write-Log "No se pudo programar el reinicio: $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log "Fin. Codigo de salida: $ExitCode"
    Write-Output "STATUS=$ExitCode COMPUTER=$env:COMPUTERNAME"

    # v18: el exit va ACA. Un 'return' dentro del try termina el script y nunca
    # llegaria a una linea despues del finally: Action1 recibiria 0 aunque fallara.
    exit $ExitCode
}
