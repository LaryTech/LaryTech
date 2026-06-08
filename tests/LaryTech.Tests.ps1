#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulePath = Join-Path -Path $PSScriptRoot -ChildPath '..\src\LaryTech\LaryTech.psm1'
    Import-Module -Name $modulePath -Force
}

Describe 'Get-LaryTechVersion' {
    It 'Returneaza un obiect de tip System.Version' {
        $result = Get-LaryTechVersion
        $result | Should -BeOfType [System.Version]
    }

    It 'Versiunea are major >= 1' {
        $result = Get-LaryTechVersion
        $result.Major | Should -BeGreaterOrEqual 1
    }
}

Describe 'LaryTech modul' {
    It 'Modulul se importa fara erori' {
        { Import-Module -Name (Join-Path $PSScriptRoot '..\src\LaryTech\LaryTech.psm1') -Force } |
            Should -Not -Throw
    }

    It 'Exporta cel putin o functie publica' {
        $commands = Get-Command -Module LaryTech
        $commands.Count | Should -BeGreaterThan 0
    }
}
