#Requires -Version 5.1
function Write-Log {
    <#
    .SYNOPSIS
        Scrie un mesaj de log cu timestamp si nivel de severitate.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $entry = "[$timestamp] [$Level] $Message"

    switch ($Level) {
        'WARN'  { Write-Warning $entry }
        'ERROR' { Write-Error   $entry }
        default { Write-Verbose $entry }
    }
}
