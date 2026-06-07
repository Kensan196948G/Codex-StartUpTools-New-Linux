Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "ConfigSchema.ps1")
. (Join-Path $PSScriptRoot "ConfigLoader.ps1")
. (Join-Path $PSScriptRoot "RecentProjects.ps1")

Export-ModuleMember -Function "*"
