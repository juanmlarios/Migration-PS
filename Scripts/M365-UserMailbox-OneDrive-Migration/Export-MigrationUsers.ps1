[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]]$SourceIdentities,

    [Parameter(Mandatory = $true)]
    [string]$TargetDomain,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = ".\MigrationUsers.csv"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-TargetUpn {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Alias,

        [Parameter(Mandatory = $true)]
        [string]$Domain
    )

    return ("{0}@{1}" -f $Alias, $Domain)
}

$rows = foreach ($identity in $SourceIdentities) {
    $exo = Get-EXOMailbox -Identity $identity -Properties DisplayName,Alias,EmailAddresses

    $graphUser = Get-MgUser -UserId $exo.UserPrincipalName -Property `
        GivenName, `
        Surname, `
        UsageLocation, `
        DisplayName, `
        Mail, `
        MailNickname, `
        UserPrincipalName

    $targetAlias = if ($exo.Alias) { $exo.Alias } elseif ($graphUser.MailNickname) { $graphUser.MailNickname } else { ($exo.UserPrincipalName -split "@")[0] }
    $targetDisplayName = if ($graphUser.DisplayName) { $graphUser.DisplayName } else { $exo.DisplayName }

    [pscustomobject]@{
        SourceUserPrincipalName      = $exo.UserPrincipalName
        SourcePrimarySmtpAddress     = $exo.PrimarySmtpAddress
        TargetUserPrincipalName      = Get-TargetUpn -Alias $targetAlias -Domain $TargetDomain
        TargetAlias                  = $targetAlias
        TargetDisplayName            = $targetDisplayName
        GivenName                    = $graphUser.GivenName
        Surname                      = $graphUser.Surname
        UsageLocation                = $graphUser.UsageLocation
        PreCutoverPrimarySmtpAddress = ""
        FinalPrimarySmtpAddress      = ""
        FinalUserPrincipalName       = ""
    }
}

$parent = Split-Path -Path $OutputPath -Parent
if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -Path $parent)) {
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
}

$rows | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host ("Wrote {0} rows to {1}" -f $rows.Count, (Resolve-Path $OutputPath).Path)
