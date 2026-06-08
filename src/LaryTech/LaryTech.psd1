@{
    RootModule             = 'LaryTech.psm1'
    ModuleVersion          = '1.0.0'
    GUID                   = 'a1b2c3d4-e5f6-7890-abcd-ef1234567890'
    Author                 = 'LaryTech'
    CompanyName            = 'LaryTech'
    Copyright              = '(c) 2026 LaryTech. All rights reserved.'
    Description            = 'Modul PowerShell LaryTech - utilitare si automatizari Windows'
    PowerShellVersion      = '5.1'
    DotNetFrameworkVersion = '4.8'
    CLRVersion             = '4.0'
    ProcessorArchitecture  = 'None'

    FunctionsToExport      = @()   # populat automat la build din /Public
    CmdletsToExport        = @()
    VariablesToExport      = @()
    AliasesToExport        = @()

    PrivateData            = @{
        PSData = @{
            Tags         = @('Windows', 'Automation', 'Utilities')
            ReleaseNotes = 'Versiune initiala'
        }
    }
}
