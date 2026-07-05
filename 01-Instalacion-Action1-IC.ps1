<#
02
Si no existe alguna carpeta la crea
Si no esta descargado el nuevo msi lo descarga
Si el agente ya se descargo, no lo vuelve a descargar
Si el agente no se desinstala, registra un log con Errores
Si el agente se logra instalar, se registra una bandera
Si el agente nuevo ya esta instalado, no vuelve a instalarlo
#>

# 1. Variables
$workDir       = "C:\ProgramData\Action1"
$msiNuevo      = "$workDir\ac.msi"
$url           = "https://app.action1.com/agent/0e6249a4-4fea-11f1-a663-e9948cfdb795/Windows/agent(ic).msi"
$guidFile      = "$workDir\guid.txt"
$bandera       = "$workDir\Action1.flag"
$logErrores    = "$workDir\Errores.txt"
$logMsi        = "$workDir\msi-install.log"
$logEset       = "$workDir\Eset.txt"
$ServiceName   = "A1Agent"

# 2. Crear carpetas
if (-not (Test-Path $workDir)) { 
    New-Item -ItemType Directory -Path $workDir | Out-Null
}

# 3. Verificar Bandera
$servicioCorriendo = (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue).Status -eq "Running"
if (Test-Path $bandera) {
    if ($servicioCorriendo) {
        $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$fecha] Tarea Exitosa`r`n" | Out-File -FilePath $logEset -Append -Encoding utf8
        Exit 0
    }
}

# Guardar GUID
$getGuid = {
    $apps = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($app in $apps) {
        if ($app.GetValue('DisplayName') -like '*Action1*') { return $app.PSChildName }
    }
}
$oldGuid = & $getGuid

if ($oldGuid) { 
    $oldGuid | Out-File -FilePath $guidFile -Encoding utf8 
}

# Frenar servicios
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
Stop-Process -Name $ServiceName -Force -ErrorAction SilentlyContinue

# Desinstalar con monitoreo
if ($oldGuid) {
    $processDesinstalacion = Start-Process msiexec.exe -ArgumentList "/x", $oldGuid, "/qn", "/norestart" -PassThru -NoNewWindow
    
    # Espera inteligente: Maximo 60 segundos por maquina lenta
    $timeoutDesinstalacion = 0
    while (-not $processDesinstalacion.HasExited -and $timeoutDesinstalacion -lt 30) {
        Start-Sleep -Seconds 2
        $timeoutDesinstalacion += 2
    }
    
    $servicioExiste = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($servicioExiste) {
        $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$fecha] - Intento PowerShell fallo. Reintentando por CMD..." | Out-File -FilePath $logErrores -Append -Encoding utf8
        
        if (Test-Path $guidFile) {
            $myguid = Get-Content -Path $guidFile -TotalCount 1
            $processCmd = Start-Process cmd.exe -ArgumentList "/c msiexec /x $myguid /qn /norestart" -PassThru -NoNewWindow
            
            $timeoutCmd = 0
            while (-not $processCmd.HasExited -and $timeoutCmd -lt 30) {
                Start-Sleep -Seconds 2
                $timeoutCmd += 2
            }
        }
    }
    
    # Verificacion final de la desinstalacion
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$fecha] - ERROR: No desinstalo. Se cancela." | Out-File -FilePath $logErrores -Append -Encoding utf8
        Exit 1
    }
}

if (Test-Path "C:\Windows\Action1") {
    Remove-Item "C:\Windows\Action1" -Recurse -Force -ErrorAction SilentlyContinue
}

# Descarga segura
if (-not (Test-Path $msiNuevo) -or (Get-Item $msiNuevo).Length -eq 0) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $msiNuevo -UseBasicParsing -ErrorAction Stop
    }
    catch {
        $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$fecha] - Error descarga MSI" | Out-File -FilePath $logErrores -Append -Encoding utf8
        Exit 1
    }
}

# Instalacion limpia
cmd.exe /c "net stop msiserver /y && taskkill /F /IM msiexec.exe /T" >nul 2>&1
Start-Sleep -Seconds 3

if (Test-Path $msiNuevo) {
    cmd.exe /c start "" msiexec.exe /i "$msiNuevo" /qn /norestart /L*V "$logMsi"
    Start-Sleep -Seconds 20
}

# Bucle inteligente
$MaxSeconds = 220
$CheckInterval = 5
$ElapsedSeconds = 0

while ($ElapsedSeconds -lt $MaxSeconds) {
    
    $servicioFinal = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    
    if ($servicioFinal -and $servicioFinal.Status -eq 'Running') {
        $fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$fecha] - Instalacion Exitosa" | Out-File -FilePath $bandera -Encoding utf8
        "[$fecha]`r`nTarea Exitosa`r`n" | Out-File -FilePath $logEset -Append -Encoding utf8
        Exit 0
    }
    
    Start-Sleep -Seconds $CheckInterval
    $ElapsedSeconds += $CheckInterval
}

$fecha = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
"[$fecha] - Error instalacion: El servicio no inicio luego de $MaxSeconds segundos" | Out-File -FilePath $logErrores -Append -Encoding utf8
Exit 1
