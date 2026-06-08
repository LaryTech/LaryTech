#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

$privatePath = Join-Path -Path $PSScriptRoot -ChildPath 'Private'
$publicPath  = Join-Path -Path $PSScriptRoot -ChildPath 'Public'

foreach ($file in (Get-ChildItem -Path $privatePath -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    . $file.FullName
}

$exportedFunctions = @()
foreach ($file in (Get-ChildItem -Path $publicPath -Filter '*.ps1' -ErrorAction SilentlyContinue)) {
    . $file.FullName
    $exportedFunctions += $file.BaseName
}

Export-ModuleMember -Function $exportedFunctions
