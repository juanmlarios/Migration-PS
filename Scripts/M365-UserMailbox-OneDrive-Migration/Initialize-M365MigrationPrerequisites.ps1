[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Install,

    [Parameter(Mandatory = $false)]
    [switch]$AllowPrereleaseExchangeModule,

    [Parameter(Mandatory = $false)]
    [string]$Scope = "CurrentUser"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Import-SharePointOnlineModule {
    $loadedModule = Get-Module -Name Microsoft.Online.SharePoint.PowerShell | Select-Object -First 1
    if ($loadedModule) {
        return $loadedModule
    }

    $availableModule = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell |
    Sort-Object Version -Descending |
    Select-Object -First 1

    if (-not $availableModule) {
        return $null
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows) {
        return Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -PassThru -ErrorAction Stop
    }

    return Import-Module Microsoft.Online.SharePoint.PowerShell -PassThru -ErrorAction Stop
}

function Get-InstalledModuleVersionSafe {
    param([Parameter(Mandatory = $true)][string]$Name)

    $module = Get-Module -ListAvailable -Name $Name |
    Sort-Object Version -Descending |
    Select-Object -First 1

    if ($module) {
        return $module.Version
    }

    return $null
}

function Get-InstalledCommand {
    param([Parameter(Mandatory = $true)][string]$Command)

    return Get-Command $Command -ErrorAction SilentlyContinue
}

function Ensure-PackageManagementPrerequisite {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        if (-not $Install.IsPresent) {
            throw "NuGet package provider is missing. Re-run with -Install to add it."
        }

        Install-PackageProvider -Name NuGet -Force -Scope $Scope | Out-Null
    }

    $psGallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
    if ($psGallery -and $psGallery.InstallationPolicy -ne "Trusted") {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }
}

function Ensure-ModuleVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][version]$MinimumVersion,
        [Parameter(Mandatory = $false)][switch]$AllowPrerelease
    )

    $installedVersion = Get-InstalledModuleVersionSafe -Name $Name
    $action = "None"

    if ($installedVersion -and $installedVersion -ge $MinimumVersion) {
        return [pscustomobject]@{
            Module         = $Name
            Installed      = $true
            InstalledVersion = $installedVersion
            MinimumVersion = $MinimumVersion
            Action         = $action
            Status         = "Ready"
        }
    }

    if (-not $Install.IsPresent) {
        return [pscustomobject]@{
            Module         = $Name
            Installed      = [bool]$installedVersion
            InstalledVersion = $installedVersion
            MinimumVersion = $MinimumVersion
            Action         = "InstallOrUpdateRequired"
            Status         = "MissingOrOutdated"
        }
    }

    Ensure-PackageManagementPrerequisite

    $installParams = @{
        Name         = $Name
        Scope        = $Scope
        Force        = $true
        MinimumVersion = $MinimumVersion.ToString()
        AllowClobber = $true
    }

    if ($AllowPrerelease.IsPresent) {
        $installParams["AllowPrerelease"] = $true
    }

    Install-Module @installParams | Out-Null

    $updatedVersion = Get-InstalledModuleVersionSafe -Name $Name
    if (-not $updatedVersion -or $updatedVersion -lt $MinimumVersion) {
        throw "Module '$Name' is still below the required version after installation."
    }

    return [pscustomobject]@{
        Module         = $Name
        Installed      = $true
        InstalledVersion = $updatedVersion
        MinimumVersion = $MinimumVersion
        Action         = "InstalledOrUpdated"
        Status         = "Ready"
    }
}

function Test-PowerShellVersion {
    $currentVersion = $PSVersionTable.PSVersion
    return [pscustomobject]@{
        Component      = "PowerShell"
        InstalledVersion = $currentVersion
        MinimumVersion = [version]"7.0.0"
        Status         = if ($currentVersion.Major -ge 7) { "Ready" } else { "UpgradeRequired" }
    }
}

$results = [System.Collections.Generic.List[object]]::new()

$pwshCheck = Test-PowerShellVersion
$results.Add($pwshCheck)

if ($pwshCheck.Status -ne "Ready") {
    throw "PowerShell 7 or later is required. Current version: $($pwshCheck.InstalledVersion)"
}

$requiredModules = @(
    @{ Name = "ExchangeOnlineManagement"; MinimumVersion = [version]"3.0.0"; AllowPrerelease = $AllowPrereleaseExchangeModule.IsPresent },
    @{ Name = "Microsoft.Graph.Authentication"; MinimumVersion = [version]"2.0.0"; AllowPrerelease = $false },
    @{ Name = "Microsoft.Graph.Users"; MinimumVersion = [version]"2.0.0"; AllowPrerelease = $false },
    @{ Name = "Microsoft.Graph.Identity.DirectoryManagement"; MinimumVersion = [version]"2.0.0"; AllowPrerelease = $false },
    @{ Name = "Microsoft.Graph.Groups"; MinimumVersion = [version]"2.0.0"; AllowPrerelease = $false },
    @{ Name = "Microsoft.Graph.Identity.SignIns"; MinimumVersion = [version]"2.0.0"; AllowPrerelease = $false },
    @{ Name = "Microsoft.Online.SharePoint.PowerShell"; MinimumVersion = [version]"16.0.0"; AllowPrerelease = $false }
)

foreach ($requiredModule in $requiredModules) {
    $results.Add(
        (Ensure-ModuleVersion `
                -Name $requiredModule.Name `
                -MinimumVersion $requiredModule.MinimumVersion `
                -AllowPrerelease:$requiredModule.AllowPrerelease)
    )
}

Import-SharePointOnlineModule | Out-Null

$commandChecks = @(
    "Connect-ExchangeOnline",
    "Get-ConnectionInformation",
    "Connect-MgGraph",
    "Get-MgContext",
    "Connect-SPOService",
    "Get-SPOCrossTenantHostUrl"
)

foreach ($commandName in $commandChecks) {
    $command = Get-InstalledCommand -Command $commandName
    $results.Add([pscustomobject]@{
            Component        = "Command"
            CommandName      = $commandName
            SourceModule     = if ($command) { $command.Source } else { $null }
            Status           = if ($command) { "Ready" } else { "Missing" }
        })
}

$summary = [pscustomobject]@{
    GeneratedAt      = (Get-Date).ToString("s")
    InstallMode      = $Install.IsPresent
    Scope            = $Scope
    ResultCount      = $results.Count
    MissingOrOutdated = ($results | Where-Object { $_.Status -in @("Missing", "MissingOrOutdated", "UpgradeRequired") } | Measure-Object).Count
}

$results | Format-Table -AutoSize
$summary | Format-List
