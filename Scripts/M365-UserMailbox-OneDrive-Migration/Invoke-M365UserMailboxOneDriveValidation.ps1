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

    [Parameter(Mandatory = $true)]
    [string]$TargetDeliveryDomain,

    [Parameter(Mandatory = $false)]
    [string]$SourceCrossTenantHostUrl,

    [Parameter(Mandatory = $false)]
    [string]$TargetCrossTenantHostUrl,

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

Ensure-Module -Name ExchangeOnlineManagement
Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell
Ensure-Module -Name Microsoft.Graph
Assert-MigrationModuleSet

$migrationRows = Import-Csv -Path $MigrationCsvPath
if (-not $migrationRows) {
    throw "Migration CSV '$MigrationCsvPath' is empty."
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "mailbox-onedrive-validation-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$issues = [System.Collections.Generic.List[object]]::new()

Connect-GraphInteractive -TenantLabel "Target" -Scopes @("Directory.Read.All", "User.Read.All", "Organization.Read.All") -ExpectedTenantId $TargetTenantId -UseDeviceCode:$UseDeviceCode | Out-Null
Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $TargetTenantId -AdminUpn $TargetAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
Connect-SPOInteractive -TenantLabel "Target" -AdminUrl $TargetTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null

$targetOneDrives = Get-SPOSite -IncludePersonalSite $true -Limit All |
Where-Object { $_.Url -like "*-my.sharepoint.com/personal/*" }

$targetResults = foreach ($row in $migrationRows) {
    $lookupIdentities = @($row.TargetUserPrincipalName)
    if ($row.FinalUserPrincipalName -and $row.FinalUserPrincipalName -ne $row.TargetUserPrincipalName) {
        $lookupIdentities += $row.FinalUserPrincipalName
    }
    if ($row.FinalPrimarySmtpAddress -and $row.FinalPrimarySmtpAddress -notin $lookupIdentities) {
        $lookupIdentities += $row.FinalPrimarySmtpAddress
    }

    $graphUser = $null
    foreach ($identity in $lookupIdentities) {
        try {
            $graphUser = Get-MgUser -UserId $identity -Property Id, DisplayName, UserPrincipalName, AssignedLicenses, Mail
            if ($graphUser) {
                break
            }
        } catch {
            $graphUser = $null
        }
    }

    $recipient = $null
    foreach ($identity in $lookupIdentities) {
        try {
            $recipient = Get-EXORecipient -Identity $identity -ErrorAction Stop
            if ($recipient) {
                break
            }
        } catch {
            $recipient = $null
        }
    }

    $mailbox = $null
    $mailboxStats = $null

    if ($recipient -and $recipient.RecipientTypeDetails -eq "UserMailbox") {
        $mailbox = Get-EXOMailbox -Identity $recipient.Identity -Properties EmailAddresses
        $mailboxStats = Get-EXOMailboxStatistics -Identity $recipient.Identity
    }

    $targetOneDrive = Get-PersonalSiteMatch -Sites $targetOneDrives -UserPrincipalName $row.TargetUserPrincipalName
    $primaryDomainOk = $false
    if ($mailbox) {
        $primaryDomainOk = ($mailbox.PrimarySmtpAddress -eq $row.FinalPrimarySmtpAddress)
    }

    if (-not $mailbox) {
        $issues.Add([pscustomobject]@{
                Workload = "Target"
                Severity = "Blocker"
                ObjectId = $row.TargetUserPrincipalName
                Detail   = "Target recipient is not a mailbox."
            })
    }

    if (-not $primaryDomainOk) {
        $issues.Add([pscustomobject]@{
                Workload = "Target"
                Severity = "Blocker"
                ObjectId = $row.TargetUserPrincipalName
                Detail   = "Target primary SMTP does not match the expected final address."
            })
    }

    if (-not $targetOneDrive) {
        $issues.Add([pscustomobject]@{
                Workload = "Target"
                Severity = "Warning"
                ObjectId = $row.TargetUserPrincipalName
                Detail   = "Target OneDrive was not found."
            })
    }

    [pscustomobject]@{
        TargetUserPrincipalName = $row.TargetUserPrincipalName
        TargetGraphUser         = [bool]$graphUser
        TargetLicenseCount      = if ($graphUser) { ($graphUser.AssignedLicenses | Measure-Object).Count } else { 0 }
        TargetRecipientType     = if ($recipient) { $recipient.RecipientTypeDetails } else { $null }
        TargetPrimarySmtp       = if ($mailbox) { $mailbox.PrimarySmtpAddress } elseif ($recipient) { $recipient.PrimarySmtpAddress } else { $null }
        FinalPrimaryMatches     = $primaryDomainOk
        CurrentUserPrincipalName = if ($graphUser) { $graphUser.UserPrincipalName } else { $null }
        ExpectedUserPrincipalName = $row.FinalUserPrincipalName
        OneDriveExists          = [bool]$targetOneDrive
        OneDriveUrl             = if ($targetOneDrive) { $targetOneDrive.Url } else { $null }
        MailboxItemCount        = if ($mailboxStats) { $mailboxStats.ItemCount } else { $null }
    }
}

Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph | Out-Null

Connect-ExchangeInteractive -TenantLabel "Source" -ExpectedTenantId $SourceTenantId -AdminUpn $SourceAdminUpn -UseDeviceCode:$UseDeviceCode | Out-Null
Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $SourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null

$sourceResults = foreach ($row in $migrationRows) {
    $recipient = Get-EXORecipient -Identity $row.SourceUserPrincipalName
    $emailAddresses = @($recipient.EmailAddresses)
    $holdsCustomDomain = ($emailAddresses -join ";") -like "*$CustomDomain*" -or $recipient.PrimarySmtpAddress -like "*@$CustomDomain"
    $externalEmail = $null

    if ($recipient.RecipientTypeDetails -eq "MailUser") {
        $mailUser = Get-MailUser -Identity $row.SourceUserPrincipalName
        $externalEmail = $mailUser.ExternalEmailAddress
    }

    if ($recipient.RecipientTypeDetails -ne "MailUser") {
        $issues.Add([pscustomobject]@{
                Workload = "Source"
                Severity = "Blocker"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "Source object is not a MailUser after mailbox migration."
            })
    }

    if ($holdsCustomDomain) {
        $issues.Add([pscustomobject]@{
                Workload = "Source"
                Severity = "Blocker"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "Source object still references the moved custom domain."
            })
    }

    if ($externalEmail -and ($externalEmail.ToString() -notlike "*@$TargetDeliveryDomain")) {
        $issues.Add([pscustomobject]@{
                Workload = "Source"
                Severity = "Warning"
                ObjectId = $row.SourceUserPrincipalName
                Detail   = "Source MailUser external address does not point to the expected target delivery domain."
            })
    }

    [pscustomobject]@{
        SourceUserPrincipalName = $row.SourceUserPrincipalName
        SourceRecipientType     = $recipient.RecipientTypeDetails
        SourcePrimarySmtp       = $recipient.PrimarySmtpAddress
        HoldsCustomDomain       = $holdsCustomDomain
        ExternalEmailAddress    = $externalEmail
    }
}

$sourceCustomDomainDependencies = Get-EXORecipient -ResultSize Unlimited |
Where-Object {
    $_.PrimarySmtpAddress -like "*@$CustomDomain" -or
    $_.WindowsEmailAddress -like "*@$CustomDomain" -or
    ($_.EmailAddresses -join ";") -like "*$CustomDomain*"
} |
Select-Object DisplayName, Alias, RecipientTypeDetails, PrimarySmtpAddress, WindowsEmailAddress, EmailAddresses

$oneDriveStates = @()
if ($TargetCrossTenantHostUrl) {
    $oneDriveStates = foreach ($row in $migrationRows) {
        try {
            Get-SPOCrossTenantUserContentMoveState -PartnerCrossTenantHostURL $TargetCrossTenantHostUrl -SourceUserPrincipalName $row.SourceUserPrincipalName |
            Select-Object State, SourceUserPrincipalName, TargetUserPrincipalName, ErrorMessage
        } catch {
            [pscustomobject]@{
                State                   = "Unknown"
                SourceUserPrincipalName = $row.SourceUserPrincipalName
                TargetUserPrincipalName = $row.TargetUserPrincipalName
                ErrorMessage            = $_.Exception.Message
            }
        }
    }
}

Disconnect-ExchangeOnline -Confirm:$false

Export-Data -Data $targetResults -Path (Join-Path $outDir "target-validation.csv")
Export-Data -Data $sourceResults -Path (Join-Path $outDir "source-validation.csv")
Export-Data -Data $sourceCustomDomainDependencies -Path (Join-Path $outDir "source-custom-domain-dependencies.csv")
Export-Data -Data $oneDriveStates -Path (Join-Path $outDir "onedrive-state.csv")
Export-Data -Data $issues -Path (Join-Path $outDir "issues.csv")

[pscustomobject]@{
    GeneratedAt         = (Get-Date).ToString("s")
    UsersValidated      = ($migrationRows | Measure-Object).Count
    OneDriveStatesRead  = ($oneDriveStates | Measure-Object).Count
    RemainingDomainHits = ($sourceCustomDomainDependencies | Measure-Object).Count
    IssuesFound         = ($issues | Measure-Object).Count
    OutputFolder        = (Resolve-Path $outDir).Path
} | Format-List
