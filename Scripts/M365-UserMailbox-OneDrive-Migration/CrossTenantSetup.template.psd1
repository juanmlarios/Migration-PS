@{
    Source = @{
        TenantId                  = "00000000-0000-0000-0000-000000000000"
        OnMicrosoftDomain         = "orgb.onmicrosoft.com"
        AdminUserPrincipalName    = "admin@orgb.onmicrosoft.com"
        TenantAdminUrl            = "https://orgb-admin.sharepoint.com"
        MigrationScopeGroupName   = "OrgB-MailboxMoveScope"
        OrganizationRelationshipName = "OrgB-to-OrgA-MailboxMoves"
    }

    Target = @{
        TenantId                  = "11111111-1111-1111-1111-111111111111"
        OnMicrosoftDomain         = "orga.onmicrosoft.com"
        AdminUserPrincipalName    = "admin@orga.onmicrosoft.com"
        TenantAdminUrl            = "https://orga-admin.sharepoint.com"
        MigrationEndpointName     = "OrgB-CrossTenant"
        OrganizationRelationshipName = "OrgA-from-OrgB-MailboxMoves"
    }

    Exchange = @{
        AppId             = "22222222-2222-2222-2222-222222222222"
        AppSecretPlainText = "replace-with-secret"
        ConsentRedirectUri = "https://office.com"
    }
}
