#Requires -Version 5.1
<#
.SYNOPSIS
    Start-WhenServerReady - opreste stiva aplicatiei pe clienti, asteapta ca serverul
    srvMast sa fie pregatit si reporneste serviciile/aplicatiile pe clienti.

.DESCRIPTION
    Se lanseaza de pe un calculator CLIENT (ex. pcRD), cu drepturi de administrator.
    Pentru fiecare client din -ClientComputers (inclusiv masina locala):
      1. verifica faptul ca masina NU este server (Test-SrvMaster);
      2. scrie scriptul worker $ScriptTsk (continutul variabilei ScriptBlock $WorkerCode),
         fisierul de configurare (.json) si credentialul pentru server (.cred, DPAPI LocalMachine);
      3. elimina marcajul Zone.Identifier (Unblock-File) si restrictioneaza ACL-urile;
      4. inregistreaza un task programat (New-LtCheckTask) care porneste worker-ul o singura data.

    Worker-ul (check-StatusServer.ps1) ruleaza pe client, in sesiunea utilizatorului logat:
      act 1 : opreste fortat $AppToStop, opreste $ServicesToStop, sterge $FilesToDel;
      bucla : la fiecare $DelaySec secunde, timp de $DurationMin minute, verifica pe server
              existenta $FlagFile si $DriverList si ca $DriverList are minim $MinRows linii
              care contin $MatchText;
              cat timp serverul NU e pregatit si utilizatorul a pornit o aplicatie din
              $AppToStart -> afiseaza un mesaj de avertizare $ShowSec secunde;
      act 2 : cand serverul e pregatit -> opreste fortat $AppToStop, porneste $ServicesToStart
              si $AppToStart;
      final : sterge credentialul si isi sterge propriul task.

    NOTA Task Scheduler: intervalul minim de repetare al unui trigger este 1 minut, deci
    repetarea la 7 secunde NU se poate face din trigger. Task-ul porneste worker-ul o data,
    iar worker-ul face bucla interna de 7 secunde limitata la $DurationMin minute.
    Ca plasa de siguranta, task-ul are EndBoundary + DeleteExpiredTaskAfter.

.PARAMETER ClientComputers
    Clientii pe care se instaleaza task-ul. Masina locala este tratata fara remoting.

.PARAMETER ClientCredential
    Cont administrator pentru conectarea WinRM la clienti. Daca lipseste si exista
    clienti remote, se cere interactiv (Get-Credential).

.PARAMETER ServerCredential
    Cont folosit de worker pentru conectarea WinRM la server. Implicit = ClientCredential.
    In workgroup folositi forma 'srvMast\Administrator'.

.PARAMETER StopPhase
    AtStart   = act 1 se executa imediat la pornirea worker-ului (implicit).
    WhenReady = act 1 se executa doar cand serverul devine pregatit, inainte de act 2.

.PARAMETER WarnIntervalSec
    Intervalul minim intre doua mesaje de avertizare. 0 = la fiecare verificare.

.PARAMETER AddServerToTrustedHosts
    Adauga $ServerName in WSMan TrustedHosts pe fiecare client (necesar in workgroup).

.EXAMPLE
    .\Start-WhenServerReady.ps1 -Verbose

.EXAMPLE
    $c = Get-Credential -UserName 'Administrator' -Message 'Admin clienti'
    .\Start-WhenServerReady.ps1 -ClientCredential $c -ServerDir 'D:\EsserNet\Status' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter()]
    [string[]]$ClientComputers = @('pcRD', 'pcTc', 'pcDisp'),

    [Parameter()]
    [string]$ServerName = 'srvMast',

    [Parameter()]
    [System.Management.Automation.PSCredential]$ClientCredential = $null,

    [Parameter()]
    [System.Management.Automation.PSCredential]$ServerCredential = $null,

    # --- verificare server ---
    [Parameter()]
    [string]$ServerDir = 'C:\EsserNet\Status',      # TODO: calea reala pe srvMast

    [Parameter()]
    [string]$FlagFile = 'serverOk.txt',

    [Parameter()]
    [string]$DriverList = 'driverlist.txt',

    [Parameter()]
    [string]$MatchText = 'essernet',

    [Parameter()]
    [ValidateRange(1, 10000)]
    [int]$MinRows = 20,

    # --- actiuni pe client ---
    [Parameter()]
    [string[]]$ServicesToStop = @('servManagCore.exe', 'FirebirdGuardian*', 'FirebirdServer*'),

    [Parameter()]
    [string[]]$ServicesToStart = @('FirebirdServer*', 'FirebirdGuardian*', 'servManagCore.exe'),

    [Parameter()]
    [string[]]$AppToStop = @('appWiwatch.exe', 'appWiConfig.exe'),

    [Parameter()]
    [string[]]$AppToStart = @('appWiwatch.exe'),

    [Parameter()]
    [hashtable]$AppPath = @{},                      # ex. @{ 'appWiwatch.exe' = 'C:\AppWi\appWiwatch.exe' }

    [Parameter()]
    [string]$FilesDir = 'C:\AppWi\Data',            # TODO: directorul real al fisierelor de sters

    [Parameter()]
    [string[]]$FilesToDel = @('drv.txt', 'fisierA.xml', 'fisier.xml'),

    [Parameter()]
    [ValidateSet('AtStart', 'WhenReady')]
    [string]$StopPhase = 'AtStart',

    # --- temporizare ---
    [Parameter()]
    [ValidateRange(1, 3600)]
    [int]$DelaySec = 7,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$DurationMin = 10,

    [Parameter()]
    [ValidateRange(1, 60)]
    [int]$ShowSec = 4,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int]$WarnIntervalSec = 0,

    [Parameter()]
    [ValidateRange(5, 600)]
    [int]$SvcTimeoutSec = 60,

    [Parameter()]
    [ValidateRange(5, 300)]
    [int]$StartDelaySec = 10,

    # --- mesaje ---
    [Parameter()]
    [string]$MsgTitle = 'Server indisponibil',

    [Parameter()]
    [string]$MsgNotReady = 'Serverul nu este inca pregatit. Aplicatia va fi pornita automat cand serverul devine disponibil.',

    [Parameter()]
    [string]$MsgTimeout = 'Serverul nu a devenit disponibil in timpul alocat. Contactati administratorul.',

    # --- task / fisiere ---
    [Parameter()]
    [string]$ScriptTsk = 'C:\Windows\tools\check-StatusServer.ps1',

    [Parameter()]
    [string]$TaskName = 'check-StatusServer',

    [Parameter()]
    [string]$TaskPath = '\LaryTech\',

    # --- identificare rol masina (Test-SrvMaster) ---
    [Parameter()]
    [string]$RoleRegPath = 'HKLM:\SOFTWARE\LaryTech',  # TODO: cheia reala

    [Parameter()]
    [string]$RoleRegName = 'Role',                     # TODO: valoarea reala

    [Parameter()]
    [string]$RoleServerValue = 'srvMaster',            # TODO: continutul care identifica serverul

    [Parameter()]
    [string]$ServerOnlyProcess = 'driverRr',           # proces care ruleaza DOAR pe server

    [Parameter()]
    [switch]$AddServerToTrustedHosts
)

# =====================================================================================
#  WORKER - continutul fisierului $ScriptTsk (check-StatusServer.ps1)
#  Este scris pe fiecare client cu $WorkerCode.ToString(). Nu contine #Requires
#  (nu este permis in ScriptBlock); linia #Requires se adauga la scriere.
# =====================================================================================
$WorkerCode = {
<#
.SYNOPSIS
    check-StatusServer.ps1 - worker rulat de Task Scheduler pe masina client.
.DESCRIPTION
    Generat automat de Start-WhenServerReady.ps1. Nu se editeaza manual pe client.
    Configurarea se citeste din fisierul .json cu acelasi nume (sau -ConfigPath).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$ConfigPath = '',

    [Parameter()]
    [switch]$NoUi
)

$script:LogFile = ''

function Write-LtLog {
    <# .SYNOPSIS Scrie o linie in fisierul de log al worker-ului. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $line = '[{0}] [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try {
            if ((Test-Path -LiteralPath $script:LogFile -PathType Leaf) -and
                ((Get-Item -LiteralPath $script:LogFile).Length -gt 1MB)) {
                Move-Item -LiteralPath $script:LogFile -Destination ($script:LogFile + '.old') -Force
            }
            Add-Content -LiteralPath $script:LogFile -Value $line -Encoding ASCII -ErrorAction Stop
        }
        catch {
            Write-Verbose -Message ('Log indisponibil: ' + $_.Exception.Message)
        }
    }
    Write-Verbose -Message $line
}

function Get-LtStoredCredential {
    <# .SYNOPSIS Reconstruieste PSCredential din blob-ul DPAPI (LocalMachine). #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCredential])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [string]$BlobPath,

        [Parameter(Mandatory = $true)]
        [string]$Entropy
    )
    Add-Type -AssemblyName System.Security
    $blob    = [System.Convert]::FromBase64String(([System.IO.File]::ReadAllText($BlobPath)).Trim())
    $entr    = [System.Text.Encoding]::UTF8.GetBytes($Entropy)
    $plain   = [System.Security.Cryptography.ProtectedData]::Unprotect(
                   $blob, $entr, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    $chars   = [System.Text.Encoding]::UTF8.GetChars($plain)
    $secure  = New-Object -TypeName System.Security.SecureString
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $secure.MakeReadOnly()
    [System.Array]::Clear($plain, 0, $plain.Length)
    [System.Array]::Clear($chars, 0, $chars.Length)
    New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $UserName, $secure
}

function Connect-LtRemote {
    <# .SYNOPSIS Deschide o sesiune WinRM catre server. Returneaza PSSession sau $null. #>
    [CmdletBinding()]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]$Credential,

        [Parameter()]
        [ValidateRange(1, 120)]
        [int]$TimeoutSec = 5
    )
    $opt = New-PSSessionOption -OpenTimeout ($TimeoutSec * 1000) `
                               -OperationTimeout ($TimeoutSec * 2000) `
                               -CancelTimeout 2000
    try {
        New-PSSession -ComputerName $ComputerName -Credential $Credential `
                      -SessionOption $opt -ErrorAction Stop
    }
    catch {
        Write-LtLog -Level 'WARN' -Message ('Conectare esuata la {0}: {1}' -f $ComputerName, $_.Exception.Message)
        $null
    }
}

function Measure-MatchingLine {
    <# .SYNOPSIS Numara liniile care contin textul cautat (fara diferenta majuscule/minuscule). #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()]
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Line = @(),

        [Parameter(Mandatory = $true)]
        [string]$Match
    )
    $count = 0
    foreach ($l in $Line) {
        if ($null -ne $l -and $l.IndexOf($Match, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $count++
        }
    }
    $count
}

function Test-ServerStatus {
    <# .SYNOPSIS check-StatusServer: verifica pe server $FlagFile, $DriverList si numarul de linii. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Runspaces.PSSession]$Session,

        [Parameter(Mandatory = $true)]
        [string]$ServerDir,

        [Parameter()]
        [string]$FlagFile = 'serverOk.txt',

        [Parameter()]
        [string]$DriverList = 'driverlist.txt',

        [Parameter()]
        [string]$Match = 'essernet',

        [Parameter()]
        [int]$MinRows = 20
    )
    $status = [pscustomobject]@{
        Ready      = $false
        FlagExists = $false
        ListExists = $false
        MatchCount = 0
        Error      = ''
    }
    try {
        $remote = Invoke-Command -Session $Session -ErrorAction Stop `
                                 -ArgumentList $ServerDir, $FlagFile, $DriverList -ScriptBlock {
            param($Dir, $Flag, $List)
            $flagPath = Join-Path -Path $Dir -ChildPath $Flag
            $listPath = Join-Path -Path $Dir -ChildPath $List
            $out = @{
                FlagExists = (Test-Path -LiteralPath $flagPath -PathType Leaf)
                ListExists = (Test-Path -LiteralPath $listPath -PathType Leaf)
                Lines      = @()
            }
            if ($out.ListExists) {
                $out.Lines = @(Get-Content -LiteralPath $listPath -ErrorAction Stop)
            }
            $out
        }
        $status.FlagExists = [bool]$remote.FlagExists
        $status.ListExists = [bool]$remote.ListExists
        $status.MatchCount = Measure-MatchingLine -Line ([string[]]@($remote.Lines)) -Match $Match
        $status.Ready      = $status.FlagExists -and $status.ListExists -and ($status.MatchCount -ge $MinRows)
    }
    catch {
        $status.Error = $_.Exception.Message
    }
    $status
}

function Show-Warning {
    <# .SYNOPSIS Afiseaza un MessageBox de avertizare care se inchide singur dupa $ShowSec secunde. #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Message = 'mesaj-Default',

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$ShowSec = 3,

        [Parameter()]
        [string]$Title = 'Atentie',

        # Conditie optionala: mesajul se afiseaza doar daca scriptblock-ul intoarce $true.
        [Parameter()]
        [scriptblock]$Condition = $null
    )
    if ($null -ne $Condition) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if (-not $ok) { return $null }
    }
    $shell = $null
    try {
        $shell = New-Object -ComObject 'WScript.Shell'
        # 48 = icon avertizare, 4096 = system modal (deasupra celorlalte ferestre)
        $shell.Popup($Message, $ShowSec, $Title, 48 + 4096)
    }
    catch {
        Write-LtLog -Level 'WARN' -Message ('Show-Warning esuat: ' + $_.Exception.Message)
        $null
    }
    finally {
        if ($null -ne $shell) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}

function Invoke-ProcAction {
    <# .SYNOPSIS query-Proc: interogheaza / opreste fortat / porneste un proces. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [Alias('Proces')]
        [string]$Name,

        [Parameter()]
        [ValidateSet('Query', 'Stop', 'Start', 'Close')]
        [string]$Action = 'Query',

        [Parameter()]
        [string]$Path = '',

        [Parameter()]
        [string]$MsgWarn = '',

        [Parameter()]
        [int]$ShowSec = 3
    )
    if ($Action -eq 'Close') { $Action = 'Stop' }
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $procs    = @(Get-Process -Name $baseName -ErrorAction SilentlyContinue)
    $paths    = @()
    foreach ($p in $procs) {
        try { if ($p.Path) { $paths += $p.Path } } catch { Write-Verbose -Message 'Path inaccesibil' }
    }
    $result = [pscustomobject]@{
        Name    = $Name
        Action  = $Action
        Running = ($procs.Count -gt 0)
        Count   = $procs.Count
        Paths   = @($paths | Select-Object -Unique)
        Success = $true
        Message = ''
    }

    switch ($Action) {
        'Query' {
            if ($result.Running -and $MsgWarn) {
                [void](Show-Warning -Message $MsgWarn -ShowSec $ShowSec)
            }
        }
        'Stop' {
            foreach ($p in $procs) {
                try {
                    Stop-Process -Id $p.Id -Force -ErrorAction Stop
                    Write-LtLog -Message ('Proces oprit: {0} (PID {1})' -f $Name, $p.Id)
                }
                catch {
                    $result.Success = $false
                    $result.Message = $_.Exception.Message
                    Write-LtLog -Level 'WARN' -Message ('Oprire esuata {0} (PID {1}): {2}' -f $Name, $p.Id, $_.Exception.Message)
                }
            }
            if ($procs.Count -gt 0) {
                Wait-Process -Id ($procs | ForEach-Object { $_.Id }) -Timeout 10 -ErrorAction SilentlyContinue
            }
        }
        'Start' {
            if ($result.Running) {
                $result.Message = 'Ruleaza deja.'
            }
            elseif (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                $result.Success = $false
                $result.Message = 'Cale executabil necunoscuta sau inexistenta: ' + $Path
                Write-LtLog -Level 'ERROR' -Message ('{0}: {1}' -f $Name, $result.Message)
            }
            else {
                try {
                    $wd = Split-Path -Path $Path -Parent
                    Start-Process -FilePath $Path -WorkingDirectory $wd -ErrorAction Stop
                    Write-LtLog -Message ('Aplicatie pornita: ' + $Path)
                }
                catch {
                    $result.Success = $false
                    $result.Message = $_.Exception.Message
                    Write-LtLog -Level 'ERROR' -Message ('Pornire esuata {0}: {1}' -f $Path, $_.Exception.Message)
                }
            }
        }
    }
    $result
}

function Resolve-LtServiceName {
    <#
    .SYNOPSIS
        Transforma intrarile din lista in nume reale de servicii, pastrand ordinea.
        'x.exe' -> serviciile al caror PathName contine x.exe; altfel Name/DisplayName (-like).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Name = @()
    )
    $all   = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop)
    $found = New-Object -TypeName System.Collections.Generic.List[string]
    foreach ($n in $Name) {
        if ($n -like '*.exe') {
            $hits = @($all | Where-Object { $_.PathName -like ('*' + $n + '*') })
        }
        else {
            $hits = @($all | Where-Object { $_.Name -like $n -or $_.DisplayName -like $n })
        }
        if ($hits.Count -eq 0) {
            Write-LtLog -Level 'WARN' -Message ('Niciun serviciu nu corespunde intrarii: ' + $n)
        }
        foreach ($h in $hits) {
            if (-not $found.Contains($h.Name)) { $found.Add($h.Name) }
        }
    }
    $found.ToArray()
}

function Invoke-SvcAction {
    <# .SYNOPSIS query-Svc: interogheaza / opreste / porneste servicii, cu timeout. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Services,

        [Parameter()]
        [ValidateSet('Query', 'Stop', 'Start', 'Close')]
        [string]$Action = 'Query',

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [string]$MsgWarn = '',

        [Parameter()]
        [int]$ShowSec = 3
    )
    if ($Action -eq 'Close') { $Action = 'Stop' }
    $timeout = [System.TimeSpan]::FromSeconds($TimeoutSec)

    foreach ($svcName in (Resolve-LtServiceName -Name $Services)) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        $res = [pscustomobject]@{ Name = $svcName; Action = $Action; Status = ''; Success = $true; Message = '' }
        if ($null -eq $svc) {
            $res.Success = $false
            $res.Message = 'Serviciu inexistent.'
            $res
            continue
        }
        try {
            switch ($Action) {
                'Query' {
                    if ($svc.Status -eq 'Running' -and $MsgWarn) {
                        [void](Show-Warning -Message $MsgWarn -ShowSec $ShowSec)
                    }
                }
                'Stop' {
                    if ($svc.Status -ne 'Stopped') {
                        # ServiceController.Stop() nu blocheaza si opreste si serviciile dependente
                        if ($svc.Status -ne 'StopPending') { $svc.Stop() }
                        try {
                            $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, $timeout)
                            Write-LtLog -Message ('Serviciu oprit: ' + $svcName)
                        }
                        catch {
                            # timeout: se omoara procesul gazda doar daca nu e partajat cu alte servicii active
                            $wmi = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $svcName)
                            $procId = [int]$wmi.ProcessId
                            $shared = @(Get-CimInstance -ClassName Win32_Service -Filter ("ProcessId={0}" -f $procId) |
                                        Where-Object { $_.Name -ne $svcName -and $_.State -eq 'Running' })
                            if ($procId -gt 0 -and $shared.Count -eq 0) {
                                Stop-Process -Id $procId -Force -ErrorAction Stop
                                Write-LtLog -Level 'WARN' -Message ('Serviciu oprit fortat (PID {0}): {1}' -f $procId, $svcName)
                            }
                            else {
                                throw ('Timeout la oprirea serviciului ' + $svcName)
                            }
                        }
                    }
                }
                'Start' {
                    if ($svc.Status -ne 'Running') {
                        if ($svc.StartType -eq 'Disabled') { throw ('Serviciul este dezactivat: ' + $svcName) }
                        if ($svc.Status -ne 'StartPending') { $svc.Start() }
                        $svc.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, $timeout)
                        Write-LtLog -Message ('Serviciu pornit: ' + $svcName)
                    }
                }
            }
        }
        catch {
            $res.Success = $false
            $res.Message = $_.Exception.Message
            Write-LtLog -Level 'ERROR' -Message ('{0} {1}: {2}' -f $Action, $svcName, $_.Exception.Message)
        }
        $svc.Refresh()
        $res.Status = [string]$svc.Status
        $res
    }
}

function Remove-LtFile {
    <# .SYNOPSIS Sterge fisierele din lista (nume relative la $Directory sau cai absolute). #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter()]
        [string]$Directory = '',

        [Parameter()]
        [AllowEmptyCollection()]
        [string[]]$Name = @()
    )
    foreach ($f in $Name) {
        if ([System.IO.Path]::IsPathRooted($f)) { $p = $f } else { $p = Join-Path -Path $Directory -ChildPath $f }
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            Write-LtLog -Message ('Fisier inexistent (ignorat): ' + $p)
            continue
        }
        if ($PSCmdlet.ShouldProcess($p, 'Stergere fisier')) {
            try {
                Remove-Item -LiteralPath $p -Force -ErrorAction Stop
                Write-LtLog -Message ('Fisier sters: ' + $p)
            }
            catch {
                Write-LtLog -Level 'WARN' -Message ('Stergere esuata {0}: {1}' -f $p, $_.Exception.Message)
            }
        }
    }
}

function Resolve-LtAppPath {
    <# .SYNOPSIS Determina calea completa a unui executabil: config -> cale capturata -> App Paths. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Exe,

        [Parameter()]
        [hashtable]$Known = @{}
    )
    if ($Known.ContainsKey($Exe) -and $Known[$Exe] -and (Test-Path -LiteralPath $Known[$Exe] -PathType Leaf)) {
        return [string]$Known[$Exe]
    }
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths',
               'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths')
    foreach ($root in $roots) {
        $key = Join-Path -Path $root -ChildPath $Exe
        if (Test-Path -LiteralPath $key) {
            $v = (Get-Item -LiteralPath $key).GetValue('')
            if ($v) {
                $v = ([string]$v).Trim('"')
                if (Test-Path -LiteralPath $v -PathType Leaf) { return $v }
            }
        }
    }
    $null
}

function Invoke-LtStopPhase {
    <# .SYNOPSIS act 1: opreste fortat aplicatiile, opreste serviciile, sterge fisierele. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$AppPath
    )
    Write-LtLog -Message 'act 1: oprire aplicatii, servicii, stergere fisiere'
    foreach ($app in @($Config.AppToStop)) {
        $r = Invoke-ProcAction -Name $app -Action 'Stop'
        # se retine calea aplicatiilor ce vor fi repornite (daca nu e configurata explicit)
        if ($r.Paths.Count -gt 0 -and -not $AppPath.ContainsKey($app)) {
            $AppPath[$app] = $r.Paths[0]
        }
    }
    [void](Invoke-SvcAction -Services @($Config.ServicesToStop) -Action 'Stop' -TimeoutSec ([int]$Config.SvcTimeoutSec))
    Remove-LtFile -Directory $Config.FilesDir -Name @($Config.FilesToDel)
}

function Invoke-LtStartPhase {
    <# .SYNOPSIS act 2: porneste serviciile si (daca exista UI) aplicatiile. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Config,

        [Parameter(Mandatory = $true)]
        [hashtable]$AppPath,

        [Parameter()]
        [bool]$NoUi = $false
    )
    Write-LtLog -Message 'act 2: pornire servicii si aplicatii'
    [void](Invoke-SvcAction -Services @($Config.ServicesToStart) -Action 'Start' -TimeoutSec ([int]$Config.SvcTimeoutSec))
    if ($NoUi) {
        Write-LtLog -Level 'WARN' -Message 'Fara sesiune interactiva: aplicatiile nu sunt pornite.'
        return
    }
    foreach ($app in @($Config.AppToStart)) {
        $path = Resolve-LtAppPath -Exe $app -Known $AppPath
        [void](Invoke-ProcAction -Name $app -Action 'Start' -Path $path)
    }
}

function Invoke-LtMain {
    <# .SYNOPSIS Fluxul principal al worker-ului. Returneaza codul de iesire. #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter()]
        [bool]$NoUi = $false
    )
    $cfg = Get-Content -LiteralPath $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json
    $script:LogFile = [string]$cfg.LogFile
    Write-LtLog -Message ('=== START worker pe {0}, utilizator {1}, NoUi={2}' -f $env:COMPUTERNAME, [Environment]::UserName, $NoUi)

    $appPath = @{}
    if ($null -ne $cfg.AppPath) {
        foreach ($prop in $cfg.AppPath.PSObject.Properties) { $appPath[$prop.Name] = [string]$prop.Value }
    }

    $exitCode = 1
    $session  = $null
    try {
        $cred = Get-LtStoredCredential -UserName $cfg.ServerUser -BlobPath $cfg.CredFile -Entropy $cfg.CredEntropy

        if ($cfg.StopPhase -eq 'AtStart') { Invoke-LtStopPhase -Config $cfg -AppPath $appPath }

        $deadline = (Get-Date).AddMinutes([int]$cfg.DurationMin)
        $lastWarn = [datetime]::MinValue
        $ready    = $false
        $lastLog  = ''

        while ((Get-Date) -lt $deadline) {
            $t0 = Get-Date

            if ($null -eq $session -or $session.State -ne 'Opened') {
                if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
                $session = Connect-LtRemote -ComputerName $cfg.ServerName -Credential $cred
            }

            if ($null -ne $session) {
                $st = Test-ServerStatus -Session $session -ServerDir $cfg.ServerDir -FlagFile $cfg.FlagFile `
                                        -DriverList $cfg.DriverList -Match $cfg.MatchText -MinRows ([int]$cfg.MinRows)
                $msg = 'flag={0} lista={1} linii={2} ready={3} err={4}' -f `
                       $st.FlagExists, $st.ListExists, $st.MatchCount, $st.Ready, $st.Error
                if ($msg -ne $lastLog) { Write-LtLog -Message $msg; $lastLog = $msg }
                if ($st.Ready) { $ready = $true; break }
            }

            if (-not $NoUi) {
                $running = @(foreach ($app in @($cfg.AppToStart)) {
                                 $q = Invoke-ProcAction -Name $app -Action 'Query'
                                 if ($q.Running) { $q }
                             })
                if ($running.Count -gt 0 -and
                    ((Get-Date) - $lastWarn).TotalSeconds -ge [int]$cfg.WarnIntervalSec) {
                    [void](Show-Warning -Message $cfg.MsgNotReady -ShowSec ([int]$cfg.ShowSec) -Title $cfg.MsgTitle)
                    $lastWarn = Get-Date
                }
            }

            $remainMs = [int]([int]$cfg.DelaySec * 1000 - ((Get-Date) - $t0).TotalMilliseconds)
            if ($remainMs -gt 0) { Start-Sleep -Milliseconds $remainMs }
        }

        if ($ready) {
            Write-LtLog -Message 'Server pregatit.'
            if ($cfg.StopPhase -eq 'WhenReady') {
                Invoke-LtStopPhase -Config $cfg -AppPath $appPath
            }
            else {
                # utilizatorul poate fi pornit aplicatii intre timp -> oprire fortata inainte de act 2
                foreach ($app in @($cfg.AppToStop)) {
                    $r = Invoke-ProcAction -Name $app -Action 'Stop'
                    if ($r.Paths.Count -gt 0 -and -not $appPath.ContainsKey($app)) { $appPath[$app] = $r.Paths[0] }
                }
            }
            Invoke-LtStartPhase -Config $cfg -AppPath $appPath -NoUi $NoUi
            $exitCode = 0
        }
        else {
            Write-LtLog -Level 'WARN' -Message ('Timeout: serverul nu a fost pregatit in {0} minute.' -f $cfg.DurationMin)
            if (-not $NoUi) {
                [void](Show-Warning -Message $cfg.MsgTimeout -ShowSec ([int]$cfg.ShowSec) -Title $cfg.MsgTitle)
            }
            $exitCode = 2
        }
    }
    catch {
        Write-LtLog -Level 'ERROR' -Message ('Eroare neasteptata: ' + $_.Exception.Message)
        $exitCode = 1
    }
    finally {
        if ($null -ne $session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        if ($cfg.CredFile -and (Test-Path -LiteralPath $cfg.CredFile)) {
            Remove-Item -LiteralPath $cfg.CredFile -Force -ErrorAction SilentlyContinue
        }
        try {
            Unregister-ScheduledTask -TaskName $cfg.TaskName -TaskPath $cfg.TaskPath -Confirm:$false -ErrorAction Stop
            Write-LtLog -Message 'Task programat sters.'
        }
        catch {
            Write-LtLog -Level 'WARN' -Message ('Stergere task esuata: ' + $_.Exception.Message)
        }
        Write-LtLog -Message ('=== STOP worker, cod iesire {0}' -f $exitCode)
    }
    $exitCode
}

# Rulare directa (nu la dot-sourcing, folosit de teste)
if ($MyInvocation.InvocationName -ne '.') {
    if (-not $ConfigPath) { $ConfigPath = [System.IO.Path]::ChangeExtension($PSCommandPath, '.json') }
    $code = Invoke-LtMain -ConfigPath $ConfigPath -NoUi $NoUi.IsPresent
    exit $code
}
}   # sfarsit $WorkerCode

# =====================================================================================
#  DEPLOY - ruleaza pe fiecare client (local cu &, remote cu Invoke-Command)
#  $P.Mode = 'RoleOnly' -> doar Test-SrvMaster; 'Deploy' -> instalare completa.
# =====================================================================================
$DeployCode = {
    param(
        [hashtable]$P,
        [System.Management.Automation.PSCredential]$ServerCredential
    )
    $ErrorActionPreference = 'Stop'

    function Test-SrvMaster {
        <# .SYNOPSIS is-SrvMaster: $true daca masina curenta este serverul. #>
        [CmdletBinding()]
        [OutputType([bool])]
        param(
            [string]$RegPath,
            [string]$RegName,
            [string]$RegServerValue,
            [string]$ServerName,
            [string]$ServerOnlyProcess
        )
        if ($env:COMPUTERNAME -eq $ServerName) { return $true }
        if ($ServerOnlyProcess -and
            @(Get-Process -Name $ServerOnlyProcess -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
        $v = $null
        try { $v = (Get-ItemProperty -LiteralPath $RegPath -Name $RegName -ErrorAction Stop).$RegName } catch { $v = $null }
        if ($null -ne $v -and ([string]$v) -eq $RegServerValue) { return $true }
        $false
    }

    function Set-LtRestrictedAcl {
        <# .SYNOPSIS ACL fara mostenire: Administrators + SYSTEM FullControl (SID-uri, independent de limba). #>
        [CmdletBinding(SupportsShouldProcess = $true)]
        param([Parameter(Mandatory = $true)][string]$Path)
        $acl = New-Object -TypeName System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-32-544', 'S-1-5-18')) {
            $ident = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList $sid
            $rule  = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule `
                                -ArgumentList $ident, 'FullControl', 'Allow'
            $acl.AddAccessRule($rule)
        }
        if ($PSCmdlet.ShouldProcess($Path, 'Restrictionare ACL')) {
            [System.IO.File]::SetAccessControl($Path, $acl)
        }
    }

    function Write-LtSecureFile {
        <# .SYNOPSIS Creeaza fisierul gol, restrictioneaza ACL, apoi scrie continutul. #>
        [CmdletBinding()]
        param([string]$Path, [string]$Content, [bool]$Restrict)
        $enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $true
        [System.IO.File]::WriteAllText($Path, '', $enc)
        if ($Restrict) { Set-LtRestrictedAcl -Path $Path -Confirm:$false }
        [System.IO.File]::WriteAllText($Path, $Content, $enc)
    }

    function New-LtCheckTask {
        <# .SYNOPSIS make-Task: inregistreaza task-ul care porneste worker-ul o singura data. #>
        [CmdletBinding(SupportsShouldProcess = $true)]
        param(
            [string]$TaskName,
            [string]$TaskPath,
            [string]$ScriptPath,
            [string]$ConfigPath,
            [int]$DurationMin,
            [int]$StartDelaySec
        )
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        $psExe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arg = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ConfigPath "{1}"' -f `
               $ScriptPath, $ConfigPath
        if ($user) {
            # sesiunea utilizatorului logat: necesar pentru MessageBox si pornirea aplicatiei
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        }
        else {
            # nimeni logat: SYSTEM, fara UI (doar servicii)
            $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $arg += ' -NoUi'
        }
        $action  = New-ScheduledTaskAction -Execute $psExe -Argument $arg
        $startAt = (Get-Date).AddSeconds($StartDelaySec)
        $trigger = New-ScheduledTaskTrigger -Once -At $startAt
        $trigger.EndBoundary = $startAt.AddMinutes($DurationMin + 10).ToString('s')
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes ($DurationMin + 5)) `
                                                 -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 1) `
                                                 -MultipleInstances IgnoreNew `
                                                 -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

        if ($PSCmdlet.ShouldProcess(($TaskPath + $TaskName), 'Inregistrare task programat')) {
            $old = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
            if ($old) { Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false }
            [void](Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Action $action `
                                          -Trigger $trigger -Settings $settings -Principal $principal `
                                          -Description 'LaryTech: asteapta srvMast si reporneste stiva client. Se autosterge.')
        }
        if ($user) { $user } else { 'NT AUTHORITY\SYSTEM (fara UI)' }
    }

    $res = [ordered]@{ Computer = $env:COMPUTERNAME; Success = $false; IsServer = $false; Principal = ''; Message = '' }
    try {
        $res.IsServer = Test-SrvMaster -RegPath $P.RoleRegPath -RegName $P.RoleRegName `
                                       -RegServerValue $P.RoleServerValue -ServerName $P.ServerName `
                                       -ServerOnlyProcess $P.ServerOnlyProcess
        if ($P.Mode -eq 'RoleOnly') {
            $res.Success = $true
            return [pscustomobject]$res
        }
        if ($res.IsServer) { throw 'Masina este identificata ca SERVER - instalare refuzata.' }

        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $id
        if (-not $pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Sesiunea nu are drepturi de administrator (elevat).'
        }

        $scriptPath = $P.ScriptTsk
        $dir        = Split-Path -Path $scriptPath -Parent
        $cfgPath    = [System.IO.Path]::ChangeExtension($scriptPath, '.json')
        $credPath   = [System.IO.Path]::ChangeExtension($scriptPath, '.cred')
        $logPath    = [System.IO.Path]::ChangeExtension($scriptPath, '.log')
        if ($P.WhatIfMode) {
            $res.Success = $true
            $res.Message = 'WhatIf: nicio modificare.'
            return [pscustomobject]$res
        }

        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $dir -Force)
        }

        # 1. worker + deblocare (Zone.Identifier)
        Write-LtSecureFile -Path $scriptPath -Content $P.WorkerText -Restrict $true
        Unblock-File -LiteralPath $scriptPath
        if (Get-Item -LiteralPath $scriptPath -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) {
            throw 'Zone.Identifier persista pe ' + $scriptPath
        }

        # 2. credential server: DPAPI LocalMachine (blob inutilizabil pe alta masina)
        Add-Type -AssemblyName System.Security
        $pwdBytes = [System.Text.Encoding]::UTF8.GetBytes($ServerCredential.GetNetworkCredential().Password)
        $entropy  = [System.Text.Encoding]::UTF8.GetBytes($P.Config.CredEntropy)
        $blob     = [System.Security.Cryptography.ProtectedData]::Protect(
                        $pwdBytes, $entropy, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
        [System.Array]::Clear($pwdBytes, 0, $pwdBytes.Length)
        Write-LtSecureFile -Path $credPath -Content ([System.Convert]::ToBase64String($blob)) -Restrict $true

        # 3. configurare
        $cfg = $P.Config
        $cfg['ServerUser'] = $ServerCredential.UserName
        $cfg['CredFile']   = $credPath
        $cfg['LogFile']    = $logPath
        Write-LtSecureFile -Path $cfgPath -Content ($cfg | ConvertTo-Json -Depth 5) -Restrict $true

        # 4. TrustedHosts (workgroup) - optional
        if ($P.AddTrustedHost) {
            $cur  = [string](Get-Item -Path 'WSMan:\localhost\Client\TrustedHosts').Value
            $list = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($list -notcontains $P.ServerName -and $list -notcontains '*') {
                Set-Item -Path 'WSMan:\localhost\Client\TrustedHosts' -Value $P.ServerName -Concatenate -Force
            }
        }

        # 5. task programat
        $res.Principal = New-LtCheckTask -TaskName $P.Config.TaskName -TaskPath $P.Config.TaskPath `
                                         -ScriptPath $scriptPath -ConfigPath $cfgPath `
                                         -DurationMin ([int]$P.Config.DurationMin) `
                                         -StartDelaySec ([int]$P.StartDelaySec) -Confirm:$false
        $res.Success = $true
        $res.Message = 'Task inregistrat; porneste in {0} s.' -f $P.StartDelaySec
    }
    catch {
        $res.Message = $_.Exception.Message
    }
    [pscustomobject]$res
}   # sfarsit $DeployCode

# =====================================================================================
#  LAUNCHER
# =====================================================================================
function Test-LtIsLocal {
    <# .SYNOPSIS $true daca numele/IP-ul indica masina locala. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$ComputerName)
    if ($ComputerName -in @('.', 'localhost', '127.0.0.1', $env:COMPUTERNAME)) { return $true }
    $ips = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' |
             ForEach-Object { $_.IPAddress })
    $ips -contains $ComputerName
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'

    $me = New-Object -TypeName System.Security.Principal.WindowsPrincipal `
                     -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $me.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Rulati scriptul dintr-o consola PowerShell pornita ca administrator.'
    }

    $P = @{
        Mode              = 'RoleOnly'
        RoleRegPath       = $RoleRegPath
        RoleRegName       = $RoleRegName
        RoleServerValue   = $RoleServerValue
        ServerName        = $ServerName
        ServerOnlyProcess = $ServerOnlyProcess
    }
    $localRole = & $DeployCode -P $P -ServerCredential $null
    if ($localRole.IsServer) { throw 'Scriptul trebuie lansat de pe un CLIENT, nu de pe server.' }

    $remoteTargets = @($ClientComputers | Where-Object { -not (Test-LtIsLocal -ComputerName $_) })
    if ($remoteTargets.Count -gt 0 -and $null -eq $ClientCredential) {
        $ClientCredential = Get-Credential -UserName 'Administrator' -Message 'Cont administrator pentru clienti (WinRM)'
    }
    if ($null -eq $ServerCredential) {
        if ($null -ne $ClientCredential) {
            $ServerCredential = $ClientCredential
        }
        else {
            $ServerCredential = Get-Credential -UserName ($ServerName + '\Administrator') -Message 'Cont pentru server (WinRM)'
        }
    }

    $P.Mode          = 'Deploy'
    $P.WhatIfMode    = [bool]$WhatIfPreference
    $P.ScriptTsk     = $ScriptTsk
    $P.StartDelaySec = $StartDelaySec
    $P.AddTrustedHost = $AddServerToTrustedHosts.IsPresent
    $P.WorkerText    = "#Requires -Version 5.1`r`n" + $WorkerCode.ToString().Trim() + "`r`n"
    $P.Config        = @{
        ServerName      = $ServerName
        ServerDir       = $ServerDir
        FlagFile        = $FlagFile
        DriverList      = $DriverList
        MatchText       = $MatchText
        MinRows         = $MinRows
        ServicesToStop  = $ServicesToStop
        ServicesToStart = $ServicesToStart
        AppToStop       = $AppToStop
        AppToStart      = $AppToStart
        AppPath         = $AppPath
        FilesDir        = $FilesDir
        FilesToDel      = $FilesToDel
        StopPhase       = $StopPhase
        DelaySec        = $DelaySec
        DurationMin     = $DurationMin
        ShowSec         = $ShowSec
        WarnIntervalSec = $WarnIntervalSec
        SvcTimeoutSec   = $SvcTimeoutSec
        MsgTitle        = $MsgTitle
        MsgNotReady     = $MsgNotReady
        MsgTimeout      = $MsgTimeout
        TaskName        = $TaskName
        TaskPath        = $TaskPath
        CredEntropy     = 'LaryTech|check-StatusServer'
    }

    $results = foreach ($target in $ClientComputers) {
        if (-not $PSCmdlet.ShouldProcess($target, 'Instalare task check-StatusServer')) {
            $P.WhatIfMode = $true
        }
        Write-Verbose -Message ('Instalare pe ' + $target)
        if (Test-LtIsLocal -ComputerName $target) {
            & $DeployCode -P $P -ServerCredential $ServerCredential
        }
        else {
            $s = $null
            try {
                $s = New-PSSession -ComputerName $target -Credential $ClientCredential -ErrorAction Stop
                Invoke-Command -Session $s -ScriptBlock $DeployCode -ArgumentList $P, $ServerCredential |
                    Select-Object -Property Computer, Success, IsServer, Principal, Message
            }
            catch {
                [pscustomobject]@{ Computer = $target; Success = $false; IsServer = $false; Principal = ''; Message = $_.Exception.Message }
            }
            finally {
                if ($null -ne $s) { Remove-PSSession -Session $s }
            }
        }
        $P.WhatIfMode = [bool]$WhatIfPreference
    }

    $results | Format-Table -Property Computer, Success, IsServer, Principal, Message -AutoSize -Wrap
    if (@($results | Where-Object { -not $_.Success }).Count -gt 0) { exit 1 }
}
