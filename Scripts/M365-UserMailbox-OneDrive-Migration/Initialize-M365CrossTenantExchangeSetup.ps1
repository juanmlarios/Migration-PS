[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "PrepareTargetExchange",
        "PrepareSourceExchange",
        "ValidateTargetEndpoint",
        "AddUsersToSourceScopeGroup"
    )]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$MigrationCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$TestMailbox,

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

function Enable-OrgCustomizationIfNeeded {
    $orgConfig = Get-OrganizationConfig | Select-Object IsDehydrated
    if ($orgConfig.IsDehydrated) {
        Enable-OrganizationCustomization
    }
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

Ensure-Module -Name ExchangeOnlineManagement
Assert-MigrationModuleSet

$config = Import-PowerShellDataFile -Path $ConfigPath
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "$Phase-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$sourceTenantId = Get-ConfigValue -Config $config -Path @("Source", "TenantId")
$sourceOnMicrosoftDomain = Get-ConfigValue -Config $config -Path @("Source", "OnMicrosoftDomain")
$sourceAdminUpn = if ($config["Source"].ContainsKey("AdminUserPrincipalName")) { $config["Source"]["AdminUserPrincipalName"] } else { $null }
$sourceScopeGroupName = Get-ConfigValue -Config $config -Path @("Source", "MigrationScopeGroupName")
$sourceOrgRelName = Get-ConfigValue -Config $config -Path @("Source", "OrganizationRelationshipName")
$targetTenantId = Get-ConfigValue -Config $config -Path @("Target", "TenantId")
$targetOnMicrosoftDomain = Get-ConfigValue -Config $config -Path @("Target", "OnMicrosoftDomain")
$targetAdminUpn = if ($config["Target"].ContainsKey("AdminUserPrincipalName")) { $config["Target"]["AdminUserPrincipalName"] } else { $null }
$targetEndpointName = Get-ConfigValue -Config $config -Path @("Target", "MigrationEndpointName")
$targetOrgRelName = Get-ConfigValue -Config $config -Path @("Target", "OrganizationRelationshipName")
$appId = Get-ConfigValue -Config $config -Path @("Exchange", "AppId")
$appSecret = Get-ConfigValue -Config $config -Path @("Exchange", "AppSecretPlainText")
$consentRedirectUri = Get-ConfigValue -Config $config -Path @("Exchange", "ConsentRedirectUri")

$consentUrl = "https://login.microsoftonline.com/{0}/adminconsent?client_id={1}&redirect_uri={2}" -f `
    $sourceOnMicrosoftDomain,
    $appId,
    [System.Uri]::EscapeDataString($consentRedirectUri)

switch ($Phase) {
    "PrepareTargetExchange" {
        Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $targetTenantId -AdminUpn $targetAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
        Enable-OrgCustomizationIfNeeded

        $existingEndpoint = Get-MigrationEndpoint -Identity $targetEndpointName -ErrorAction SilentlyContinue
        if (-not $existingEndpoint) {
            $credential = New-Object System.Management.Automation.PSCredential(
                $appId,
                (ConvertTo-SecureString -String $appSecret -AsPlainText -Force)
            )

            New-MigrationEndpoint `
                -RemoteServer "outlook.office.com" `
                -RemoteTenant $sourceOnMicrosoftDomain `
                -Credentials $credential `
                -ExchangeRemoteMove:$true `
                -Name $targetEndpointName `
                -ApplicationId $appId | Out-Null
        }

        $existingOrgRel = Get-OrganizationRelationship | Where-Object { $_.DomainNames -like $sourceTenantId } | Select-Object -First 1
        if ($existingOrgRel) {
            Set-OrganizationRelationship `
                -Identity $existingOrgRel.Name `
                -Enabled:$true `
                -MailboxMoveEnabled:$true `
                -MailboxMoveCapability Inbound | Out-Null
        } else {
            New-OrganizationRelationship `
                -Name $targetOrgRelName `
                -Enabled:$true `
                -MailboxMoveEnabled:$true `
                -MailboxMoveCapability Inbound `
                -DomainNames $sourceTenantId | Out-Null
        }

        $result = [pscustomobject]@{
            Phase                = $Phase
            MigrationEndpoint    = $targetEndpointName
            SourceTenantDomain   = $sourceOnMicrosoftDomain
            SourceTenantId       = $sourceTenantId
            ConsentUrlForSource  = $consentUrl
            OutputFolder         = (Resolve-Path $outDir).Path
        }

        Export-Data -Data @($result) -Path (Join-Path $outDir "target-exchange-setup.csv")
        $result | Format-List

        Disconnect-ExchangeOnline -Confirm:$false
    }

    "PrepareSourceExchange" {
        Connect-ExchangeInteractive -TenantLabel "Source" -ExpectedTenantId $sourceTenantId -AdminUpn $sourceAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
        Enable-OrgCustomizationIfNeeded

        $scopeGroup = Get-DistributionGroup -Identity $sourceScopeGroupName -ErrorAction SilentlyContinue
        if (-not $scopeGroup) {
            $scopeGroup = New-DistributionGroup -Type Security -Name $sourceScopeGroupName
        }

        $existingOrgRel = Get-OrganizationRelationship | Where-Object { $_.DomainNames -like $targetTenantId } | Select-Object -First 1
        if ($existingOrgRel) {
            Set-OrganizationRelationship `
                -Identity $existingOrgRel.Name `
                -Enabled:$true `
                -MailboxMoveEnabled:$true `
                -MailboxMoveCapability RemoteOutbound `
                -OAuthApplicationId $appId `
                -MailboxMovePublishedScopes $sourceScopeGroupName | Out-Null
        } else {
            New-OrganizationRelationship `
                -Name $sourceOrgRelName `
                -Enabled:$true `
                -MailboxMoveEnabled:$true `
                -MailboxMoveCapability RemoteOutbound `
                -DomainNames $targetTenantId `
                -OAuthApplicationId $appId `
                -MailboxMovePublishedScopes $sourceScopeGroupName | Out-Null
        }

        $result = [pscustomobject]@{
            Phase                = $Phase
            ScopeGroupName       = $sourceScopeGroupName
            TargetTenantId       = $targetTenantId
            ApplicationId        = $appId
            OutputFolder         = (Resolve-Path $outDir).Path
        }

        Export-Data -Data @($result) -Path (Join-Path $outDir "source-exchange-setup.csv")
        $result | Format-List

        Disconnect-ExchangeOnline -Confirm:$false
    }

    "AddUsersToSourceScopeGroup" {
        if (-not $MigrationCsvPath) {
            throw "MigrationCsvPath is required for AddUsersToSourceScopeGroup."
        }

        Connect-ExchangeInteractive -TenantLabel "Source" -ExpectedTenantId $sourceTenantId -AdminUpn $sourceAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
        $rows = Import-Csv -Path $MigrationCsvPath
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $rows) {
            $memberIdentity = if ($row.SourceUserPrincipalName) { $row.SourceUserPrincipalName } else { $row.UserPrincipalName }
            Add-DistributionGroupMember -Identity $sourceScopeGroupName -Member $memberIdentity -BypassSecurityGroupManagerCheck -ErrorAction SilentlyContinue
            $results.Add([pscustomobject]@{
                ScopeGroupName         = $sourceScopeGroupName
                SourceUserPrincipalName = $memberIdentity
                Status                 = "Processed"
            })
        }

        Export-Data -Data $results -Path (Join-Path $outDir "scope-group-members.csv")
        Disconnect-ExchangeOnline -Confirm:$false
    }

    "ValidateTargetEndpoint" {
        if (-not $TestMailbox) {
            throw "TestMailbox is required for ValidateTargetEndpoint."
        }

        Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $targetTenantId -AdminUpn $targetAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
        $validation = Test-MigrationServerAvailability -Endpoint $targetEndpointName -TestMailbox $TestMailbox

        $validationResult = $validation | Select-Object Result, SupportsCutover, ErrorDetail, Identity
        Export-Data -Data $validationResult -Path (Join-Path $outDir "target-endpoint-validation.csv")

        $validation | Format-List *
        Disconnect-ExchangeOnline -Confirm:$false
    }
}
