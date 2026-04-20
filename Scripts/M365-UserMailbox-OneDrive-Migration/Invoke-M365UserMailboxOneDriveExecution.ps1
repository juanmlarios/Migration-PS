[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "PrepareTargetMailUsers",
        "AssignTargetLicenses",
        "CreateMailboxBatch",
        "StartOneDriveMoves",
        "ReaddressSourceMailUsersForDomainRelease",
        "SetTargetPrimaryAddresses"
    )]
    [string]$Phase,

    [Parameter(Mandatory = $true)]
    [string]$MigrationCsvPath,

    [Parameter(Mandatory = $false)]
    [string]$TemporaryPasswordPlainText,

    [Parameter(Mandatory = $false)]
    [string[]]$LicenseSkuPartNumbers,

    [Parameter(Mandatory = $false)]
    [string]$MigrationEndpointName,

    [Parameter(Mandatory = $false)]
    [string]$BatchName,

    [Parameter(Mandatory = $false)]
    [string]$TargetDeliveryDomain,

    [Parameter(Mandatory = $false)]
    [string]$SourceTenantAdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$TargetTenantAdminUrl,

    [Parameter(Mandatory = $false)]
    [string]$TargetCrossTenantHostUrl,

    [Parameter(Mandatory = $false)]
    [datetime]$PreferredMoveBeginDateUtc,

    [Parameter(Mandatory = $false)]
    [datetime]$PreferredMoveEndDateUtc,

    [Parameter(Mandatory = $false)]
    [switch]$UpdateUserPrincipalNames,

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
    [switch]$DisableExchangeWAM,

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

function Require-Parameter {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Value
    )

    if ($null -eq $Value -or ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value))) {
        throw "Parameter '$Name' is required for phase '$Phase'."
    }
}

function Get-PrimaryAddressLocalPart {
    param([Parameter(Mandatory = $true)][string]$Address)

    return ($Address -split "@")[0]
}

function Get-TempPassword {
    param([Parameter(Mandatory = $true)][string]$PlainText)

    return (ConvertTo-SecureString -String $PlainText -AsPlainText -Force)
}

function Add-MailUserX500Addresses {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string[]]$Addresses
    )

    foreach ($address in $Addresses) {
        if ([string]::IsNullOrWhiteSpace($address)) {
            continue
        }

        Set-MailUser -Identity $Identity -EmailAddresses @{ Add = $address }
    }
}

function Set-RecipientPrimaryAddress {
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [Parameter(Mandatory = $true)][string]$PrimarySmtpAddress,
        [Parameter(Mandatory = $true)][string[]]$EmailAddresses
    )

    $recipient = Get-EXORecipient -Identity $Identity
    if ($recipient.RecipientTypeDetails -eq "MailUser") {
        Set-MailUser -Identity $Identity -PrimarySmtpAddress $PrimarySmtpAddress -EmailAddresses $EmailAddresses
    } elseif ($recipient.RecipientTypeDetails -eq "UserMailbox") {
        Set-Mailbox -Identity $Identity -PrimarySmtpAddress $PrimarySmtpAddress -EmailAddresses $EmailAddresses
    } else {
        throw "Unsupported recipient type '$($recipient.RecipientTypeDetails)' for '$Identity'."
    }
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
$outDir = Join-Path $OutputRoot "$Phase-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

switch ($Phase) {
    "PrepareTargetMailUsers" {
        Require-Parameter -Name "TemporaryPasswordPlainText" -Value $TemporaryPasswordPlainText

        Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $TargetTenantId -AdminUpn $TargetAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null
        $password = Get-TempPassword -PlainText $TemporaryPasswordPlainText
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $migrationRows) {
            $existing = $null
            try {
                $existing = Get-EXORecipient -Identity $row.TargetUserPrincipalName -ErrorAction Stop
            } catch {
                $existing = $null
            }

            if (-not $existing) {
                New-MailUser `
                    -MicrosoftOnlineServicesID $row.TargetUserPrincipalName `
                    -PrimarySmtpAddress $row.PreCutoverPrimarySmtpAddress `
                    -ExternalEmailAddress $row.SourceOnMicrosoftAddress `
                    -FirstName $row.GivenName `
                    -LastName $row.Surname `
                    -Name $row.TargetDisplayName `
                    -DisplayName $row.TargetDisplayName `
                    -Alias $row.TargetAlias `
                    -Password $password | Out-Null
            } elseif ($existing.RecipientTypeDetails -eq "UserMailbox") {
                throw "Target object '$($row.TargetUserPrincipalName)' already has a mailbox."
            }

            $setParams = @{
                Identity     = $row.TargetUserPrincipalName
                ExchangeGuid = $row.ExchangeGuid
            }

            if ($row.ArchiveGuid) {
                $setParams["ArchiveGuid"] = $row.ArchiveGuid
            }

            Set-MailUser @setParams

            $x500Values = @()
            if ($row.LegacyExchangeDn) {
                $x500Values += "x500:$($row.LegacyExchangeDn)"
            }
            if ($row.X500Addresses) {
                $x500Values += ($row.X500Addresses -split "\|" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
            $x500Values = $x500Values | Select-Object -Unique

            Add-MailUserX500Addresses -Identity $row.TargetUserPrincipalName -Addresses $x500Values

            $results.Add([pscustomobject]@{
                    TargetUserPrincipalName  = $row.TargetUserPrincipalName
                    PreCutoverPrimarySmtp    = $row.PreCutoverPrimarySmtpAddress
                    ExternalEmailAddress     = $row.SourceOnMicrosoftAddress
                    ExchangeGuid             = $row.ExchangeGuid
                    ArchiveGuid              = $row.ArchiveGuid
                    X500AddressCount         = ($x500Values | Measure-Object).Count
                    Status                   = "Prepared"
                })
        }

        Export-Data -Data $results -Path (Join-Path $outDir "prepared-target-mailusers.csv")
        Disconnect-ExchangeOnline -Confirm:$false
    }

    "AssignTargetLicenses" {
        Require-Parameter -Name "LicenseSkuPartNumbers" -Value $LicenseSkuPartNumbers

        Connect-GraphInteractive -TenantLabel "Target" -Scopes @("User.ReadWrite.All", "Directory.Read.All", "Organization.Read.All") -ExpectedTenantId $TargetTenantId -UseDeviceCode:$UseDeviceCode | Out-Null
        $skus = Get-MgSubscribedSku -All

        $resolvedSkuIds = foreach ($partNumber in $LicenseSkuPartNumbers) {
            $sku = $skus | Where-Object { $_.SkuPartNumber -eq $partNumber } | Select-Object -First 1
            if (-not $sku) {
                throw "Could not resolve SKU part number '$partNumber' in the target tenant."
            }
            $sku.SkuId
        }

        $results = foreach ($row in $migrationRows) {
            $user = Get-MgUser -UserId $row.TargetUserPrincipalName -Property Id, UserPrincipalName
            $addLicenses = foreach ($skuId in $resolvedSkuIds) {
                @{ SkuId = $skuId }
            }

            Set-MgUserLicense -UserId $user.Id -AddLicenses $addLicenses -RemoveLicenses @() | Out-Null

            [pscustomobject]@{
                TargetUserPrincipalName = $row.TargetUserPrincipalName
                AssignedSkuCount        = $resolvedSkuIds.Count
                Status                  = "Licensed"
            }
        }

        Export-Data -Data $results -Path (Join-Path $outDir "license-results.csv")
        Disconnect-MgGraph | Out-Null
    }

    "CreateMailboxBatch" {
        Require-Parameter -Name "MigrationEndpointName" -Value $MigrationEndpointName
        Require-Parameter -Name "BatchName" -Value $BatchName
        Require-Parameter -Name "TargetDeliveryDomain" -Value $TargetDeliveryDomain

        Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $TargetTenantId -AdminUpn $TargetAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null

        $batchCsvPath = Join-Path $outDir "$BatchName-users.csv"
        $batchRows = $migrationRows | ForEach-Object {
            [pscustomobject]@{
                EmailAddress = $_.TargetUserPrincipalName
            }
        }
        Export-Data -Data $batchRows -Path $batchCsvPath

        $csvData = [System.IO.File]::ReadAllBytes((Resolve-Path $batchCsvPath).Path)

        $batch = New-MigrationBatch `
            -Name $BatchName `
            -SourceEndpoint $MigrationEndpointName `
            -CSVData $csvData `
            -AutoStart `
            -TargetDeliveryDomain $TargetDeliveryDomain

        $batchResult = $batch | Select-Object Identity, Status, Type, TotalCount
        Export-Data -Data $batchResult -Path (Join-Path $outDir "mailbox-batch-result.csv")

        Disconnect-ExchangeOnline -Confirm:$false
    }

    "StartOneDriveMoves" {
        Require-Parameter -Name "SourceTenantAdminUrl" -Value $SourceTenantAdminUrl
        Require-Parameter -Name "TargetCrossTenantHostUrl" -Value $TargetCrossTenantHostUrl

        Connect-SPOInteractive -TenantLabel "Source" -AdminUrl $SourceTenantAdminUrl -UseDeviceCode:$UseDeviceCode | Out-Null
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $migrationRows) {
            $moveParams = @{
                SourceUserPrincipalName = $row.SourceUserPrincipalName
                TargetUserPrincipalName = $row.TargetUserPrincipalName
                TargetCrossTenantHostUrl = $TargetCrossTenantHostUrl
            }

            if ($PSBoundParameters.ContainsKey("PreferredMoveBeginDateUtc")) {
                $moveParams["PreferredMoveBeginDate"] = $PreferredMoveBeginDateUtc.ToUniversalTime()
            }
            if ($PSBoundParameters.ContainsKey("PreferredMoveEndDateUtc")) {
                $moveParams["PreferredMoveEndDate"] = $PreferredMoveEndDateUtc.ToUniversalTime()
            }

            Start-SPOCrossTenantUserContentMove @moveParams

            $results.Add([pscustomobject]@{
                    SourceUserPrincipalName = $row.SourceUserPrincipalName
                    TargetUserPrincipalName = $row.TargetUserPrincipalName
                    Status                  = "MoveSubmitted"
                })
        }

        Export-Data -Data $results -Path (Join-Path $outDir "onedrive-move-submissions.csv")
    }

    "ReaddressSourceMailUsersForDomainRelease" {
        Require-Parameter -Name "TargetDeliveryDomain" -Value $TargetDeliveryDomain

        Connect-ExchangeInteractive -TenantLabel "Source" -ExpectedTenantId $SourceTenantId -AdminUpn $SourceAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $migrationRows) {
            $recipient = Get-EXORecipient -Identity $row.SourceUserPrincipalName
            if ($recipient.RecipientTypeDetails -ne "MailUser") {
                throw "Source object '$($row.SourceUserPrincipalName)' is not yet a MailUser. Do not readdress before mailbox migration completes."
            }

            $retainedSourceAddress = $row.SourceOnMicrosoftAddress
            $targetRoutingAddress = "{0}@{1}" -f (Get-PrimaryAddressLocalPart -Address $row.TargetUserPrincipalName), $TargetDeliveryDomain

            $newAddresses = @("SMTP:$retainedSourceAddress")

            Set-MailUser -Identity $row.SourceUserPrincipalName `
                -PrimarySmtpAddress $retainedSourceAddress `
                -ExternalEmailAddress $targetRoutingAddress `
                -EmailAddresses $newAddresses

            $results.Add([pscustomobject]@{
                    SourceUserPrincipalName = $row.SourceUserPrincipalName
                    NewPrimarySmtpAddress   = $retainedSourceAddress
                    ExternalEmailAddress    = $targetRoutingAddress
                    Status                  = "Readdressed"
                })
        }

        Export-Data -Data $results -Path (Join-Path $outDir "source-mailuser-readdressing.csv")
        Disconnect-ExchangeOnline -Confirm:$false
    }

    "SetTargetPrimaryAddresses" {
        Connect-ExchangeInteractive -TenantLabel "Target" -ExpectedTenantId $TargetTenantId -AdminUpn $TargetAdminUpn -UseDeviceCode:$UseDeviceCode -DisableWAM:$DisableExchangeWAM | Out-Null
        Connect-GraphInteractive -TenantLabel "Target" -Scopes @("User.ReadWrite.All", "Directory.Read.All") -ExpectedTenantId $TargetTenantId -UseDeviceCode:$UseDeviceCode | Out-Null
        $results = [System.Collections.Generic.List[object]]::new()

        foreach ($row in $migrationRows) {
            $recipient = Get-EXORecipient -Identity $row.TargetUserPrincipalName
            $existingAddresses = @($recipient.EmailAddresses | ForEach-Object { $_.ToString() })
            $nonSmtpAddresses = $existingAddresses | Where-Object { $_ -notmatch '^(?i)smtp:' }
            $secondarySmtp = $existingAddresses |
            Where-Object {
                $_ -match '^(?i)smtp:' -and
                $_ -notmatch "^SMTP:$([regex]::Escape($row.FinalPrimarySmtpAddress))$"
            } |
            ForEach-Object { $_ -replace '^SMTP:', 'smtp:' }

            $emailAddresses = @(
                "SMTP:$($row.FinalPrimarySmtpAddress)",
                "smtp:$($row.PreCutoverPrimarySmtpAddress)"
            ) + $secondarySmtp + $nonSmtpAddresses

            $emailAddresses = $emailAddresses | Select-Object -Unique

            Set-RecipientPrimaryAddress `
                -Identity $row.TargetUserPrincipalName `
                -PrimarySmtpAddress $row.FinalPrimarySmtpAddress `
                -EmailAddresses $emailAddresses

            $upnUpdated = $false
            if ($UpdateUserPrincipalNames.IsPresent -and $row.FinalUserPrincipalName) {
                Update-MgUser -UserId $row.TargetUserPrincipalName -UserPrincipalName $row.FinalUserPrincipalName
                $upnUpdated = $true
            }

            $results.Add([pscustomobject]@{
                    TargetUserPrincipalName = $row.TargetUserPrincipalName
                    FinalPrimarySmtpAddress = $row.FinalPrimarySmtpAddress
                    FinalUserPrincipalName  = $row.FinalUserPrincipalName
                    UserPrincipalNameUpdated = $upnUpdated
                    Status                  = "Updated"
                })
        }

        Export-Data -Data $results -Path (Join-Path $outDir "target-address-updates.csv")
        Disconnect-ExchangeOnline -Confirm:$false
        Disconnect-MgGraph | Out-Null
    }
}

[pscustomobject]@{
    Phase        = $Phase
    GeneratedAt  = (Get-Date).ToString("s")
    UserCount    = ($migrationRows | Measure-Object).Count
    OutputFolder = (Resolve-Path $outDir).Path
} | Format-List
