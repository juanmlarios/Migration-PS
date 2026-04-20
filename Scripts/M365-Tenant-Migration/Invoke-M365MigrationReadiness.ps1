[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantLabel,

    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$UserCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$CustomDomain,

    [Parameter(Mandatory = $false)]
    [string]$OutputRoot = ".\Output"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

Ensure-Module -Name ExchangeOnlineManagement
Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell
Ensure-Module -Name Microsoft.Graph
Ensure-Module -Name MicrosoftTeams

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "$TenantLabel-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes `
    "Directory.Read.All", `
    "User.Read.All", `
    "Group.Read.All", `
    "Domain.Read.All", `
    "Sites.Read.All", `
    "Organization.Read.All" | Out-Null

Write-Host "Connecting to Exchange Online..."
Connect-ExchangeOnline -ShowBanner:$false

Write-Host "Connecting to SharePoint Online..."
Connect-SPOService -Url $TenantAdminUrl

Write-Host "Connecting to Microsoft Teams..."
Connect-MicrosoftTeams | Out-Null

$issues = [System.Collections.Generic.List[object]]::new()

$usersToCheck =
if ($UserCsvPath) {
    Import-Csv -Path $UserCsvPath
} else {
    Get-EXOMailbox -ResultSize Unlimited | Select-Object DisplayName, UserPrincipalName, PrimarySmtpAddress
}

$mailboxReadiness = foreach ($user in $usersToCheck) {
    $upn = if ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.EmailAddress }
    $mailbox = Get-EXOMailbox -Identity $upn -Properties LitigationHoldEnabled, RetentionHoldEnabled, InPlaceHolds, ArchiveGuid, ExchangeGuid, EmailAddresses
    $stats = Get-EXOMailboxStatistics -Identity $upn

    if ($mailbox.LitigationHoldEnabled -or $mailbox.RetentionHoldEnabled -or $mailbox.InPlaceHolds) {
        $issues.Add([pscustomobject]@{
                Workload = "Exchange"
                Severity = "Blocker"
                ObjectId  = $upn
                Detail    = "Mailbox has hold-related settings and needs review before cross-tenant move."
            })
    }

    [pscustomobject]@{
        DisplayName          = $mailbox.DisplayName
        UserPrincipalName    = $mailbox.UserPrincipalName
        PrimarySmtpAddress   = $mailbox.PrimarySmtpAddress
        ExchangeGuid         = $mailbox.ExchangeGuid
        ArchiveGuid          = $mailbox.ArchiveGuid
        LitigationHold       = $mailbox.LitigationHoldEnabled
        RetentionHold        = $mailbox.RetentionHoldEnabled
        InPlaceHolds         = ($mailbox.InPlaceHolds -join ";")
        TotalItemSize        = $stats.TotalItemSize
        ItemCount            = $stats.ItemCount
    }
}

$oneDrives = Get-SPOSite -IncludePersonalSite $true -Limit All |
Where-Object { $_.Url -like "*-my.sharepoint.com/personal/*" }

$oneDriveReadiness = foreach ($site in $oneDrives) {
    if ($site.StorageUsageCurrent -gt 5242880) {
        $issues.Add([pscustomobject]@{
                Workload = "OneDrive"
                Severity = "Blocker"
                ObjectId  = $site.Url
                Detail    = "OneDrive exceeds 5 TB."
            })
    }

    [pscustomobject]@{
        Url                 = $site.Url
        Owner               = $site.Owner
        StorageMB           = $site.StorageUsageCurrent
        Template            = $site.Template
        SharingCapability   = $site.SharingCapability
        LockState           = $site.LockState
    }
}

$sharePointSites = Get-SPOSite -Limit All |
Where-Object {
    $_.Template -ne "RedirectSite#0" -and
    $_.Url -notlike "*-my.sharepoint.com/personal/*"
}

$sharePointReadiness = foreach ($site in $sharePointSites) {
    if ($site.StorageUsageCurrent -gt 5242880) {
        $issues.Add([pscustomobject]@{
                Workload = "SharePoint"
                Severity = "Blocker"
                ObjectId  = $site.Url
                Detail    = "Site exceeds 5 TB."
            })
    }

    if ($site.LockState -and $site.LockState -ne "Unlock") {
        $issues.Add([pscustomobject]@{
                Workload = "SharePoint"
                Severity = "Blocker"
                ObjectId  = $site.Url
                Detail    = "Site is not read/write."
            })
    }

    [pscustomobject]@{
        Url               = $site.Url
        Title             = $site.Title
        Template          = $site.Template
        GroupId           = $site.GroupId
        StorageMB         = $site.StorageUsageCurrent
        LockState         = $site.LockState
        SharingCapability = $site.SharingCapability
    }
}

$teams = Get-Team
$teamInventory = foreach ($team in $teams) {
    $channels = Get-TeamChannel -GroupId $team.GroupId
    $owners = Get-TeamUser -GroupId $team.GroupId -Role Owner
    $members = Get-TeamUser -GroupId $team.GroupId -Role Member

    [pscustomobject]@{
        GroupId       = $team.GroupId
        DisplayName   = $team.DisplayName
        MailNickName  = $team.MailNickName
        Visibility    = $team.Visibility
        Archived      = $team.Archived
        ChannelCount  = ($channels | Measure-Object).Count
        OwnerCount    = ($owners | Measure-Object).Count
        MemberCount   = ($members | Measure-Object).Count
    }
}

$domains = Get-MgDomain -All | Select-Object Id, IsDefault, IsVerified, AuthenticationType

if ($CustomDomain) {
    $domainHits = Get-EXORecipient -ResultSize Unlimited |
    Where-Object {
        $_.PrimarySmtpAddress -like "*@$CustomDomain" -or
        ($_.EmailAddresses -join ";") -like "*$CustomDomain*"
    } |
    Select-Object DisplayName, RecipientTypeDetails, PrimarySmtpAddress, EmailAddresses

    if (-not $domainHits) {
        $issues.Add([pscustomobject]@{
                Workload = "Domain"
                Severity = "Info"
                ObjectId  = $CustomDomain
                Detail    = "No Exchange recipients found using the custom domain."
            })
    }

    Export-Data -Data $domainHits -Path (Join-Path $outDir "custom-domain-exchange-hits.csv")
}

Export-Data -Data $mailboxReadiness -Path (Join-Path $outDir "mailbox-readiness.csv")
Export-Data -Data $oneDriveReadiness -Path (Join-Path $outDir "onedrive-readiness.csv")
Export-Data -Data $sharePointReadiness -Path (Join-Path $outDir "sharepoint-readiness.csv")
Export-Data -Data $teamInventory -Path (Join-Path $outDir "teams-inventory.csv")
Export-Data -Data $domains -Path (Join-Path $outDir "domains.csv")
Export-Data -Data $issues -Path (Join-Path $outDir "issues.csv")

$summary = [pscustomobject]@{
    TenantLabel        = $TenantLabel
    GeneratedAt        = (Get-Date).ToString("s")
    MailboxesChecked   = ($mailboxReadiness | Measure-Object).Count
    OneDrivesFound     = ($oneDriveReadiness | Measure-Object).Count
    SharePointSites    = ($sharePointReadiness | Measure-Object).Count
    TeamsFound         = ($teamInventory | Measure-Object).Count
    IssuesFound        = ($issues | Measure-Object).Count
    OutputFolder       = (Resolve-Path $outDir).Path
}

$summary | Format-List
$summary | ConvertTo-Json | Set-Content -Path (Join-Path $outDir "summary.json") -Encoding UTF8

Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph | Out-Null
