# Microsoft 365 User, Mailbox, and OneDrive Migration Runbook

As of April 17, 2026, this runbook is aligned to Microsoft's current documented guidance for commercial Microsoft 365 tenants.

## Scope

- Source tenant: Org B
- Target tenant: Org A
- User scope: about 10 cloud-only users
- Workloads in scope:
  - user identities
  - Exchange Online mailboxes
  - OneDrive
- Workloads intentionally out of scope:
  - SharePoint sites
  - Teams rebuild or migration
  - Microsoft 365 Groups beyond what is required for user licensing and identity
- Business constraint:
  - migrated users must keep the Org B custom domain as their primary email domain in Org A after cutover
- Operating constraint:
  - Org B remains active after the migration and is not deleted

## Executive Decision

Use Microsoft native cross-tenant migration only for:

1. Exchange Online mailbox migration
2. OneDrive cross-tenant migration
3. Domain transfer at final cutover

Leave the rest of Org B in place.

This is the cleanest path if:

- only the selected users are moving
- Org B must remain alive
- you want to minimize user downtime
- you do not want to rebuild SharePoint or Teams now

## What Org B Must Do To Remain Active

Org B can remain active after the user migration, but only if it stops using the custom domain that will move to Org A.

Required conditions:

- Org B keeps at least one administrative identity on `*.onmicrosoft.com` or another domain that stays in Org B.
- No users, shared mailboxes, groups, contacts, or admin accounts in Org B can still reference the moved custom domain when you remove it.
- DNS for the moved custom domain must point to Org A after cutover.
- Migrated users in Org B become source-side `MailUser` objects after mailbox migration and must be readdressed to a retained Org B domain so Org B can release the custom domain.

Important limitation:

- a Microsoft 365 custom domain can exist in only one tenant at a time

References:

- [Remove a domain from Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/admin/get-help-with-domains/remove-a-domain?view=o365-worldwide)
- [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)

## Supported Microsoft-Native Path

### Exchange Online

Supported:

- cross-tenant mailbox moves initiated from the target tenant using `New-MigrationBatch`
- target users prepared as `MailUser` objects with matching `ExchangeGuid`
- source mailbox converted to `MailUser` after successful migration

Important requirements:

- target users must be mail-enabled correctly before the mailbox batch starts
- source mailbox `LegacyExchangeDN` must be stamped as `x500:` on the target
- all source `x500:` addresses must also be copied to the target MailUser
- holds block migration

References:

- [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)

### OneDrive

Supported:

- cross-tenant OneDrive migration using SharePoint Online PowerShell
- permissions preserved where identity mapping exists
- redirect left on source after migration

Important requirements:

- target users must exist before migration
- target OneDrive should not already be in active use
- trust must be established between source and target tenants
- migration is initiated from the source tenant using `Start-SPOCrossTenantUserContentMove`

References:

- [Cross-tenant OneDrive migration Step 6](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step6?view=o365-worldwide)
- [Post migration steps](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step7?view=o365-worldwide)

## What This Narrow Plan Deliberately Avoids

- Teams migration risk
- SharePoint site migration complexity
- Microsoft 365 Group reconstruction
- Team-connected SharePoint remapping
- custom tooling for Teams history

This materially reduces project risk and lets Org B remain operational.

## Limitations You Still Need To Accept

### Teams and SharePoint remain in Org B

Consequence:

- migrated users lose native same-tenant access patterns unless you later configure B2B or cross-tenant access

Mitigation:

- use B2B collaboration or cross-tenant access for any remaining Org B resources those users still need

Reference:

- [Cross-tenant synchronization overview](https://learn.microsoft.com/en-us/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-overview)

### Domain cutover is still a hard stop event

Consequence:

- Org B cannot keep any object on the moved custom domain

Mitigation:

- pre-stage target users on `@orga.onmicrosoft.com`
- switch Org B objects that must remain active to an Org B retained domain before removing the custom domain

### OneDrive migration is one-time, not incremental

Consequence:

- you need a controlled cutover window for each user's OneDrive

Mitigation:

- pilot with 2 users first
- ask users to stop editing during their move window

## Migration Inputs

Use the included CSV template:

- [MigrationUsers.template.csv](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/MigrationUsers.template.csv)

Required columns:

- `SourceUserPrincipalName`
- `SourcePrimarySmtpAddress`
- `TargetUserPrincipalName`
- `TargetAlias`
- `TargetDisplayName`
- `GivenName`
- `Surname`
- `UsageLocation`

Optional columns:

- `PreCutoverPrimarySmtpAddress`
- `FinalPrimarySmtpAddress`
- `FinalUserPrincipalName`

If the optional columns are blank:

- `PreCutoverPrimarySmtpAddress` defaults to `TargetUserPrincipalName`
- `FinalPrimarySmtpAddress` defaults to `SourcePrimarySmtpAddress`
- `FinalUserPrincipalName` defaults to `FinalPrimarySmtpAddress`

## Included Scripts

- [Invoke-M365UserMailboxOneDriveReadiness.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveReadiness.ps1)
- [Invoke-M365UserMailboxOneDriveExecution.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveExecution.ps1)
- [Invoke-M365UserMailboxOneDriveValidation.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveValidation.ps1)
- [Initialize-M365CrossTenantExchangeSetup.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365CrossTenantExchangeSetup.ps1)
- [Initialize-M365CrossTenantOneDriveTrust.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365CrossTenantOneDriveTrust.ps1)
- [CrossTenantSetup.template.psd1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/CrossTenantSetup.template.psd1)
- [M365InteractiveAuth.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/M365InteractiveAuth.ps1)
- [Initialize-M365MigrationPrerequisites.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365MigrationPrerequisites.ps1)

## Authentication Model

These scripts now assume:

- PowerShell 7
- tenant administrator interactive sign-in
- browser-based auth by default
- device code auth when explicitly requested and supported by the module

Behavior:

- Exchange Online uses interactive browser sign-in by default and supports device code mode
- Microsoft Graph uses interactive browser sign-in by default and supports device code mode
- SharePoint Online uses `Connect-SPOService -UseSystemBrowser $true`
- each script prints a short pre-connection banner before prompting
- each Exchange and Graph connection validates the tenant after sign-in when you provide the expected tenant ID
- SharePoint verifies admin access against the requested admin URL after sign-in
- ExchangeOnlineManagement 3.7.2 or later is required so WAM issues can be retried with `-DisableWAM`
- PowerShell 7 imports SharePoint Online through Windows PowerShell compatibility with `-UseWindowsPowerShell`

Practical recommendation:

- run the prerequisite script before the first migration task
- always pass `SourceTenantId` and `TargetTenantId` for stronger tenant verification
- use `-UseDeviceCode` when browser-based auth or WAM broker auth fails
- keep `AdminUserPrincipalName` values populated in `CrossTenantSetup.psd1` for cleaner Exchange prompts

## Migration Phases

### Phase 0: Readiness

Run the readiness script.

Purpose:

- verify mailbox hold blockers
- verify source OneDrive presence and size
- export mailbox attributes required for target MailUser creation
- check whether target users, target mailboxes, or target OneDrives already exist
- inventory every Org B recipient still using the custom domain

Key output files:

- `migration-prep-input.csv`
- `source-mailbox-baseline.csv`
- `source-onedrive-baseline.csv`
- `source-custom-domain-dependencies.csv`
- `issues.csv`

### Phase 1: Prepare Target MailUsers

Run the execution script with `PrepareTargetMailUsers`.

What it does:

- creates target MailUsers in Org A on the `onmicrosoft.com` namespace
- stamps `ExchangeGuid`
- stamps `ArchiveGuid` when present
- adds source `LegacyExchangeDN` as `x500:`
- adds all source `x500:` values

Critical rule:

- do not assign Exchange licenses before the target MailUser is correctly stamped, or Exchange Online can provision a mailbox with the wrong GUID

This is directly consistent with Microsoft's mailbox migration guidance.

### Phase 2: Assign Licenses

Run the execution script with `AssignTargetLicenses`.

Assign:

- base license for Exchange Online and OneDrive
- Cross-Tenant User Data Migration add-on

Microsoft states the cross-tenant user data migration license is required and covers both mailbox and OneDrive migration.

Reference:

- [Cross-tenant mailbox migration licensing](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)

### Phase 3: Start Mailbox Batch

Run the execution script with `CreateMailboxBatch`.

This creates the CSV input and starts a cross-tenant `New-MigrationBatch` from Org A.

Required beforehand:

- migration app and secret created in Org A
- source tenant admin consent granted
- migration endpoint created in Org A
- organization relationships created in both tenants
- source users added to the source migration scope group

### Phase 4: Start OneDrive Moves

Run the execution script with `StartOneDriveMoves`.

This starts `Start-SPOCrossTenantUserContentMove` from Org B for each user in the CSV.

Required beforehand:

- SharePoint cross-tenant trust configured in both tenants
- compatibility status checked
- identity mapping prepared

### Phase 5: Mailbox Completion and Source Readdressing

When each mailbox is complete:

1. confirm the source mailbox is now a source-side `MailUser`
2. run `ReaddressSourceMailUsersForDomainRelease`
3. move the Org B custom domain only after all Org B objects are off that domain

This is the critical step that lets Org B remain active while relinquishing the custom domain.

### Phase 6: Domain Transfer

Do this only after Org B is clean of the custom domain.

Steps:

1. remove the custom domain from Org B
2. add and verify the custom domain in Org A
3. update DNS to Org A
4. run `SetTargetPrimaryAddresses`

### Phase 7: Final Validation

Run the validation script.

Validate:

- target mailbox exists
- target primary SMTP uses the moved custom domain
- target user UPN is correct if you chose to change it
- target OneDrive exists
- source object is a `MailUser`
- source object no longer uses the moved custom domain
- source `ExternalEmailAddress` points to the target routing domain

## Recommended Cutover Sequence

1. Pilot 2 users first.
2. Run readiness against all 10 users.
3. Prepare target MailUsers in Org A.
4. Assign target licenses.
5. Start mailbox migration batch in Org A.
6. Start OneDrive moves in Org B.
7. Wait for mailbox completion.
8. Readdress source MailUsers in Org B so they no longer hold the custom domain.
9. Remove the custom domain from Org B.
10. Add the custom domain to Org A.
11. Set final primary SMTP addresses in Org A.
12. Optionally set final UPNs in Org A.
13. Run final validation.

## Practical Notes

- Keep at least one Org B global admin on `*.onmicrosoft.com`.
- Do not assign Exchange licenses too early in Org A.
- Do not let target OneDrive be actively used before the move.
- Treat domain cutover as a separate controlled event, not as part of initial pre-staging.
- Remove SharePoint cross-tenant trust when OneDrive migration is fully complete.

Reference:

- [OneDrive post-migration trust removal](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step7?view=o365-worldwide)

## Example Script Flow

```powershell
# -Install will install or update required modules for the current user
.\Initialize-M365MigrationPrerequisites.ps1 -Install

# 0. Fill in CrossTenantSetup.psd1 from the template first

# 0a. Prepare Exchange target setup in Org A
.\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase PrepareTargetExchange `
  -ConfigPath ".\CrossTenantSetup.psd1" `
  -UseDeviceCode

# 0b. Accept the printed consent URL in Org B, then prepare source Exchange setup
.\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase PrepareSourceExchange `
  -ConfigPath ".\CrossTenantSetup.psd1" `
  -UseDeviceCode

# 0c. Establish and verify SharePoint trust for OneDrive
.\Initialize-M365CrossTenantOneDriveTrust.ps1 `
  -Phase EstablishAndVerifyTrust `
  -ConfigPath ".\CrossTenantSetup.psd1"

# 1. Readiness
.\Invoke-M365UserMailboxOneDriveReadiness.ps1 `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetTenantAdminUrl "https://orga-admin.sharepoint.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -MigrationCsvPath ".\MigrationUsers.csv" `
  -CustomDomain "orgb.com" `
  -UseDeviceCode

# 2. Prepare target MailUsers
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase PrepareTargetMailUsers `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TemporaryPasswordPlainText "ReplaceThisWithATemporaryPassword!" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UseDeviceCode

# 3. Assign licenses
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase AssignTargetLicenses `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -LicenseSkuPartNumbers "SPE_E3","CROSS_TENANT_USER_DATA_MIGRATION" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UseDeviceCode

# 3a. Add source users to the mailbox migration scope group in Org B
.\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase AddUsersToSourceScopeGroup `
  -ConfigPath ".\CrossTenantSetup.psd1" `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -UseDeviceCode

# 4. Create mailbox batch in Org A
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase CreateMailboxBatch `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -MigrationEndpointName "OrgB-CrossTenant" `
  -BatchName "Wave01" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UseDeviceCode

# 5. Start OneDrive moves from Org B
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase StartOneDriveMoves `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetCrossTenantHostUrl "https://orga-my.sharepoint.com/" `
  -UseDeviceCode

# 6. Readdress source MailUsers after the mailbox moves are done
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase ReaddressSourceMailUsersForDomainRelease `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -UseDeviceCode

# 7. After domain is attached to Org A, set final SMTP/UPN
.\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase SetTargetPrimaryAddresses `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UpdateUserPrincipalNames `
  -UseDeviceCode

# 8. Final validation
.\Invoke-M365UserMailboxOneDriveValidation.ps1 `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetTenantAdminUrl "https://orga-admin.sharepoint.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -CustomDomain "orgb.com" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -UseDeviceCode
```
