#Requires -Version 5.1
function Get-LaryTechVersion {
    <#
    .SYNOPSIS
        Returneaza versiunea curenta a modulului LaryTech.
    .EXAMPLE
        Get-LaryTechVersion
    #>
    [CmdletBinding()]
    [OutputType([System.Version])]
    param()

    $manifest = Join-Path -Path $PSScriptRoot -ChildPath '..\LaryTech.psd1'
    $data = Import-PowerShellDataFile -Path $manifest
    return [System.Version]$data.ModuleVersion
}
