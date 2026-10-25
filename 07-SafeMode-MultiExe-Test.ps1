<#
=========================================================================
 Objetivo:
   Motor "Modo Seguro automatizado" (NSSM) corriendo VARIOS .exe EN SECUENCIA
   dentro de Safe Mode, como SYSTEM y sin login, capturando salida y exit code
   de cada uno. Disenado para ser A PRUEBA DE LOOP: sirve hasta en notebooks
   por WiFi (donde en Safe Mode NO hay red y no hay salida remota).

   Prueba actual (inofensiva, no toca ningun AV):
     1) driverquery /v   -> enumera drivers (captura salida grande)
     2) msiexec /quiet /x {GUID-inexistente} -> sonda: ver si Windows Installer
        responde en Safe Mode (msiserver suele estar deshabilitado ahi)

   Para ESET: editar la lista $payloads (p.ej. C:\Intel\ESETUninstaller.exe /force).

 CLAVE DE SEGURIDAD (a prueba de loop):
   El worker, lo PRIMERO que hace es QUITAR el safeboot. Una vez dentro de Safe
   Mode ya no se necesita la marca; al sacarla al inicio, cualquier reinicio
   posterior vuelve a Windows normal AUNQUE el worker falle o se corte la luz.
   Nunca queda en loop de Safe Mode.

 Diseno robusto:
   - Worker ESTATICO: los payloads se leen de un JSON en disco (no se insertan
     por texto), asi no hay forma de romper el parseo del worker.
   - Rutas completas a System32 -> evita el bug 32/64 bits.
   - Tope de tiempo global en el ARM (no cuelga Action1) y timeout por cada exe.
   - Windows PowerShell 5.1. Enviar como script .ps1 por Action1, NUNCA como cmd.
=========================================================================
#>

# ================== CONFIG ==================
$log          = "C:\Intel\SafeSvc-Arm.txt"
$workerPath   = "C:\Intel\SafeSvc-Worker.ps1"
$payloadsJson = "C:\Intel\SafeSvc-Payloads.json"
$added        = "C:\Intel\SafeSvc-Added.txt"
$nssm         = "C:\Intel\nssm.exe"
$svc          = "CortexSafeSvc"
$topeArmSeg   = 180            # tope global de la fase ARM (no cuelga Action1)
# El timeout de CADA exe esta fijo en el worker ($timeoutMs=120000 => 120s)

# --- Lista de payloads a correr EN ORDEN. Para ESET: agregar/cambiar una entrada. ---
$payloads = @(
  @{ Exe="C:\Windows\System32\driverquery.exe"; Args="/v";                                                 Log="C:\Intel\SafeSvc-01-driverquery.txt" },
  @{ Exe="C:\Windows\System32\msiexec.exe";      Args="/quiet /x {00000000-0000-0000-0000-000000000000}";   Log="C:\Intel\SafeSvc-02-msiexec.txt" }
)

# Agentes de acceso remoto a mantener vivos en Safe Mode con Red
# (util en desktop por Ethernet; en notebook WiFi normalmente NO hay red en Safe Mode)
$keepKeywords = @("a1agent","mesh","rustdesk","anydesk")

# ================== INFRA ==================
$armInicio = Get-Date
New-Item -ItemType Directory -Path "C:\Intel" -Force -EA SilentlyContinue | Out-Null
"==== SAFE SVC ARM (MultiExe Test v2) $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Set-Content $log -Encoding UTF8
"" | Set-Content $added -Encoding UTF8
function Log($m){ $l=(Get-Date -Format 'HH:mm:ss')+' '+$m; Add-Content $log $l -EA SilentlyContinue; Write-Output $l }
function TopeVencido { return ((New-TimeSpan -Start $armInicio -End (Get-Date)).TotalSeconds -gt $topeArmSeg) }

$SYS = "$env:windir\System32"

# ================== conseguir NSSM ==================
if(-not (Test-Path $nssm)){
  try{
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "https://nssm.cc/release/nssm-2.24.zip" -OutFile "C:\Intel\nssm.zip" -UseBasicParsing -TimeoutSec 60
    Expand-Archive "C:\Intel\nssm.zip" "C:\Intel\nssm_tmp" -Force
    Copy-Item "C:\Intel\nssm_tmp\nssm-2.24\win64\nssm.exe" $nssm -Force
    Log "NSSM descargado OK"
  }catch{ Log "ERROR: no pude descargar NSSM ($_). Pone nssm.exe en C:\Intel y re-corre. ABORTO."; exit 1 }
}else{ Log "NSSM ya estaba en $nssm" }

if(TopeVencido){ Log "ABORTO: tope de tiempo del ARM vencido en descarga NSSM."; exit 1 }

# ================== escribir payloads a JSON (worker los lee de ahi) ==================
($payloads | ConvertTo-Json -Depth 3) | Set-Content $payloadsJson -Encoding UTF8
Log "payloads escritos en $payloadsJson ($($payloads.Count) exe)"

# ================== proteger agentes remotos en Safe Mode con Red ==================
$svcKey="HKLM:\SYSTEM\CurrentControlSet\Services"
$keep = New-Object System.Collections.Generic.List[string]
Get-ChildItem $svcKey -EA SilentlyContinue | ForEach-Object {
  $name=$_.PSChildName; $dp=Get-ItemProperty -Path $_.PSPath -EA SilentlyContinue; $hit=$false
  foreach($kw in $keepKeywords){ $k=$kw.ToLower()
    if( ($name -and $name.ToLower().Contains($k)) -or
        ($dp.DisplayName -and $dp.DisplayName.ToLower().Contains($k)) -or
        ($dp.ImagePath   -and $dp.ImagePath.ToLower().Contains($k)) ){ $hit=$true } }
  if($hit -and ($keep -notcontains $name)){ $keep.Add($name) }
}
foreach($s in $keep){
  $sbk="HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\$s"
  if(Test-Path $sbk){ Log "SafeBoot(Network) ya tenia: $s"; continue }
  & "$SYS\reg.exe" add ("HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\" + $s) /ve /d "Service" /f 2>&1 | Out-Null
  Add-Content $added ("Network\" + $s); Log "SafeBoot(Network) + $s"
}
Log ("agentes protegidos: " + ($keep -join ", "))

if(TopeVencido){ Log "ABORTO: tope de tiempo del ARM vencido."; exit 1 }

# ================== WORKER (ESTATICO: lee payloads del JSON) ==================
$worker = @'
$log="C:\Intel\SafeSvc-Worker.txt"
$svc="CortexSafeSvc"
$added="C:\Intel\SafeSvc-Added.txt"
$payloadsJson="C:\Intel\SafeSvc-Payloads.json"
$SYS="$env:windir\System32"
$timeoutMs=120000
New-Item -ItemType Directory -Path "C:\Intel" -Force -EA SilentlyContinue | Out-Null
function Log($m){ $l=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$m; Add-Content $log $l -EA SilentlyContinue }

function CorrerExe($exe,$argumentos,$logSalida){
  if(-not (Test-Path -LiteralPath $exe)){ Log ("PAYLOAD: NO existe el exe: " + $exe); return }
  Log ("PAYLOAD: ejecutando '" + $exe + " " + $argumentos + "'")
  ("==== PAYLOAD " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " :: " + $exe + " " + $argumentos + " ====") | Set-Content $logSalida -Encoding UTF8
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = $exe
  $psi.Arguments = $argumentos
  $psi.WorkingDirectory = (Split-Path -Parent $exe)
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow  = $true
  $p = [System.Diagnostics.Process]::Start($psi)
  if(-not $p.WaitForExit($timeoutMs)){ try{$p.Kill()}catch{ Log "no se pudo matar el proceso colgado" }; Add-Content $logSalida "[TIMEOUT: no termino a tiempo, se mato]" }
  $out = $p.StandardOutput.ReadToEnd()
  $err = $p.StandardError.ReadToEnd()
  Add-Content $logSalida $out
  if($err){ Add-Content $logSalida ("[STDERR]`r`n" + $err) }
  Add-Content $logSalida ("[EXIT CODE] " + $p.ExitCode)
  Log ("PAYLOAD termino. ExitCode=" + $p.ExitCode + ". Salida en " + $logSalida)
}

Log "===== WORKER (NSSM) ARRANCO ====="
Log ("usuario = " + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Log ("equipo  = " + $env:COMPUTERNAME)
$opt=(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option" -Name OptionValue -EA SilentlyContinue).OptionValue
if($opt){ Log "SafeBoot OptionValue = $opt (2=Network) -> ESTAMOS EN MODO SEGURO" } else { Log "OptionValue vacio -> NO es Modo Seguro" }

# ---- A PRUEBA DE LOOP: quitar safeboot AHORA MISMO. Ya estamos dentro de Safe
#      Mode; sin la marca, cualquier reinicio posterior vuelve a normal. ----
$rd = & "$SYS\bcdedit.exe" /deletevalue safeboot 2>&1
Log ("DESARMADO safeboot al inicio: " + ($rd -join ' '))

try{
  $payloads = @(Get-Content $payloadsJson -Raw -EA SilentlyContinue | ConvertFrom-Json)
  $n=0
  foreach($pl in $payloads){
    $n++
    Log ("----- PAYLOAD " + $n + "/" + $payloads.Count + " -----")
    CorrerExe $pl.Exe $pl.Args $pl.Log
  }
}
catch{ Log "ERROR en payloads: $_" }
finally{
  Log "Limpiando SafeBoot y servicio..."
  if(Test-Path $added){
    Get-Content $added | ForEach-Object { if($_){ & "$SYS\reg.exe" delete ("HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\" + $_) /f 2>&1 | Out-Null; Log "SafeBoot quitado: $_" } }
    Remove-Item $added -Force -EA SilentlyContinue
  }
  & "$SYS\reg.exe" delete "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\CortexSafeSvc" /f 2>&1 | Out-Null
  # por si acaso, re-asegurar que safeboot no este
  & "$SYS\bcdedit.exe" /deletevalue safeboot 2>&1 | Out-Null
  $ro="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
  if(-not (Test-Path $ro)){ New-Item -Path $ro -Force | Out-Null }
  Set-ItemProperty -Path $ro -Name "CortexSafeSvcCleanup" -Value ("$SYS\sc.exe delete " + $svc) -EA SilentlyContinue
  Log "limpieza del servicio agendada para el proximo arranque normal (RunOnce)"
  Log "listo. Reinicio a modo normal en 15s."
  Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -EA SilentlyContinue
  & "$SYS\shutdown.exe" /r /t 15 /c "Prueba NSSM MultiExe - volviendo a normal"
}
'@
Set-Content -Path $workerPath -Value $worker -Encoding UTF8
Log "worker escrito en $workerPath"

# ================== crear servicio con NSSM (SYSTEM, auto) ==================
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
& "$SYS\sc.exe" stop $svc   2>&1 | Out-Null
& "$SYS\sc.exe" delete $svc 2>&1 | Out-Null
& $nssm install $svc "$ps" "-NoProfile -ExecutionPolicy Bypass -File $workerPath" 2>&1 | ForEach-Object { Log "nssm: $_" }
& $nssm set $svc Start SERVICE_AUTO_START 2>&1 | Out-Null
& $nssm set $svc AppExit Default Exit 2>&1 | Out-Null
& $nssm set $svc AppNoConsole 1 2>&1 | Out-Null

& "$SYS\sc.exe" query $svc | Out-Null
if($LASTEXITCODE -ne 0){ Log "ERROR: el servicio no se creo. Abortando (no reinicio)."; exit 1 }
Log "servicio '$svc' creado con NSSM (auto, SYSTEM)"

& "$SYS\reg.exe" add "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\$svc" /ve /d "Service" /f 2>&1 | Out-Null
Log "servicio agregado a SafeBoot\Network"

if(TopeVencido){ Log "ABORTO: tope de tiempo del ARM vencido antes del reinicio. Limpio servicio."; & "$SYS\sc.exe" delete $svc 2>&1 | Out-Null; exit 1 }

# ================== Safe Mode con Red + reiniciar (rutas completas, verificado) ==================
$rb = & "$SYS\bcdedit.exe" /set "{current}" safeboot network 2>&1
Log ("bcdedit set: " + ($rb -join ' '))
if(($rb -join ' ') -notmatch "correctamente|completed successfully"){
  Log "ERROR: bcdedit no aplico safeboot. Abortando (no reinicio). Limpio servicio."
  & "$SYS\sc.exe" delete $svc 2>&1 | Out-Null
  exit 1
}
Log "reinicio a Modo Seguro con Red en 15s. El servicio arranca solo como SYSTEM."
Log "Logs: C:\Intel\SafeSvc-Worker.txt (motor), SafeSvc-01-driverquery.txt y SafeSvc-02-msiexec.txt"
& "$SYS\shutdown.exe" /r /t 15 /c "Prueba NSSM MultiExe - reinicio tecnico"
exit 0
