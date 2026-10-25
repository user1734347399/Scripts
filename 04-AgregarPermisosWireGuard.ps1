try { $Host.UI.RawUI.WindowTitle = "04" } catch {}

# Identificar los grupos locales por SID
Write-Host "`n1 Por favor espere" -ForegroundColor Yellow
$groupSID = "S-1-5-32-556" # Operadores de Red
$adminSID = "S-1-5-32-544" # Administradores

try {
    $groupName = (Get-LocalGroup | Where-Object { $_.SID -eq $groupSID }).Name
    $adminGroupName = (Get-LocalGroup | Where-Object { $_.SID -eq $adminSID }).Name
    if (-not $groupName) { throw }
} catch {
    Write-Host "ERROR: No se pudo encontrar los grupos locales" -ForegroundColor Red
	Start-Sleep -Seconds 3
    exit 1
}

function Get-MiembrosSID($grupoADSI) {
    $sids = @()
    try { $miembros = @($grupoADSI.Invoke("Members")) } catch { $miembros = @() }
    foreach ($m in $miembros) {
        try {
            $bytes = $m.GetType().InvokeMember("objectSid", 'GetProperty', $null, $m, $null)
            $sids += (New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value
        } catch { }
    }
    return $sids
}

Write-Host "`n2 Por favor espere" -ForegroundColor Yellow

# Buscar TODOS los usuarios que tienen perfil en el equipo
$profileListPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*"
$profiles = Get-ItemProperty $profileListPath -ErrorAction SilentlyContinue | Where-Object {
    # Filtramos SIDs del sistema (SYSTEM, LocalService, NetworkService tienen SIDs cortos)
    $_.PSChildName -like "S-1-5-21-*" -and
    $_.PSChildName -notlike "*.bak" -and
    # Excluimos la cuenta Administrador integrada del dominio o local (termina en -500)
    $_.PSChildName -notlike "*-500"
}

if (-not $profiles) {
    Write-Host "AVISO: No se encontraron usuarios validos" -ForegroundColor Yellow
    exit 0
}
Write-Host "`n3 Por favor espere" -ForegroundColor Yellow

# Instanciar el grupo local usando la API WinNT
$groupADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$groupName,group"
$adminADSI = [ADSI]"WinNT://$env:COMPUTERNAME/$adminGroupName,group"
$adminSIDs = Get-MiembrosSID $adminADSI
$groupSIDs = Get-MiembrosSID $groupADSI

# Procesar cada SID encontrado
foreach ($prof in $profiles) {
    $userSID = $prof.PSChildName

    # Validar si este SID es Administrador local
    $isAdmin = $adminSIDs -contains $userSID
    if ($isAdmin) {
        #Write-Host "El usuario ya es Administrador" -ForegroundColor Yellow
        continue
    }

    # Verificar si ya es miembro de Operadores de Red
    $isMember = $groupSIDs -contains $userSID

    # Si no es miembro y no es admin, lo agregamos usando el SID
    if (-not $isMember) {
        try {
            $groupADSI.Add("WinNT://$userSID")
            Write-Host "Usuario agregado al grupo" -ForegroundColor Green
        } catch {
            # Write-Host "ERROR: No se pudo agregar al grupo" -ForegroundColor Red
        }
    } else {
        Write-Host "El usuario ya tiene permisos" -ForegroundColor Cyan
    }
}

# Agregar clave en el registro
Write-Host "`n4 Por favor espere" -ForegroundColor Yellow
$regPath = "HKLM:\Software\WireGuard"
if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
New-ItemProperty -Path $regPath -Name "LimitedOperatorUI" -Value 1 -PropertyType DWORD -Force | Out-Null

Write-Host "`n5 Terminando" -ForegroundColor Green
Start-Sleep -Seconds 2
exit 0
