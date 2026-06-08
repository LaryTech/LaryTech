#Requires -Version 5.1
<#
.SYNOPSIS
    Script principal de build pentru modulul LaryTech.
.PARAMETER Task
    Taskul de executat: Lint, Test, All (implicit)
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Task Lint
    .\build.ps1 -Task Test
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('Lint', 'Test', 'All')]
    [string]$Task = 'All'
)

$ErrorActionPreference = 'Stop'
$rootPath   = $PSScriptRoot
$srcPath    = Join-Path $rootPath 'src\LaryTech'
$testsPath  = Join-Path $rootPath 'tests'
$settingsFile = Join-Path $rootPath 'PSScriptAnalyzerSettings.psd1'

function Install-BuildDependencies {
    $modules = @(
        @{ Name = 'PSScriptAnalyzer'; MinVersion = '1.21.0' },
        @{ Name = 'Pester';           MinVersion = '5.0.0'  }
    )
    foreach ($mod in $modules) {
        if (-not (Get-Module -ListAvailable -Name $mod.Name |
                  Where-Object { $_.Version -ge [version]$mod.MinVersion })) {
            Write-Host "Instalare $($mod.Name)..." -ForegroundColor Cyan
            Install-Module -Name $mod.Name -MinimumVersion $mod.MinVersion `
                           -Scope CurrentUser -Force -SkipPublisherCheck
        }
    }
}

function Invoke-Lint {
    Write-Host "`n=== PSScriptAnalyzer ===" -ForegroundColor Cyan
    $results = Invoke-ScriptAnalyzer -Path $srcPath -Recurse `
                                     -Settings $settingsFile
    if ($results) {
        $results | Format-Table -AutoSize
        throw "PSScriptAnalyzer a gasit $($results.Count) probleme."
    }
    Write-Host "Lint: OK" -ForegroundColor Green
}

function Invoke-Tests {
    Write-Host "`n=== Pester ===" -ForegroundColor Cyan
    $config = New-PesterConfiguration
    $config.Run.Path           = $testsPath
    $config.Output.Verbosity   = 'Detailed'
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputPath = Join-Path $rootPath 'testResults.xml'

    $result = Invoke-Pester -Configuration $config
    if ($result.FailedCount -gt 0) {
        throw "Pester: $($result.FailedCount) test(e) esuate."
    }
    Write-Host "Teste: OK ($($result.PassedCount) trecute)" -ForegroundColor Green
}

Install-BuildDependencies

switch ($Task) {
    'Lint' { Invoke-Lint }
    'Test' { Invoke-Tests }
    'All'  { Invoke-Lint; Invoke-Tests }
}

Write-Host "`nBuild finalizat cu succes." -ForegroundColor Green
