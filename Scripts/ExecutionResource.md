# Execution Resource

This guide explains how an administrator should prepare, run, and validate the Microsoft 365 narrow-scope migration scripts in this workspace.

## Scope

This script set supports:

- user creation and preparation in Org A
- Exchange Online cross-tenant mailbox migration
- OneDrive cross-tenant migration
- custom domain release from Org B and reassignment to Org A
- post-cutover validation

This script set does not migrate:

- SharePoint sites
- Teams
- Microsoft 365 Groups as full collaboration objects

## Files Used

Primary runbook:

- [m365-user-mailbox-onedrive-runbook-orgb-remains.md](/Users/juan/GitHub/SecureLift-Research/m365-user-mailbox-onedrive-runbook-orgb-remains.md)

Admin execution files:

- [Initialize-M365MigrationPrerequisites.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365MigrationPrerequisites.ps1)
- [CrossTenantSetup.template.psd1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/CrossTenantSetup.template.psd1)
- [MigrationUsers.template.csv](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/MigrationUsers.template.csv)
- [Initialize-M365CrossTenantExchangeSetup.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365CrossTenantExchangeSetup.ps1)
- [Initialize-M365CrossTenantOneDriveTrust.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Initialize-M365CrossTenantOneDriveTrust.ps1)
- [Invoke-M365UserMailboxOneDriveReadiness.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveReadiness.ps1)
- [Invoke-M365UserMailboxOneDriveExecution.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveExecution.ps1)
- [Invoke-M365UserMailboxOneDriveValidation.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/Invoke-M365UserMailboxOneDriveValidation.ps1)

## Assumptions

- You are running PowerShell 7 as a tenant administrator.
- Org B is the source tenant.
- Org A is the target tenant.
- Migrated users are cloud-only.
- Org B remains active after the migration.
- The custom domain currently in Org B will be moved to Org A.
- You want interactive sign-in, with device code available where Microsoft supports it.

## High-Level Order

Run the work in this order:

1. Prepare your local PowerShell environment.
2. Fill in the migration user CSV.
3. Run readiness and discovery before any configuration or setup.
4. Review readiness outputs and remediate blockers.
5. Fill in the tenant configuration template.
6. Perform the manual Entra app preparation for Exchange cross-tenant migration.
7. Run Exchange setup scripts.
8. Run OneDrive trust setup.
9. Prepare target MailUsers.
10. Assign target licenses.
11. Add source users to the mailbox move scope group.
12. Create the Exchange migration batch.
13. Start OneDrive moves.
14. Monitor completion.
15. Readdress source MailUsers in Org B to release the custom domain.
16. Perform manual domain cutover.
17. Set final SMTP addresses and optional UPNs in Org A.
18. Run final validation.

## Prerequisites

### Administrative prerequisites

You need:

- Global Admin or equivalent delegated rights in Org A and Org B
- Exchange admin rights in both tenants
- SharePoint admin rights in both tenants
- permission to create an Entra app in Org A
- permission to grant admin consent in Org B

### Local prerequisites

You need:

- PowerShell 7
- internet access to the PowerShell Gallery
- ability to install modules for the current user

Run this first:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365MigrationPrerequisites.ps1 -Install
```

What it does:

- verifies PowerShell 7+
- checks required module versions
- installs or updates required modules for the current user
- checks that the required commands are present

### Tenant prerequisites

For readiness only, you need:

- admin access to source and target tenants
- source and target SharePoint admin URLs
- source and target tenant IDs if you want tenant verification
- the migration user CSV

For migration setup and execution later, you also need:

- Exchange migration app in Org A
- app ID and client secret
- Org B admin consent for that app
- target users created in Org A before OneDrive migration starts

## Files You Must Fill In

### 1. Migration user CSV

Prepare this first.

Copy:

- [MigrationUsers.template.csv](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/MigrationUsers.template.csv)

Create a working file, for example:

- `MigrationUsers.csv`

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

Recommended values:

- `TargetUserPrincipalName`: use `@orga.onmicrosoft.com`
- `PreCutoverPrimarySmtpAddress`: same as the target `onmicrosoft.com` address unless you need something else
- `FinalPrimarySmtpAddress`: the current production SMTP address on the Org B custom domain
- `FinalUserPrincipalName`: usually the same as `FinalPrimarySmtpAddress` if you want UPNs switched after cutover

### 2. Tenant config file

Copy:

- [CrossTenantSetup.template.psd1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-UserMailbox-OneDrive-Migration/CrossTenantSetup.template.psd1)

Create a working file beside it, for example:

- `CrossTenantSetup.psd1`

Fill in:

- `Source.TenantId`
- `Source.OnMicrosoftDomain`
- `Source.AdminUserPrincipalName`
- `Source.TenantAdminUrl`
- `Source.MigrationScopeGroupName`
- `Source.OrganizationRelationshipName`
- `Target.TenantId`
- `Target.OnMicrosoftDomain`
- `Target.AdminUserPrincipalName`
- `Target.TenantAdminUrl`
- `Target.MigrationEndpointName`
- `Target.OrganizationRelationshipName`
- `Exchange.AppId`
- `Exchange.AppSecretPlainText`
- `Exchange.ConsentRedirectUri`

Practical guidance:

- do not fill this file until after readiness is complete and you are ready to configure migration
- use stable names for relationship objects and migration endpoint names
- use `https://office.com` or another valid redirect URI that matches the app registration
- keep this file secured because it contains a client secret

## Manual Steps Outside the Scripts

### Manual step 1: Create the Exchange migration app in Org A

The scripts do not create the Entra application for you.

You must manually:

1. Create or identify the app registration in Org A.
2. Create a client secret.
3. Grant the application the required Exchange migration permission per Microsoft's current cross-tenant mailbox migration guidance.
4. Put the `AppId` and `AppSecretPlainText` into `CrossTenantSetup.psd1`.

### Manual step 2: Admin consent in Org B

When you run:

- `Initialize-M365CrossTenantExchangeSetup.ps1 -Phase PrepareTargetExchange`

the script prints a consent URL.

You must:

1. Open that URL.
2. Sign in as an Org B administrator.
3. Grant admin consent.

Then continue to the source Exchange setup phase.

### Manual step 3: Domain cutover

The scripts do not move the custom domain between tenants.

You must manually:

1. remove the custom domain from all remaining Org B objects
2. remove the domain from Org B
3. add and verify the domain in Org A
4. update DNS for Org A mail flow

Only after that should you run:

- `SetTargetPrimaryAddresses`

## Authentication Model

The scripts now support:

- interactive browser auth by default
- device code auth when you pass `-UseDeviceCode` and the module supports it

Workload behavior:

- Exchange Online: browser auth by default, device code supported
- Microsoft Graph: browser auth by default, device code supported
- SharePoint Online: system browser auth only

What the scripts do at connect time:

- print a short banner telling you which tenant to sign into
- verify Exchange tenant ID after sign-in if you supplied `SourceTenantId` or `TargetTenantId`
- verify Graph tenant ID after sign-in if you supplied `SourceTenantId` or `TargetTenantId`
- verify SharePoint admin access against the requested admin URL

Recommendation:

- always pass tenant IDs where the script supports them

## Readiness-First Workflow

Readiness is not just a single script launch. It is a short assessment phase with required review and remediation before any migration configuration is done.

### Readiness phase order

1. Install prerequisites.
2. Prepare `MigrationUsers.csv`.
3. Run the readiness script only.
4. Review the readiness outputs in detail.
5. Fix blockers.
6. Freeze the migration wave membership.
7. Only then create `CrossTenantSetup.psd1` and proceed with tenant setup.

### What the readiness script checks

The readiness script performs these checks:

- source mailbox existence for every CSV user
- source mailbox hold blockers:
  - litigation hold
  - retention hold
  - in-place holds
- source Exchange attributes needed later:
  - `ExchangeGuid`
  - `ArchiveGuid`
  - `LegacyExchangeDN`
  - source `x500` addresses
  - source `onmicrosoft.com` routing address
- source mailbox baseline:
  - item count
  - total item size
- source OneDrive discovery:
  - whether a personal site exists
  - URL
  - owner
  - size
  - lock state
  - sharing capability
- source custom domain dependencies across Exchange recipients
- target tenant readiness:
  - whether the target user exists
  - whether a target recipient already exists
  - whether the target recipient is already a mailbox
  - whether a target OneDrive already exists

### Readiness outputs you must review

The readiness script writes these outputs:

- `issues.csv`
- `source-mailbox-baseline.csv`
- `source-onedrive-baseline.csv`
- `source-custom-domain-dependencies.csv`
- `target-readiness.csv`
- `migration-prep-input.csv`

Use them as follows:

- `issues.csv`
  - stop list for blockers and warnings
- `source-mailbox-baseline.csv`
  - source mailbox inventory and move-prep attributes
- `source-onedrive-baseline.csv`
  - OneDrive scope and size review
- `source-custom-domain-dependencies.csv`
  - domain cutover planning
- `target-readiness.csv`
  - confirms whether Org A is clean enough for pre-stage
- `migration-prep-input.csv`
  - normalized handoff file for later execution scripts

### Readiness stop conditions

Do not proceed into setup if any of these are true:

- a source mailbox is on hold
- a source user has no usable `onmicrosoft.com` routing address
- a source OneDrive exceeds the supported size threshold
- a target recipient already exists as a mailbox
- a target OneDrive already exists and is intended for the same user
- `source-custom-domain-dependencies.csv` contains Org B objects that still need the custom domain

## Detailed Execution Order

### Step 1: Install or update prerequisites

Run:

```powershell
cd /Users/juan/GitHub/SecureLift-Research
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365MigrationPrerequisites.ps1 -Install
```

Expected outcome:

- PowerShell and module checks report `Ready`

### Step 2: Create and fill `MigrationUsers.csv`

Populate the CSV for the migration wave.

For a first pilot, keep this to 2 users.

This must be done before any tenant configuration or setup.

### Step 3: Run readiness before setup

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveReadiness.ps1 `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetTenantAdminUrl "https://orga-admin.sharepoint.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -SourceAdminUpn "admin@orgb.onmicrosoft.com" `
  -TargetAdminUpn "admin@orga.onmicrosoft.com" `
  -MigrationCsvPath ".\MigrationUsers.csv" `
  -CustomDomain "orgb.com" `
  -UseDeviceCode
```

What it does:

- checks source mailbox holds
- extracts Exchange GUID and `x500` values needed later
- inventories source OneDrive state
- checks whether target user/recipient/OneDrive objects already exist
- inventories Org B objects still using the custom domain
- writes a normalized file named `migration-prep-input.csv`

Review outputs:

- `issues.csv`
- `source-mailbox-baseline.csv`
- `source-onedrive-baseline.csv`
- `target-readiness.csv`
- `source-custom-domain-dependencies.csv`
- `migration-prep-input.csv`

Do not continue until blockers are resolved.

### Step 4: Review readiness outputs and remediate

At this point, no migration setup should have been done yet.

Review and resolve:

- mailbox holds
- OneDrive size exceptions
- target mailbox collisions
- target OneDrive collisions
- custom domain dependencies in Org B
- any CSV data corrections

If you change the CSV, rerun readiness and replace the previous readiness outputs.

### Step 5: Create and fill `CrossTenantSetup.psd1`

Use the template and create your working copy only after readiness is acceptable.

Do not commit secrets into source control.

### Step 6: Prepare Exchange target setup in Org A

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase PrepareTargetExchange `
  -ConfigPath ".\Scripts\M365-UserMailbox-OneDrive-Migration\CrossTenantSetup.psd1" `
  -UseDeviceCode
```

What it does:

- connects to Exchange Online in Org A
- ensures organization customization is enabled if needed
- creates or updates the target migration endpoint
- creates or updates the target organization relationship
- prints the admin consent URL for Org B

### Step 7: Grant source-tenant admin consent in Org B

Manual:

- open the consent URL printed in step 4
- sign in to Org B as admin
- grant consent

### Step 8: Prepare Exchange source setup in Org B

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase PrepareSourceExchange `
  -ConfigPath ".\Scripts\M365-UserMailbox-OneDrive-Migration\CrossTenantSetup.psd1" `
  -UseDeviceCode
```

What it does:

- connects to Exchange Online in Org B
- creates or updates the mailbox move scope security group
- creates or updates the source organization relationship

### Step 9: Establish and verify OneDrive trust

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365CrossTenantOneDriveTrust.ps1 `
  -Phase EstablishAndVerifyTrust `
  -ConfigPath ".\Scripts\M365-UserMailbox-OneDrive-Migration\CrossTenantSetup.psd1"
```

What it does:

- connects to SharePoint admin in both tenants
- gets cross-tenant host URLs
- establishes trust in both directions
- verifies the trust
- checks compatibility

### Step 10: Prepare target MailUsers in Org A

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase PrepareTargetMailUsers `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TemporaryPasswordPlainText "ReplaceThisWithATemporaryPassword!" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -TargetAdminUpn "admin@orga.onmicrosoft.com" `
  -UseDeviceCode
```

What it does:

- creates target MailUsers if they do not already exist
- stamps `ExchangeGuid`
- stamps `ArchiveGuid` when present
- adds source `LegacyExchangeDN` as `x500`
- adds source `x500` addresses

Critical rule:

- this must happen before Exchange licensing is assigned

### Step 11: Assign target licenses in Org A

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase AssignTargetLicenses `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -LicenseSkuPartNumbers "SPE_E3","CROSS_TENANT_USER_DATA_MIGRATION" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UseDeviceCode
```

What it does:

- resolves SKU part numbers in Org A
- assigns licenses to each target user

Manual prerequisite:

- the target users must already exist in Entra ID

### Step 12: Add source users to the mailbox move scope group

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase AddUsersToSourceScopeGroup `
  -ConfigPath ".\Scripts\M365-UserMailbox-OneDrive-Migration\CrossTenantSetup.psd1" `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -UseDeviceCode
```

What it does:

- adds the migration users to the source published scope group

### Step 13: Validate the Exchange endpoint

Optional but recommended.

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Initialize-M365CrossTenantExchangeSetup.ps1 `
  -Phase ValidateTargetEndpoint `
  -ConfigPath ".\Scripts\M365-UserMailbox-OneDrive-Migration\CrossTenantSetup.psd1" `
  -TestMailbox "pilot.user@orga.onmicrosoft.com" `
  -UseDeviceCode
```

What it does:

- runs `Test-MigrationServerAvailability`

### Step 14: Create the mailbox migration batch in Org A

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase CreateMailboxBatch `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -MigrationEndpointName "OrgB-CrossTenant" `
  -BatchName "Wave01" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -UseDeviceCode
```

What it does:

- generates the mailbox batch CSV
- runs `New-MigrationBatch`

### Step 15: Start OneDrive moves from Org B

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase StartOneDriveMoves `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetCrossTenantHostUrl "https://orga-my.sharepoint.com/" `
  -UseDeviceCode
```

What it does:

- starts `Start-SPOCrossTenantUserContentMove` for each user

Optional timing inputs:

- `PreferredMoveBeginDateUtc`
- `PreferredMoveEndDateUtc`

### Step 16: Monitor completion

Manual monitoring:

- Exchange migration batch status in Exchange Online
- OneDrive move state in SharePoint Online

You can rerun validation later to read OneDrive move state when `TargetCrossTenantHostUrl` is provided.

### Step 17: Readdress source MailUsers in Org B for domain release

Run this only after mailbox moves complete and source recipients are now `MailUser`.

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase ReaddressSourceMailUsersForDomainRelease `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -SourceAdminUpn "admin@orgb.onmicrosoft.com" `
  -UseDeviceCode
```

What it does:

- verifies the source object is now a `MailUser`
- changes the source primary SMTP to the source `onmicrosoft.com` address
- sets `ExternalEmailAddress` to the target routing domain

Purpose:

- this frees the Org B custom domain so it can be removed from Org B

### Step 18: Perform manual domain cutover

Manual:

1. Confirm no remaining required Org B objects still use the custom domain.
2. Remove the domain from Org B.
3. Add and verify the domain in Org A.
4. Update DNS records for Org A mail flow.

### Step 19: Set final target SMTP addresses and optional UPNs in Org A

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveExecution.ps1 `
  -Phase SetTargetPrimaryAddresses `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -TargetAdminUpn "admin@orga.onmicrosoft.com" `
  -UpdateUserPrincipalNames `
  -UseDeviceCode
```

What it does:

- sets the final primary SMTP in Org A
- preserves secondary SMTP and non-SMTP addresses where appropriate
- optionally updates user UPNs to the final value from the CSV

### Step 20: Run final validation

Run:

```powershell
.\Scripts\M365-UserMailbox-OneDrive-Migration\Invoke-M365UserMailboxOneDriveValidation.ps1 `
  -SourceTenantAdminUrl "https://orgb-admin.sharepoint.com" `
  -TargetTenantAdminUrl "https://orga-admin.sharepoint.com" `
  -SourceTenantId "00000000-0000-0000-0000-000000000000" `
  -TargetTenantId "11111111-1111-1111-1111-111111111111" `
  -SourceAdminUpn "admin@orgb.onmicrosoft.com" `
  -TargetAdminUpn "admin@orga.onmicrosoft.com" `
  -MigrationCsvPath ".\Output\...\migration-prep-input.csv" `
  -CustomDomain "orgb.com" `
  -TargetDeliveryDomain "orga.mail.onmicrosoft.com" `
  -TargetCrossTenantHostUrl "https://orga-my.sharepoint.com/" `
  -UseDeviceCode
```

What it does:

- checks target mailbox presence
- checks target primary SMTP
- checks target OneDrive presence
- checks source object is now a `MailUser`
- checks source object no longer holds the custom domain
- checks source `ExternalEmailAddress`
- optionally reads OneDrive move state

Review:

- `target-validation.csv`
- `source-validation.csv`
- `source-custom-domain-dependencies.csv`
- `onedrive-state.csv`
- `issues.csv`

## Output Handling

Most scripts write a timestamped output folder under `.\Output`.

You should retain:

- readiness output for audit and planning
- mailbox batch result CSV
- OneDrive move submission CSV
- final validation output

## Common Stop Conditions

Do not continue if any of these are true:

- readiness shows mailbox hold blockers
- target already has user mailboxes provisioned for migration users
- OneDrive target already exists and is in active use
- source custom domain dependencies still include objects you intend to keep in Org B
- source mailbox migration has not completed but you are about to run source MailUser readdressing

## Recommended Pilot

Before running the full wave:

1. Put 2 users in the CSV.
2. Run the full sequence end-to-end.
3. Validate:
   - mailbox content
   - OneDrive content
   - source-to-target routing
   - domain release process
   - final target sign-in and SMTP behavior

Only then scale to the rest of the wave.
