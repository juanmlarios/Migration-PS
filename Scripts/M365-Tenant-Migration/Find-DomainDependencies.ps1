[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Domain,

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
Ensure-Module -Name Microsoft.Graph

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$outDir = Join-Path $OutputRoot "domain-dependencies-$($Domain)-$stamp"
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

Connect-MgGraph -Scopes "Directory.Read.All", "User.Read.All", "Group.Read.All", "Domain.Read.All" | Out-Null
Connect-ExchangeOnline -ShowBanner:$false

$recipientHits = Get-EXORecipient -ResultSize Unlimited |
Where-Object {
    $_.PrimarySmtpAddress -like "*@$Domain" -or
    $_.WindowsEmailAddress -like "*@$Domain" -or
    ($_.EmailAddresses -join ";") -like "*$Domain*"
} |
Select-Object DisplayName, Alias, RecipientTypeDetails, PrimarySmtpAddress, WindowsEmailAddress, EmailAddresses

$userHits = Get-MgUser -All -Property Id,DisplayName,UserPrincipalName,Mail,ProxyAddresses |
Where-Object {
    $_.UserPrincipalName -like "*@$Domain" -or
    $_.Mail -like "*@$Domain" -or
    ($_.ProxyAddresses -join ";") -like "*$Domain*"
} |
Select-Object Id, DisplayName, UserPrincipalName, Mail, ProxyAddresses

$groupHits = Get-MgGroup -All -Property Id,DisplayName,Mail,ProxyAddresses,MailNickname |
Where-Object {
    $_.Mail -like "*@$Domain" -or
    ($_.ProxyAddresses -join ";") -like "*$Domain*"
} |
Select-Object Id, DisplayName, Mail, MailNickname, ProxyAddresses

$recipientHits | Export-Csv -Path (Join-Path $outDir "exchange-recipient-hits.csv") -NoTypeInformation -Encoding UTF8
$userHits | Export-Csv -Path (Join-Path $outDir "graph-user-hits.csv") -NoTypeInformation -Encoding UTF8
$groupHits | Export-Csv -Path (Join-Path $outDir "graph-group-hits.csv") -NoTypeInformation -Encoding UTF8

[pscustomobject]@{
    Domain             = $Domain
    GeneratedAt        = (Get-Date).ToString("s")
    RecipientHitCount  = ($recipientHits | Measure-Object).Count
    UserHitCount       = ($userHits | Measure-Object).Count
    GroupHitCount      = ($groupHits | Measure-Object).Count
    OutputFolder       = (Resolve-Path $outDir).Path
} | Format-List

Disconnect-ExchangeOnline -Confirm:$false
Disconnect-MgGraph | Out-Null
