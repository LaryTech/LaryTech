# Start-WhenServerReady - plan de implementare

Fisiere:

| Fisier | Rol |
|---|---|
| `tools/Start-WhenServerReady/Start-WhenServerReady.ps1` | launcher (rulat pe pcRD) + `$WorkerCode` (ScriptBlock) + `$DeployCode` |
| `C:\Windows\tools\check-StatusServer.ps1` | worker generat pe fiecare client din `$WorkerCode` |
| `C:\Windows\tools\check-StatusServer.json` | configurarea worker-ului (generata) |
| `C:\Windows\tools\check-StatusServer.cred` | parola server, DPAPI LocalMachine (stearsa la final de worker) |
| `C:\Windows\tools\check-StatusServer.log` | log worker |
| `tests/Start-WhenServerReady.Tests.ps1` | teste Pester pentru partile independente de Windows |

Nume ales: **Start-WhenServerReady** (verb aprobat `Start`, descrie exact efectul: porneste stiva
client cand serverul e pregatit). Worker-ul pastreaza numele cerut, `check-StatusServer.ps1`.

---

## 1. Context

- Retea 192.168.101.x; server `srvMast`; clienti `pcRD`, `pcTc`, `pcDisp`.
- Server: servicii Firebird + servManagCore (care porneste ~50 x `driverRr.exe`), uneori `appWiwatch.exe`.
- Clienti: aceleasi servicii (fara `driverRr.exe`) + `appWiwatch.exe`.
- Lansare de pe `pcRD`; scriptul actioneaza local si pe ceilalti clienti.

## 2. Corectii tehnice fata de specificatie (obligatorii)

| Cerinta | Problema | Solutie aplicata |
|---|---|---|
| Task repetat la 7 s | Task Scheduler: intervalul minim de repetare este **1 minut** | Task-ul porneste worker-ul **o singura data**; worker-ul face bucla interna la 7 s, limitata la 10 min |
| Stergere task dupa 10 min | - | Worker-ul isi sterge task-ul in `finally`; plasa de siguranta: `EndBoundary` + `DeleteExpiredTaskAfter`, `ExecutionTimeLimit` = durata + 5 min |
| MessageBox din task | Un task rulat ca SYSTEM / "Run whether user is logged on or not" ruleaza in **sesiunea 0**: fereastra nu este vizibila, aplicatia pornita nici atat | Principal = utilizatorul logat, `LogonType Interactive`, `RunLevel Highest`. Daca nu e nimeni logat: SYSTEM cu `-NoUi` (doar servicii) |
| Parola in clar `$pass='...'` | Interzis de CLAUDE.md si PSScriptAnalyzer (`PSAvoidUsingPlainTextForPassword`) | `PSCredential` (Get-Credential); pe client parola e stocata DPAPI **LocalMachine**, ACL Administrators+SYSTEM, si e stearsa la finalul rularii |
| "Windows protected your PC" (SmartScreen) | SmartScreen se aplica executabilelor descarcate lansate din Explorer, nu `powershell.exe -File`. Pentru `.ps1` blocajul real este **ExecutionPolicy** + marcajul **Zone.Identifier** (MOTW) | Fisierul e scris local de script (fara MOTW); se aplica oricum `Unblock-File` si se verifica lipsa stream-ului `Zone.Identifier`; task-ul ruleaza cu `-ExecutionPolicy Bypass` (doar la nivel de proces) |
| "Lista alba" Windows | AppLocker/WDAC sunt alt mecanism | `C:\Windows\tools` este acoperit de regula implicita AppLocker "scripturi din folderul Windows"; folderul nu poate fi scris de non-admini (important: task-ul ruleaza elevat). **Nu** se adauga excluderi Defender |
| `servManagCore.exe` ca nume de serviciu | Este numele executabilului, nu al serviciului | Intrarile `*.exe` se rezolva prin `Win32_Service.PathName`; restul prin `Name`/`DisplayName` cu wildcard (`FirebirdServer*`, `FirebirdGuardian*`) |
| `-action close` in exemple | Nu era in ValidateSet | `ValidateSet('Query','Stop','Start','Close')`, `Close` = `Stop` |

## 3. Arhitectura (propunerea 1 - implementata)

```
pcRD (admin)                         client X (pcRD / pcTc / pcDisp)                srvMast
Start-WhenServerReady.ps1
 |- verifica admin + Test-SrvMaster (local)
 |- pentru fiecare client:
 |   local  -> & $DeployCode
 |   remote -> Invoke-Command $DeployCode ---> Test-SrvMaster (refuza daca e server)
 |                                         scrie check-StatusServer.ps1/.json/.cred
 |                                         Unblock-File + ACL
 |                                         New-LtCheckTask (porneste peste 10 s)
 |                                                 |
 |                                         [Task] check-StatusServer.ps1
 |                                           act 1 (AtStart)
 |                                           bucla 7 s / 10 min:
 |                                             Connect-LtRemote  ----- WinRM ------>  PSSession
 |                                             Test-ServerStatus ----------------->  flag + driverlist
 |                                             nepregatit + appWiwatch pornit -> Show-Warning
 |                                           pregatit -> stop $AppToStop -> act 2
 |                                           finally: sterge .cred, sterge task
```

### Corespondenta nume cerute -> functii

| Cerut | Implementat | Unde |
|---|---|---|
| is-SrvMaster | `Test-SrvMaster` | `$DeployCode` |
| make-Task | `New-LtCheckTask` | `$DeployCode` |
| conectare Remote | `Connect-LtRemote` (returneaza `PSSession`) | worker |
| check-StatusServer | `Test-ServerStatus` (+ `Measure-MatchingLine`) | worker |
| show-warning | `Show-Warning -Message -ShowSec -Title -Condition` | worker |
| query-Proc | `Invoke-ProcAction -Name/-Proces -Action -Path -MsgWarn` | worker |
| query-Svc | `Invoke-SvcAction -Services -Action -TimeoutSec -MsgWarn` | worker |
| act 1 / act 2 | `Invoke-LtStopPhase` / `Invoke-LtStartPhase` | worker |

Verbele `is`, `make`, `query`, `check` nu sunt aprobate (`Get-Verb`), de aici redenumirea.

### Test-SrvMaster - criterii (oricare => server)

1. `$env:COMPUTERNAME -eq $ServerName`;
2. ruleaza cel putin un proces `driverRr` (exista doar pe server);
3. valoarea de registry `$RoleRegPath\$RoleRegName` este egala cu `$RoleServerValue`.

Criteriile 1-2 protejeaza chiar daca cheia de registry lipseste.

## 4. Fluxul worker-ului

1. Citeste `.json`, reconstruieste credentialul din `.cred`.
2. **act 1** (daca `StopPhase = AtStart`): opreste fortat `$AppToStop` (retine calea exe pentru repornire),
   opreste `$ServicesToStop` in ordinea data (timeout `SvcTimeoutSec`, apoi kill al procesului gazda doar
   daca nu e partajat), sterge `$FilesToDel` din `$FilesDir`.
3. Bucla pana la `DurationMin`, pas `DelaySec` (timpul de executie se scade din pauza):
   - reconecteaza sesiunea daca e cazul;
   - pe server: `FlagFile` exista **si** `DriverList` exista **si** are `>= MinRows` linii cu `MatchText`;
   - pregatit -> iesire din bucla;
   - nepregatit **si** o aplicatie din `$AppToStart` ruleaza -> `Show-Warning` (`ShowSec` s);
     nepregatit si nicio aplicatie -> nimic.
4. Pregatit: opreste fortat `$AppToStop` (sau act 1 complet daca `StopPhase = WhenReady`),
   porneste `$ServicesToStart` in ordinea data, apoi `$AppToStart`.
5. Timeout: log + mesaj `MsgTimeout`; serviciile raman oprite (cod iesire 2).
6. `finally`: inchide sesiunea, sterge `.cred`, sterge task-ul.

Calea aplicatiei de pornit: `-AppPath` explicit -> calea capturata la oprire -> registry `App Paths`.

## 5. Cerinte prealabile (o singura data)

| Masina | Cerinta |
|---|---|
| toti | `Enable-PSRemoting -Force` (serviciul WinRM pornit) |
| pcRD | `TrustedHosts` contine `pcTc,pcDisp` (workgroup) |
| clienti | `TrustedHosts` contine `srvMast` - sau parametrul `-AddServerToTrustedHosts` |
| toti | in workgroup, alt cont admin decat `Administrator` (RID 500) cere `LocalAccountTokenFilterPolicy = 1` |
| clienti | utilizatorul operator este in grupul local Administrators (task-ul ruleaza elevat in sesiunea lui) |
| srvMast | calea `-ServerDir` exista; contul `-ServerCredential` o poate citi |

## 6. Puncte deschise (de completat inainte de productie)

- [ ] `ServerDir` - directorul real cu `serverOk.txt` / `driverlist.txt` pe srvMast.
- [ ] `FilesDir` - directorul real cu `drv.txt`, `fisierA.xml`, `fisier.xml` pe clienti.
- [ ] `RoleRegPath`, `RoleRegName`, `RoleServerValue` - cheia reala care identifica serverul.
- [ ] Numele exacte ale serviciilor Firebird (2.5: Guardian + Server; 3.0+: de regula doar Server).
- [ ] `AppPath` pentru `appWiwatch.exe` daca nu este inregistrat in `App Paths`.
- [ ] Politica de mesaj: `WarnIntervalSec = 0` respecta specificatia (mesaj la fiecare verificare);
      recomandat 21 (o data la 3 verificari).

Limitari cunoscute:

- `-WindowStyle Hidden` poate lasa o fereastra de consola vizibila o fractiune de secunda.
- Aplicatia este pornita elevat (mosteneste tokenul task-ului).
- Daca `ExecutionTimeLimit` opreste fortat worker-ul, `finally` nu ruleaza: `.cred` ramane pana la
  urmatoarea instalare, task-ul se sterge la expirarea `EndBoundary`.
- SMB nu este folosit (doar WinRM), deci nu apare conflictul de credentiale SMB (eroarea 1219).

## 7. Plan de testare

| Nivel | Ce | Cum |
|---|---|---|
| Unitar | `Measure-MatchingLine`, `Show-Warning -Condition`, `Remove-LtFile`, parsare worker, ASCII | `.\build.ps1 -Task Test` |
| Lint | toate functiile | `Invoke-ScriptAnalyzer -Path .\tools -Recurse -Settings .\PSScriptAnalyzerSettings.psd1` |
| Uscat | fara modificari | `.\Start-WhenServerReady.ps1 -WhatIf -Verbose` |
| Un client | doar pcRD, durata scurta | `-ClientComputers pcRD -DurationMin 2`, urmarit `check-StatusServer.log` |
| Server nepregatit | flag lipsa + appWiwatch pornit | mesaj la `ShowSec` s; fara appWiwatch - fara mesaj |
| Server pregatit | creare flag + 20 linii `essernet` | servicii + aplicatie pornite, task sters, `.cred` sters |
| Protectie server | rulare cu `-ClientComputers srvMast` | refuz "identificata ca SERVER" |

---

## 8. Propunerea 2 - script hibrid CMD + PowerShell (plan, neimplementat)

### Structura fisierului `Start-WhenServerReady.cmd`

```
<# :
@echo off
setlocal
set "tg=#-tag"
set "tg=%tg%-"
rem --- extrage sectiunile marcate in %TEMP% si ruleaza launcher-ul ---
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$t=$env:tg; $l=[IO.File]::ReadAllLines('%~f0');" ^
  "foreach($n in 'launcher','worker'){ $b=[Array]::IndexOf($l,$t+$n+'-begin'); $e=[Array]::IndexOf($l,$t+$n+'-end');" ^
  " if($b -lt 0 -or $e -le $b){ exit 3 }; [IO.File]::WriteAllLines((Join-Path $env:TEMP ('lt-'+$n+'.ps1')), $l[($b+1)..($e-1)]) }"
if errorlevel 1 exit /b %errorlevel%
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%TEMP%\lt-launcher.ps1" -WorkerFile "%TEMP%\lt-worker.ps1" %*
exit /b %errorlevel%
#>
#-tag-launcher-begin
... cod launcher (fara $WorkerCode; citeste -WorkerFile) ...
#-tag-launcher-end
#-tag-worker-begin
... cod check-StatusServer.ps1 ...
#-tag-worker-end
```

### De ce tag-ul se construieste din bucati (`set tg=...`)

Codul de extragere cauta linia exacta `#-tag-worker-begin`. Daca acest text ar aparea literal in
sectiunea CMD, `IndexOf` l-ar gasi acolo primul. Construind tag-ul din `%tg%` + nume, textul complet
nu exista decat pe liniile-marcaj. Comparatia se face pe **linie intreaga**, nu pe subsir.

### Etape

1. Antet poliglot `<# : ... #>`: pentru CMD, `<# :` este o eticheta ignorata; pentru PowerShell,
   intreaga parte CMD este un comentariu bloc.
2. Extragere sectiuni cu marcaje begin/end in fisiere `.ps1` separate (fara `Invoke-Expression`,
   interzis de PSScriptAnalyzer).
3. Launcher-ul primeste calea worker-ului ca parametru si o copiaza pe clienti (Invoke-Command cu
   continutul, nu copiere SMB).
4. Restul fluxului este identic cu propunerea 1.

### Constrangeri ale variantei CMD

- Fisierul `.cmd` trebuie salvat **ASCII, fara BOM, cu CRLF** (cmd.exe esueaza la BOM si la LF singur);
  adaugati `*.cmd text eol=crlf` in `.gitattributes`.
- Caracterele `%`, `^`, `&`, `|`, `!` din partea CMD cer escapare; codul PowerShell din `-Command` e fragil.
- Fisierele temporare din `%TEMP%` pot fi scrise de utilizator: trebuie copiate in `C:\Windows\tools`
  inainte de a fi rulate elevat.
- Nu poate fi analizat de PSScriptAnalyzer si nici testat cu Pester ca intreg.

### Comparatie si recomandare

| Criteriu | Propunerea 1 (PS1 + ScriptBlock) | Propunerea 2 (CMD hibrid) |
|---|---|---|
| Lint / teste | complet | doar sectiunile extrase |
| Lansare dublu-click | nu (necesita consola admin) | da |
| ExecutionPolicy | trebuie permisa pe pcRD | ocolita prin `-ExecutionPolicy Bypass` |
| Fragilitate | mica | escapare CMD, BOM, CRLF |
| Fisiere temporare | nu | da (%TEMP%) |

**Recomandare:** propunerea 1. Daca se doreste dublu-click, se adauga un `.cmd` de o linie
(`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-WhenServerReady.ps1" %*`),
care ofera avantajul propunerii 2 fara extragere de cod.
