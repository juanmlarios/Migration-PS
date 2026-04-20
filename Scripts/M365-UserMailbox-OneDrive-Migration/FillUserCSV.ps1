Connect-ExchangeOnline
Connect-MgGraph -Scopes "User.Read.All", "Directory.Read.All"

$users = @(
    "juan.larios@slaterhill.com",
    "ben.devito@slaterhill.com",
    "tom.hill@slaterhill.com"
)

$rows = foreach ($id in $users) {
    $exo = Get-EXOMailbox -Identity $id -Properties DisplayName, Alias, EmailAddresses
    $mg = Get-MgUser -UserId $exo.UserPrincipalName -Property GivenName, Surname, UsageLocation, DisplayName, MailNickname
    $targetAlias = if ($exo.Alias) { $exo.Alias } elseif ($mg.MailNickname) { $mg.MailNickname } else { ($exo.UserPrincipalName -split "@")[0] }

    [pscustomobject]@{
        SourceUserPrincipalName      = $exo.UserPrincipalName
        SourcePrimarySmtpAddress     = $exo.PrimarySmtpAddress
        TargetUserPrincipalName      = ($targetAlias + "@orga.onmicrosoft.com")
        TargetAlias                  = $targetAlias
        TargetDisplayName            = $exo.DisplayName
        GivenName                    = $mg.GivenName
        Surname                      = $mg.Surname
        UsageLocation                = $mg.UsageLocation
        PreCutoverPrimarySmtpAddress = ""
        FinalPrimarySmtpAddress      = ""
        FinalUserPrincipalName       = ""
    }
}

$rows | Export-Csv .\MigrationUsers.csv -NoTypeInformation -Encoding UTF8
