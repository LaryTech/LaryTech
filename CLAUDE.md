# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Cerințe de mediu

- **PowerShell**: 5.1 (nu sunt permise funcționalități din PS 6+)
- **OS**: Windows 10 v22H2
- **.NET Framework**: 4.8.1 (CLR 4.0 — nu .NET Core / .NET 5+)
- **Pester**: ≥ 5.0.0
- **PSScriptAnalyzer**: ≥ 1.21.0

## Comenzi esențiale

```powershell
# Instalare dependențe + lint + toate testele
.\build.ps1

# Doar lint (PSScriptAnalyzer)
.\build.ps1 -Task Lint

# Doar teste (Pester)
.\build.ps1 -Task Test

# Rulare test individual
Invoke-Pester -Path .\tests\LaryTech.Tests.ps1 -FullNameFilter 'Get-LaryTechVersion*'

# Import modul în sesiunea curentă pentru dezvoltare
Import-Module .\src\LaryTech\LaryTech.psm1 -Force

# Lint manual pe un singur fișier
Invoke-ScriptAnalyzer -Path .\src\LaryTech\Public\Get-LaryTechVersion.ps1 -Settings .\PSScriptAnalyzerSettings.psd1
```

## Arhitectura proiectului

```
LaryTech/
├── src/LaryTech/
│   ├── LaryTech.psd1        # manifest modul (versiune, dependențe, metadata)
│   ├── LaryTech.psm1        # root — dot-sources automat Public/ și Private/
│   ├── Public/              # funcții exportate (un fișier = o funcție)
│   └── Private/             # funcții interne, nevizibile consumatorilor
├── tests/                   # fișiere Pester 5, *.Tests.ps1
├── build.ps1                # orchestrare lint + teste + instalare dependențe
├── PSScriptAnalyzerSettings.psd1
└── docs/
```

### Convenția Public/Private

`LaryTech.psm1` dot-sources toate fișierele `.ps1` din `Private/` și `Public/` la import. Numele fișierului **trebuie să fie identic cu numele funcției** (ex. `Get-Foo.ps1` conține `function Get-Foo`). Funcțiile din `Public/` sunt exportate automat; cele din `Private/` nu sunt niciodată expuse.

### Adăugarea unei funcții noi

1. Creează `src/LaryTech/Public/Verb-Noun.ps1` (verbele trebuie să fie aprobate — verifică cu `Get-Verb`).
2. Adaugă un bloc `<# .SYNOPSIS ... #>` minim.
3. Adaugă un fișier `tests/Verb-Noun.Tests.ps1` cu cel puțin un `Describe`/`It`.
4. Nu modifica manual `FunctionsToExport` din `.psd1` — este gestionat de `psm1` la runtime.

## Constrângeri PowerShell 5.1

Aceste construcții **nu există** în PS 5.1 și trebuie evitate:

| Interzis (PS 6+)         | Alternativă PS 5.1                     |
|--------------------------|----------------------------------------|
| `$a ?? $b`               | `if ($null -eq $a) { $b } else { $a }` |
| `$a ??= $b`              | `if ($null -eq $a) { $a = $b }`        |
| `$a ? $b : $c`           | `if ($a) { $b } else { $c }`           |
| `&&` / `\|\|` în shell   | `; if ($LASTEXITCODE -ne 0) { ... }`   |
| `ForEach-Object -Parallel` | bucle secvențiale sau `Start-Job`    |
| `Get-Error`              | `$Error[0]`                            |

- Folosește întotdeauna `[System.IO.Path]::Combine()` sau `Join-Path` în loc de concatenare manuală a căilor.
- Evită `Invoke-Expression` (blocat de PSScriptAnalyzer).
- Credențialele se transmit exclusiv ca `[System.Management.Automation.PSCredential]`.

## Teste Pester 5

- Structura: `BeforeAll` pentru import modul, `Describe` pe funcție, `It` pe comportament specific.
- Folosește `-FullNameFilter` pentru rularea unui singur test: `Invoke-Pester -FullNameFilter 'Describe It'`.
- Rezultatele se salvează în `testResults.xml` (ignorat de git).
- `Should -Throw` se testează cu bloc de script: `{ Invoke-Cmd } | Should -Throw`.

## Lint

`PSScriptAnalyzerSettings.psd1` activează regulile de securitate critice (parole plain-text, `Invoke-Expression`, etc.). Nu dezactiva regulile de securitate fără justificare documentată.
