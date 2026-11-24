#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:LauncherPath = Join-Path -Path $PSScriptRoot -ChildPath '..\tools\Start-WhenServerReady\Start-WhenServerReady.ps1'
    # dot-sourcing: blocul principal este protejat de garda InvocationName -ne '.'
    . $script:LauncherPath
    $script:WorkerText = "#Requires -Version 5.1`r`n" + $WorkerCode.ToString().Trim() + "`r`n"
    $script:WorkerPath = Join-Path -Path $TestDrive -ChildPath 'check-StatusServer.ps1'
    Set-Content -LiteralPath $script:WorkerPath -Value $script:WorkerText -Encoding ASCII
    . $script:WorkerPath
}

Describe 'Start-WhenServerReady - fisiere' {
    It 'Launcher-ul nu contine caractere non-ASCII' {
        $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $script:LauncherPath).Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'Worker-ul generat se parseaza fara erori' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($script:WorkerText, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }

    It 'Worker-ul generat incepe cu #Requires -Version 5.1' {
        $script:WorkerText | Should -Match '^#Requires -Version 5\.1'
    }
}

Describe 'Measure-MatchingLine' {
    It 'Numara liniile care contin textul, fara diferenta de majuscule' {
        Measure-MatchingLine -Line @('ESSERNET drv1', 'driver essernet 2', 'altceva') -Match 'essernet' |
            Should -Be 2
    }

    It 'Returneaza 0 pentru lista goala' {
        Measure-MatchingLine -Line @() -Match 'essernet' | Should -Be 0
    }

    It 'Ignora elementele null' {
        Measure-MatchingLine -Line @($null, 'essernet') -Match 'essernet' | Should -Be 1
    }
}

Describe 'Show-Warning' {
    It 'Nu afiseaza nimic cand conditia este falsa' {
        Show-Warning -Message 'test' -ShowSec 1 -Condition { $false } | Should -BeNullOrEmpty
    }
}

Describe 'Remove-LtFile' {
    It 'Nu sterge fisierul cu -WhatIf' {
        $f = Join-Path -Path $TestDrive -ChildPath 'drv.txt'
        Set-Content -LiteralPath $f -Value 'x'
        Remove-LtFile -Directory $TestDrive -Name @('drv.txt') -WhatIf
        Test-Path -LiteralPath $f | Should -BeTrue
    }

    It 'Sterge fisierul relativ la director' {
        $f = Join-Path -Path $TestDrive -ChildPath 'fisier.xml'
        Set-Content -LiteralPath $f -Value 'x'
        Remove-LtFile -Directory $TestDrive -Name @('fisier.xml') -Confirm:$false
        Test-Path -LiteralPath $f | Should -BeFalse
    }
}
