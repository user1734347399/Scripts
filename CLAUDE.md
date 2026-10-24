# CLAUDE.md

Repositorio de scripts PowerShell que se despliegan con **Action1** (RMM).
Action1 los ejecuta como **NT AUTHORITY\SYSTEM**, sin usuario interactivo, con
Windows PowerShell 5.1 por defecto.

## Reglas obligatorias para cada script

1. **Nombre con prefijo numérico incremental**: `01-Nombre.ps1`, `02-Nombre.ps1`, ...
   Mirar el número más alto existente y usar el siguiente. `00-` queda reservado
   para pruebas.
2. **Encabezado de comentario al inicio** con, como mínimo, la sección `Objetivo`:

   ```powershell
   <#
   Objetivo:
       Qué hace el script y por qué.
   Notas:
       Requisitos, parámetros, efectos secundarios (opcional).
   #>
   ```

3. **Nunca debe colgar Action1**:
   - Definir un **tiempo máximo total** (`$TiempoMaximoTotalSeg`) y controlarlo con
     un cronómetro (`[Diagnostics.Stopwatch]`); al superarlo, abortar con exit code
     distinto de 0.
   - Cada paso que pueda bloquearse (descargas, instaladores, servicios, procesos
     externos, red) lleva **su propio timeout**: `Start-Process -PassThru` +
     `WaitForExit(ms)` (y matar el proceso si vence), `Invoke-WebRequest -TimeoutSec`,
     `Wait-Job -Timeout`, `WaitForStatus(..., timeout)`, etc.
   - Nada interactivo: sin `Read-Host`, `Pause`, `-Confirm` ni ventanas/GUI.
     Usar `-Confirm:$false` / instaladores silenciosos.
4. **Exit code explícito**: `exit 0` si salió bien, distinto de 0 si falló.
   Action1 se basa en él.
5. **Salida legible** en consola (`Write-Output`) con mensajes por paso, porque es
   lo que se ve en el log de Action1.
6. Tener en cuenta el contexto SYSTEM: no hay `HKCU`/perfil del usuario logueado,
   `$env:USERPROFILE` apunta a `C:\Windows\System32\config\systemprofile`, y las
   unidades de red mapeadas no existen.
7. Compatibles con **Windows PowerShell 5.1** (no usar sintaxis exclusiva de PS 7).
8. **Codificación UTF-8 con BOM** si el archivo tiene caracteres no ASCII (acentos, ñ):
   PowerShell 5.1 lee los `.ps1` sin BOM como ANSI y rompe esos caracteres.

## Pruebas

El workflow `.github/workflows/probar-ps.yml` (runner `windows-latest`):
- valida la sintaxis con el parser de PowerShell,
- ejecuta el script como SYSTEM con `PsExec -s`,
- muestra la salida y el exit code.

Se lanza manualmente (workflow_dispatch, input `script`, p. ej. `00-Prueba.ps1`)
y también automáticamente al hacer push de cambios en archivos `.ps1`.
