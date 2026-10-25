<#
=========================================================================
 Objetivo:
   PLANTILLA del motor "Modo Seguro automatizado" (NSSM) validando el paso
   nuevo: CORRER UN .EXE en Modo Seguro y CAPTURAR su salida en un log.

   Esta prueba NO toca ningun AV. Corre un exe inofensivo (ipconfig /all)
   solo para confirmar el mecanismo "ejecutar exe + guardar salida + exit code"
   dentro de Safe Mode, como SYSTEM, sin login.

   Cuando esto funcione, reemplazar el bloque "PAYLOAD" del worker por:
     ESETUninstaller.exe /force   (correr desde su carpeta; deja ~ESETUninstaller.log)

 Flujo:
   FASE ARM (modo normal, por Action1 como SYSTEM):
     1) Protege agentes remotos (Action1/Mesh/RustDesk/AnyDesk) en SafeBoot\Network
        -> si NO detecta Action1 y Mesh, ABORTA (no te deja sin acceso).
     2) Escribe el WORKER en disco.
     3) Crea servicio real con NSSM (SYSTEM) y lo mete en SafeBoot\Network.
     4) bcdedit safeboot network (verificado) y reinicia.
   FASE WORKER (ya en Safe Mode, SYSTEM, sin login):
     - Loguea fecha/hora, usuario, OptionValue.
     - PAYLOAD: corre el .exe y captura stdout/stderr + exit code en un log.
     - finally BLINDADO: revierte SafeBoot, agenda borrado del servicio (RunOnce),
       y reinicia a normal. Siempre vuelve, aunque el payload falle.

 Recaudos:
   - Rutas completas a System32 (bcdedit/shutdown/sc/reg) -> evita el bug 32/64 bits.
   - TOPE DE TIEMPO GLOBAL en el ARM (no cuelga Action1): se autotermina.
   - PowerShell 64-bit (correr como script .ps1 en Action1, NUNCA como cmd).

 Probado sobre la base validada en VM PRUEBAS-01 (motor NSSM end-to-end).
=========================================================================
#>

# ================== CONFIG ==================
$log          = "C:\Intel\SafeSvc-Arm.txt"
$workerPath   = "C:\Intel\SafeSvc-Worker.ps1"
$added        = "C:\Intel\SafeSvc-Added.txt"
$nssm         = "C:\Intel\nssm.exe"
$svc          = "CortexSafeSvc"
$topeArmSeg   = 180   # tope global de la fase ARM: si se pasa, aborta sin colgar Action1

# --- PAYLOAD de prueba (exe inofensivo). Cambiar por ESET cuando valides. ---
$payloadExe   = "C:\Windows\System32\ipconfig.exe"
$payloadArgs  = "/all"
$payloadLog   = "C:\Intel\SafeSvc-Payload.txt"

# Agentes de acceso remoto a mantener vivos en Modo Seguro con Red
# a1agent=Action1, mesh=MeshCentral (Mesh Agent / MeshAgent), rustdesk, anydesk
$keepKeywords = @("a1agent","mesh","rustdesk","anydesk")

# ================== INFRA ==================
$armInicio = Get-Date
New-Item -ItemType Directory -Path "C:\Intel" -Force -EA SilentlyContinue | Out-Null
"==== SAFE SVC ARM (RunExe Test) $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====" | Set-Content $log -Encoding UTF8
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
$hayA1  = ($keep | Where-Object { $_.ToLower().Contains("a1") }).Count -gt 0
$hayMesh= ($keep | Where-Object { $_.ToLower().Contains("mesh") }).Count -gt 0
if(-not ($hayA1 -and $hayMesh)){ Log "ABORTO: falta Action1 y/o Mesh (A1=$hayA1 Mesh=$hayMesh). No reinicio."; exit 1 }

if(TopeVencido){ Log "ABORTO: tope de tiempo del ARM vencido."; exit 1 }

# ================== WORKER ==================
$worker = @'
param([string]$PayloadExe,[string]$PayloadArgs,[string]$PayloadLog)
$log="C:\Intel\SafeSvc-Worker.txt"
$svc="CortexSafeSvc"
$added="C:\Intel\SafeSvc-Added.txt"
$SYS="$env:windir\System32"
New-Item -ItemType Directory -Path "C:\Intel" -Force -EA SilentlyContinue | Out-Null
function Log($m){ $l=(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')+' '+$m; Add-Content $log $l -EA SilentlyContinue }

Log "===== WORKER (NSSM) ARRANCO ====="
Log ("usuario = " + [Security.Principal.WindowsIdentity]::GetCurrent().Name)
Log ("equipo  = " + $env:COMPUTERNAME)
$opt=(Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option" -Name OptionValue -EA SilentlyContinue).OptionValue
if($opt){ Log "SafeBoot OptionValue = $opt (2=Network) -> ESTAMOS EN MODO SEGURO :)" } else { Log "OptionValue vacio -> NO es Modo Seguro" }

try{
  # ---------------- PAYLOAD: correr exe + capturar salida ----------------
  if(Test-Path -LiteralPath $PayloadExe){
    Log "PAYLOAD: ejecutando '$PayloadExe $PayloadArgs'"
    "==== PAYLOAD $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') :: $PayloadExe $PayloadArgs ====" | Set-Content $PayloadLog -Encoding UTF8
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = $PayloadExe
    $psi.Arguments = $PayloadArgs
    $psi.WorkingDirectory = (Split-Path -Parent $PayloadExe)
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if(-not $p.WaitForExit(120000)){ try{$p.Kill()}catch{}; Add-Content $PayloadLog "[TIMEOUT: el exe no termino en 120s, se mato]" }
    $out = $p.StandardOutput.ReadToEnd()
    $err = $p.StandardError.ReadToEnd()
    Add-Content $PayloadLog $out
    if($err){ Add-Content $PayloadLog ("[STDERR]`r`n" + $err) }
    Add-Content $PayloadLog ("[EXIT CODE] " + $p.ExitCode)
    Log ("PAYLOAD termino. ExitCode=" + $p.ExitCode + ". Salida en " + $PayloadLog)
  } else {
    Log "PAYLOAD: NO existe el exe '$PayloadExe' (en ESET real: subi el .exe antes)."
  }
}
catch{ Log "ERROR en payload: $_" }
finally{
  Log "Revirtiendo..."
  if(Test-Path $added){
    Get-Content $added | ForEach-Object { if($_){ & "$SYS\reg.exe" delete ("HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\" + $_) /f 2>&1 | Out-Null; Log "SafeBoot quitado: $_" } }
    Remove-Item $added -Force -EA SilentlyContinue
  }
  & "$SYS\reg.exe" delete "HKLM\SYSTEM\CurrentControlSet\Control\SafeBoot\Network\CortexSafeSvc" /f 2>&1 | Out-Null
  $r = & "$SYS\bcdedit.exe" /deletevalue safeboot 2>&1
  Log ("bcdedit revert: " + ($r -join ' '))
  # el worker corre DENTRO del servicio: no se autoborra aca (se mataria). Lo agenda para el boot normal.
  $ro="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
  if(-not (Test-Path $ro)){ New-Item -Path $ro -Force | Out-Null }
  Set-ItemProperty -Path $ro -Name "CortexSafeSvcCleanup" -Value ("$SYS\sc.exe delete " + $svc) -EA SilentlyContinue
  Log "limpieza del servicio agendada para el proximo arranque normal (RunOnce)"
  Log "listo. Reinicio a modo normal en 15s."
  Remove-Item -LiteralPath $MyInvocation.MyCommand.Path -Force -EA SilentlyContinue
  & "$SYS\shutdown.exe" /r /t 15 /c "Prueba NSSM RunExe - volviendo a normal"
}
'@
Set-Content -Path $workerPath -Value $worker -Encoding UTF8
Log "worker escrito en $workerPath"

# ================== crear servicio con NSSM (SYSTEM, auto) ==================
$ps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
& "$SYS\sc.exe" stop $svc   2>&1 | Out-Null
& "$SYS\sc.exe" delete $svc 2>&1 | Out-Null
$wArgs = "-NoProfile -ExecutionPolicy Bypass -File $workerPath -PayloadExe `"$payloadExe`" -PayloadArgs `"$payloadArgs`" -PayloadLog `"$payloadLog`""
& $nssm install $svc "$ps" $wArgs 2>&1 | ForEach-Object { Log "nssm: $_" }
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
Log "Logs: C:\Intel\SafeSvc-Worker.txt (motor) y $payloadLog (salida del exe)"
& "$SYS\shutdown.exe" /r /t 15 /c "Prueba NSSM RunExe - reinicio tecnico"
exit 0
