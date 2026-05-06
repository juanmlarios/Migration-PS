[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceTenantAdminUrl,

    [Parameter(Mandatory = $true)]
    [string]$TargetTenantAdminUrl,

    [Parameter(Mandatory = $true)]
    [string]$MigrationCsvPath,

    [Parameter(Mandatory = $true)]
    [string]$CustomDomain,

    [Parameter(Mandatory = $false)]
    [string]$SourceTenantId,

    [Parameter(Mandatory = $false)]
    [string]$TargetTenantId,

    [Parameter(Mandatory = $false)]
    [string]$SourceAdminUpn,

    [Parameter(Mandatory = $false)]
    [string]$TargetAdminUpn,

    [Parameter(Mandatory = $false)]
    [switch]$UseDeviceCode,

    [Parameter(Mandatory = $false)]
    [switch]$DisableExchangeWAM, ##this should have changed 

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

function Get-UserLocalPart {
    param([Parameter(Mandatory = $true)][string]$Address)

    return ($Address -split "@")[0]
}

function Get-PersonalSiteMatch {
    param(
        [Parameter(Mandatory = $true)][object[]]$Sites,
        [Parameter(Mandatory = $true)][string]$UserPrincipalName
    )

    $fragment = ($UserPrincipalName.ToLowerInvariant() -replace "@", "_" -replace "\.", "_")
    $site = $Sites | Where-Object {
        $_.Owner -eq $UserPrincipalName -or $_.Url.ToLowerInvariant().Contains("/personal/$fragment")
    } | Select-Object -First 1

    return $site
}

function Disconnect-ReadinessSessions {
    if (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}

function Enter-PhaseBoundary {
    param(
        [Parameter(Mandatory = $true)][string]$CompletedPhase,
        [Parameter(Mandatory = $true)][string]$NextPhase
    )

    Write-Host ""
    Write-Host ("Completed {0} checks." -f $CompletedPhase) -ForegroundColor Cyan
    Write-Host ("Disconnected Microsoft Graph and Exchange Online sessions for {0}." -f $CompletedPhase) -ForegroundColor Cyan
    Write-Host ("Next step: sign in to the {0} tenant when prompted." -f $NextPhase) -ForegroundColor Cyan
    Read-Host ("Press Enter to continue to the {0} tenant" -f $NextPhase) | Out-Null
    Write-Host ""
}

Ensure-Module -Name ExchangeOnlineManagement
Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell
Ensure-Module -Name Microsoft.Graph
Assert-MigrationModuleSet

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "mailbox-onedrive-readiness-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$migrationRows = Import-Csv -Path $MigrationCsvPath
if (-not $migrationRows) {
    throw "Migration CSV '$MigrationCsvPath' is empty."
}

$issues = [System.Collections.Generic.List[object]]::new()

Write-Host "Connecting to source Microsoft Graph..."
Connect-GraphInteractive -TenantLabel "Source" -Scopes @("Directory.Read.All", "User.Read.All", "Group.Read.All", "Domain.Read.All", "Organization.Read.All") -ExpectedTenantId $SourceTenantId -UseDeviceCode:$UseDeviceCode | Out-Null

Write-Host "Connecting to source Exchange Online..."
Connect-ExchangeInteractive -TenantLabel "Source" -ExpectedTenantId $SourceTenantId -AdminUpn $SourceAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null

Write-Host "Connecting to source SharePoint Online..."
Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $SourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null

$sourceOneDrives = Get-SPOSite -IncludePersonalSite $true -Limit All |
Where-Object { $_.Url -like "*-my.sharepoint.com/personal/*" }

$sourceMailboxBaseline = foreach ($row in $migrationRows) {
    $mailbox = Get-EXOMailbox -Identity $row.SourceUserPrincipalName -Properties LitigationHoldEnabled, RetentionHoldEnabled, InPlaceHolds, ArchiveGuid, ExchangeGuid, EmailAddresses, LegacyExchangeDN, DisplayName, Alias
    $stats = Get-EXOMailboxStatistics -Identity $row.SourceUserPrincipalName
    $sourceUser = $null

    try {
        $sourceUser = Get-MgUser -UserId $row.SourceUserPrincipalName -Property GivenName, Surname, DisplayName, UserPrincipalName
    }
    catch {
        $sourceUser = $null
    }

    $sourceOnMicrosoftAddress =
    ($mailbox.EmailAddresses |
    Where-Object { $_ -cmatch '^smtp:.*\.onmicrosoft\.com$' } |
    ForEach-Object { $_.Substring(5) } |
    Select-Object -First 1)

    $x500Addresses =
    ($mailbox.EmailAddresses |
    Where-Object { $_ -cmatch '^x500:' })

    if (-not $sourceOnMicrosoftAddress) {
        $issues.Add([pscustomobject]@{
                Workload = "Exchange"
                Severity = "Blocker"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "No source onmicrosoft routing address was found."
            })
    }

    if ($mailbox.LitigationHoldEnabled -or $mailbox.RetentionHoldEnabled -or $mailbox.InPlaceHolds) {
        $issues.Add([pscustomobject]@{
                Workload = "Exchange"
                Severity = "Blocker"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "Mailbox has hold-related settings and is not ready for cross-tenant migration."
            })
    }

    $preCutoverPrimary = if ($row.PreCutoverPrimarySmtpAddress) { $row.PreCutoverPrimarySmtpAddress } else { $row.TargetUserPrincipalName }
    $finalPrimary = if ($row.FinalPrimarySmtpAddress) { $row.FinalPrimarySmtpAddress } else { $row.SourcePrimarySmtpAddress }
    $finalUpn = if ($row.FinalUserPrincipalName) { $row.FinalUserPrincipalName } else { $finalPrimary }

    [pscustomobject]@{
        SourceUserPrincipalName      = $row.SourceUserPrincipalName
        SourcePrimarySmtpAddress     = $row.SourcePrimarySmtpAddress
        SourceOnMicrosoftAddress     = $sourceOnMicrosoftAddress
        SourceAlias                  = $mailbox.Alias
        SourceDisplayName            = $mailbox.DisplayName
        GivenName                    = if ($row.GivenName) { $row.GivenName } elseif ($sourceUser) { $sourceUser.GivenName } else { $null }
        Surname                      = if ($row.Surname) { $row.Surname } elseif ($sourceUser) { $sourceUser.Surname } else { $null }
        TargetUserPrincipalName      = $row.TargetUserPrincipalName
        TargetAlias                  = $row.TargetAlias
        TargetDisplayName            = $row.TargetDisplayName
        UsageLocation                = $row.UsageLocation
        PreCutoverPrimarySmtpAddress = $preCutoverPrimary
        FinalPrimarySmtpAddress      = $finalPrimary
        FinalUserPrincipalName       = $finalUpn
        ExchangeGuid                 = $mailbox.ExchangeGuid
        ArchiveGuid                  = $mailbox.ArchiveGuid
        LegacyExchangeDn             = $mailbox.LegacyExchangeDN
        X500Addresses                = ($x500Addresses -join "|")
        TotalItemSize                = $stats.TotalItemSize
        ItemCount                    = $stats.ItemCount
        LitigationHoldEnabled        = $mailbox.LitigationHoldEnabled
        RetentionHoldEnabled         = $mailbox.RetentionHoldEnabled
        InPlaceHolds                 = ($mailbox.InPlaceHolds -join ";")
    }
}

$sourceOneDriveBaseline = foreach ($row in $migrationRows) {
    $site = Get-PersonalSiteMatch -Sites $sourceOneDrives -UserPrincipalName $row.SourceUserPrincipalName

    if (-not $site) {
        $issues.Add([pscustomobject]@{
                Workload = "OneDrive"
                Severity = "Warning"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "No source OneDrive personal site was found."
            })
    }
    elseif ($site.StorageUsageCurrent -gt 5242880) {
        $issues.Add([pscustomobject]@{
                Workload = "OneDrive"
                Severity = "Blocker"
                ObjectId = $site.Url
                Detail   = "OneDrive exceeds 5 TB."
            })
    }

    [pscustomobject]@{
        SourceUserPrincipalName = $row.SourceUserPrincipalName
        OneDriveFound           = [bool]$site
        Url                     = if ($site) { $site.Url } else { $null }
        Owner                   = if ($site) { $site.Owner } else { $null }
        StorageMB               = if ($site) { $site.StorageUsageCurrent } else { $null }
        LockState               = if ($site) { $site.LockState } else { $null }
        SharingCapability       = if ($site) { $site.SharingCapability } else { $null }
    }
}

$sourceDomainDependencies = Get-EXORecipient -ResultSize Unlimited |
Where-Object {
    $primarySmtpAddress = if ($_.PSObject.Properties.Match("PrimarySmtpAddress").Count -gt 0) { [string]$_.PrimarySmtpAddress } else { $null }
    $windowsEmailAddress = if ($_.PSObject.Properties.Match("WindowsEmailAddress").Count -gt 0) { [string]$_.WindowsEmailAddress } else { $null }
    $emailAddresses = if ($_.PSObject.Properties.Match("EmailAddresses").Count -gt 0) { @($_.EmailAddresses) } else { @() }

    $primarySmtpAddress -like "*@$CustomDomain" -or
    $windowsEmailAddress -like "*@$CustomDomain" -or
    ($emailAddresses -join ";") -like "*$CustomDomain*"
} |
Select-Object DisplayName, Alias, RecipientTypeDetails, PrimarySmtpAddress, WindowsEmailAddress, EmailAddresses

Disconnect-ReadinessSessions
Enter-PhaseBoundary -CompletedPhase "source tenant" -NextPhase "target"

Write-Host "Connecting to target Microsoft Graph..."
Connect-GraphInteractive -TenantLabel "Target" -Scopes @("Directory.Read.All", "User.Read.All", "Organization.Read.All") -ExpectedTenantId $TargetTenantId -UseDeviceCode:$UseDeviceCode | Out-Null

Write-Host "Connecting to target Exchange Online..."
Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $TargetTenantId -AdminUpn $TargetAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null

Write-Host "Connecting to target SharePoint Online..."
Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $TargetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null

$targetOneDrives = Get-SPOSite -IncludePersonalSite $true -Limit All |
Where-Object { $_.Url -like "*-my.sharepoint.com/personal/*" }

$targetReadiness = foreach ($row in $sourceMailboxBaseline) {
    $graphUser = $null
    try {
        $graphUser = Get-MgUser -UserId $row.TargetUserPrincipalName -Property Id, DisplayName, UserPrincipalName, AssignedLicenses, Mail
    }
    catch {
        $graphUser = $null
    }

    $recipient = $null
    try {
        $recipient = Get-EXORecipient -Identity $row.TargetUserPrincipalName -ErrorAction Stop
    }
    catch {
        $recipient = $null
    }

    $targetOneDrive = Get-PersonalSiteMatch -Sites $targetOneDrives -UserPrincipalName $row.TargetUserPrincipalName

    if ($recipient -and $recipient.RecipientTypeDetails -eq "UserMailbox") {
        $issues.Add([pscustomobject]@{
                Workload = "Target"
                Severity = "Blocker"
                ObjectId = $row.TargetUserPrincipalName
                Detail   = "Target object already has a mailbox. Cleanup is required before migration."
            })
    }

    if ($targetOneDrive) {
        $issues.Add([pscustomobject]@{
                Workload = "Target"
                Severity = "Warning"
                ObjectId = $row.TargetUserPrincipalName
                Detail   = "Target OneDrive already exists. Cross-tenant OneDrive migration should use a clean target."
            })
    }

    [pscustomobject]@{
        TargetUserPrincipalName = $row.TargetUserPrincipalName
        GraphUserExists         = [bool]$graphUser
        RecipientExists         = [bool]$recipient
        RecipientTypeDetails    = if ($recipient) { $recipient.RecipientTypeDetails } else { $null }
        ExistingPrimarySmtp     = if ($recipient) { $recipient.PrimarySmtpAddress } else { $null }
        ExistingOneDrive        = [bool]$targetOneDrive
    }
}

Disconnect-ReadinessSessions

Export-Data -Data $sourceMailboxBaseline -Path (Join-Path $outDir "source-mailbox-baseline.csv")
Export-Data -Data $sourceOneDriveBaseline -Path (Join-Path $outDir "source-onedrive-baseline.csv")
Export-Data -Data $sourceDomainDependencies -Path (Join-Path $outDir "source-custom-domain-dependencies.csv")
Export-Data -Data $targetReadiness -Path (Join-Path $outDir "target-readiness.csv")
Export-Data -Data $sourceMailboxBaseline -Path (Join-Path $outDir "migration-prep-input.csv")
Export-Data -Data $issues -Path (Join-Path $outDir "issues.csv")

[pscustomobject]@{
    GeneratedAt               = (Get-Date).ToString("s")
    MigrationUserCount        = ($sourceMailboxBaseline | Measure-Object).Count
    SourceCustomDomainObjects = ($sourceDomainDependencies | Measure-Object).Count
    IssuesFound               = ($issues | Measure-Object).Count
    OutputFolder              = (Resolve-Path $outDir).Path
} | Format-List
