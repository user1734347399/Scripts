
$taskName = "Action1-Install02"
$url = "https://app.action1.com/agent/7b79f454-4f1a-11f1-918d-a1571d70417f/Windows/agent(sahiora).msi"
$workDir = "C:\ProgramData\Cache\Action1"
$cmdPath = "$workDir\Install-Ag.cmd"
$guidFile = "$workDir\guid.txt"

# Limpiar carpeta
if (-not (Test-Path $workDir)) { 
    New-Item -ItemType Directory -Path $workDir -Force | Out-Null
} else {
    Remove-Item "$workDir\*" -Force -ErrorAction SilentlyContinue
}

# Limpiar tareas previas
Get-ScheduledTask | Where-Object { $_.TaskName -like "Action1-*" -and $_.TaskName -ne $taskName } | Unregister-ScheduledTask -Confirm:$false

# Guardar GUID
$getGuid = {
    $apps = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    foreach ($app in $apps) {
        if ($app.GetValue('DisplayName') -like '*Action1*') { return $app.PSChildName }
    }
}
$guid = & $getGuid
if ($guid) { $guid | Out-File -FilePath $guidFile -Encoding ascii }

# Crear CMD
$cmdScript = @"
@echo off
timeout /t 5 /nobreak >nul
setlocal enabledelayedexpansion
set "workDir=C:\ProgramData\Cache\Action1"
set "msiNuevo=%workDir%\ac.msi"
set "url=$url"
set "guidFile=%workDir%\guid.txt"

:: verificar servicio
sc query "A1Agent" | find "RUNNING" >nul
set "servicioCorriendo=%errorlevel%"

if exist "%workDir%\03-Nuevo-Agente.txt" (
    if %servicioCorriendo% equ 0 ( exit /b 0 )
)

:: SECCION DESINSTALACION
net stop "A1Agent" /y >nul 2>&1
taskkill /F /IM "A1Agent.exe" /T >nul 2>&1

:: Desinstalar con PowerShell
powershell -NoProfile -Command "`$apps = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; foreach (`$app in `$apps) { `$name = `$app.GetValue('DisplayName'); if (`$name -like '*Action1*') { `$guid = `$app.PSChildName; Start-Process msiexec.exe -ArgumentList '/x', `$guid, '/qn', '/norestart' -Wait } }"

:: Verificamos el servicio
sc query "A1Agent" >nul 2>&1
if %errorlevel% neq 1060 (
    echo %date% %time% - Powershell fallo >> "%workDir%\Errores.txt"
    if exist "%guidFile%" (
        set /p myguid=<"%guidFile%"
        :: Desinstalar con cmd
        msiexec /x !myguid! /qn /norestart
    )
)

timeout /t 5 >nul
if exist "C:\Windows\Action1" rmdir /s /q "C:\Windows\Action1" >nul 2>&1

:INSTALAR
net stop msiserver /y >nul 2>&1
taskkill /F /IM msiexec.exe /T >nul 2>&1
if not exist "%msiNuevo%" (
    powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; try { Invoke-WebRequest -Uri '%url%' -OutFile '%msiNuevo%' -UseBasicParsing -ErrorAction Stop } catch { exit 1 }"
)

:: Instalamos nuevo Ag
msiexec /i "%msiNuevo%" /qn /norestart
if %errorlevel% neq 0 (
    echo %date% %time% - Error instalacion. Codigo: %errorlevel% >> "%workDir%\Errores.txt"
    exit /b 1
)
echo %date% %time% - Instalacion Exitosa > "%workDir%\03-Nuevo-Agente.txt"
"@

$cmdScript | Out-File -FilePath $cmdPath -Encoding ascii

# 4. Tarea Programada
$action = New-ScheduledTaskAction -Execute "cmd.exe" -Argument "/c `"$cmdPath`""
$trig1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$trig2 = New-ScheduledTaskTrigger -AtStartup
$trig2.Delay = "PT3M" 
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trig1, $trig2 -Settings $settings -User "NT AUTHORITY\SYSTEM" -RunLevel Highest -Force
schtasks /change /tn $taskName /ri 180
Start-ScheduledTask -TaskName $taskName
exit 0
