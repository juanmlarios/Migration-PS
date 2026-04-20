[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantLabel,

    [Parameter(Mandatory = $true)]
    [string]$TenantAdminUrl,

    [Parameter(Mandatory = $true)]
    [string]$UserCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$ExpectedPrimaryDomain,

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

Ensure-Module -Name ExchangeOnlineManagement
Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell
Ensure-Module -Name Microsoft.Graph
Ensure-Module -Name MicrosoftTeams

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "$TenantLabel-post-validation-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Connect-MgGraph -Scopes `
    "Directory.Read.All", `
    "User.Read.All", `
    "Group.Read.All", `
    "Sites.Read.All", `
    "Organization.Read.All" | Out-Null

Connect-ExchangeOnline -ShowBanner:$false
Connect-SPOService -Url $TenantAdminUrl
Connect-MicrosoftTeams | Out-Null

$users = Import-Csv -Path $UserCsvPath
$results = [System.Collections.Generic.List[object]]::new()

foreach ($user in $users) {
    $upn = if ($user.TargetUserPrincipalName) { $user.TargetUserPrincipalName } elseif ($user.UserPrincipalName) { $user.UserPrincipalName } else { $user.EmailAddress }

    $graphUser = Get-MgUser -UserId $upn -Property Id,DisplayName,UserPrincipalName,AssignedLicenses,Mail
    $mailbox = Get-EXOMailbox -Identity $upn -Properties EmailAddresses
    $stats = Get-EXOMailboxStatistics -Identity $upn

    $domainOk = $true
    if ($ExpectedPrimaryDomain) {
        $domainOk = ($mailbox.PrimarySmtpAddress -like "*@$ExpectedPrimaryDomain")
    }

    $oneDriveUrl = "https://$((($TenantAdminUrl -replace '^https://', '') -replace '-admin\.sharepoint\.com$', ''))-my.sharepoint.com/personal/$($upn.Replace('@', '_').Replace('.', '_'))"

    $oneDriveExists = $false
    try {
        $null = Get-SPOSite -Identity $oneDriveUrl
        $oneDriveExists = $true
    } catch {
        $oneDriveExists = $false
    }

    $results.Add([pscustomobject]@{
            DisplayName        = $graphUser.DisplayName
            UserPrincipalName  = $graphUser.UserPrincipalName
            Mail               = $graphUser.Mail
            LicenseCount       = ($graphUser.AssignedLicenses | Measure-Object).Count
            MailboxExists      = $true
            PrimarySmtpAddress = $mailbox.PrimarySmtpAddress
            PrimaryDomainOk    = $domainOk
            MailboxItemCount   = $stats.ItemCount
            OneDriveExists     = $oneDriveExists
        })
}

$teams = Get-Team | Select-Object GroupId, DisplayName, MailNickName, Visibility, Archived
$spoSites = Get-SPOSite -Limit All |
Where-Object {
    $_.Template -ne "RedirectSite#0" -and
    $_.Url -notlike "*-my.sharepoint.com/personal/*"
} |
Select-Object Url, Title, Template, GroupId, SharingCapability

$issues = $results | Where-Object {
    $_.LicenseCount -eq 0 -or
    -not $_.MailboxExists -or
    -not $_.PrimaryDomainOk -or
    -not $_.OneDriveExists
}

$results | Export-Csv -Path (Join-Path $outDir "user-validation.csv") -NoTypeInformation -Encoding UTF8
$teams | Export-Csv -Path (Join-Path $outDir "teams.csv") -NoTypeInformation -Encoding UTF8
$spoSites | Export-Csv -Path (Join-Path $outDir "sharepoint-sites.csv") -NoTypeInformation -Encoding UTF8
$issues | Export-Csv -Path (Join-Path $outDir "issues.csv") -NoTypeInformation -Encoding UTF8

[pscustomobject]@{
    TenantLabel       = $TenantLabel
    GeneratedAt       = (Get-Date).ToString("s")
    UsersValidated    = ($results | Measure-Object).Count
    IssuesFound       = ($issues | Measure-Object).Count
    TeamsFound        = ($teams | Measure-Object).Count
    SharePointSites   = ($spoSites | Measure-Object).Count
    OutputFolder      = (Resolve-Path $outDir).Path
} | Format-List

Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph | Out-Null
