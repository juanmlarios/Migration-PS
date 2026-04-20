[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "EstablishAndVerifyTrust",
        "CheckCompatibility"
    )]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceCode,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = ".\Output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "M365InteractiveAuth.ps1")

function Ensure-Module {
    param([Parameter(Mandatory = $true)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' is not installed."
    }
}

function Export-Data {
    param(
        [Parameter(Mandatory = $true)][object]$Data,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Data | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
}

function Get-ConfigValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$Path
    )

    $cursor = $Config
    foreach ($segment in $Path) {
        if (-not $cursor.ContainsKey($segment)) {
            throw "Config path '$($Path -join ".")' is missing."
        }
        $cursor = $cursor[$segment]
    }

    if ([string]::IsNullOrWhiteSpace([string]$cursor)) {
        throw "Config path '$($Path -join ".")' is empty."
    }

    return $cursor
}

Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell
Assert-MigrationModuleSet

$config = Import-PowerShellDataFile -Path $ConfigPath
$sourceTenantAdminUrl = Get-ConfigValue -Config $config -Path @("Source", "TenantAdminUrl")
$targetTenantAdminUrl = Get-ConfigValue -Config $config -Path @("Target", "TenantAdminUrl")

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "$Phase-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

switch ($Phase) {
    "EstablishAndVerifyTrust" {
        Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $sourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $sourceHostUrl = Get-SPOCrossTenantHostUrl

        Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $targetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $targetHostUrl = Get-SPOCrossTenantHostUrl

        Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $sourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        Set-SPOCrossTenantRelationship -Scenario MnA -PartnerRole Target -PartnerCrossTenantHostUrl $targetHostUrl
        $sourceVerify = Verify-SPOCrossTenantRelationship -Scenario MnA -PartnerRole Target -PartnerCrossTenantHostUrl $targetHostUrl
        $sourceCompatibility = Get-SPOCrossTenantCompatibilityStatus -PartnerCrossTenantHostURL $targetHostUrl

        Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $targetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        Set-SPOCrossTenantRelationship -Scenario MnA -PartnerRole Source -PartnerCrossTenantHostUrl $sourceHostUrl
        $targetVerify = Verify-SPOCrossTenantRelationship -Scenario MnA -PartnerRole Source -PartnerCrossTenantHostUrl $sourceHostUrl
        $targetCompatibility = Get-SPOCrossTenantCompatibilityStatus -PartnerCrossTenantHostURL $sourceHostUrl

        $results = @(
            [pscustomobject]@{
                Tenant             = "Source"
                TenantAdminUrl     = $sourceTenantAdminUrl
                HostUrl            = $sourceHostUrl
                VerifyStatus       = $sourceVerify
                Compatibility      = $sourceCompatibility
            },
            [pscustomobject]@{
                Tenant             = "Target"
                TenantAdminUrl     = $targetTenantAdminUrl
                HostUrl            = $targetHostUrl
                VerifyStatus       = $targetVerify
                Compatibility      = $targetCompatibility
            }
        )

        Export-Data -Data $results -Path (Join-Path $outDir "trust-results.csv")
        $results | Format-Table -AutoSize
    }

    "CheckCompatibility" {
        Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $sourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $sourceHostUrl = Get-SPOCrossTenantHostUrl

        Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $targetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $targetHostUrl = Get-SPOCrossTenantHostUrl

        Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $sourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $sourceCompatibility = Get-SPOCrossTenantCompatibilityStatus -PartnerCrossTenantHostURL $targetHostUrl

        Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $targetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $targetCompatibility = Get-SPOCrossTenantCompatibilityStatus -PartnerCrossTenantHostURL $sourceHostUrl

        $results = @(
            [pscustomobject]@{
                Tenant             = "Source"
                TenantAdminUrl     = $sourceTenantAdminUrl
                PartnerHostUrl     = $targetHostUrl
                Compatibility      = $sourceCompatibility
            },
            [pscustomobject]@{
                Tenant             = "Target"
                TenantAdminUrl     = $targetTenantAdminUrl
                PartnerHostUrl     = $sourceHostUrl
                Compatibility      = $targetCompatibility
            }
        )

        Export-Data -Data $results -Path (Join-Path $outDir "compatibility-results.csv")
        $results | Format-Table -AutoSize
    }
}
