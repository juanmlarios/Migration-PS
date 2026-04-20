# Microsoft 365 Tenant Migration Runbook

As of April 17, 2026, this runbook is aligned to Microsoft's current documented cross-tenant guidance for commercial tenants.

## Scope

- Source: Org B
- Target: Org A
- User scope: subset of about 10 mailboxes
- Tenant type: commercial Microsoft 365
- Identity type: cloud-only
- Objective:
  - license the migrated users in Org A
  - keep the Org B custom domain as the users' primary SMTP domain after cutover
  - preserve Exchange Online mailboxes
  - preserve OneDrive
  - migrate all SharePoint sites in Org B
  - rebuild Teams in Org A and reconnect them to migrated SharePoint and Microsoft 365 Group resources
- Accepted constraints:
  - Org B custom domain can be removed from Org B and added to Org A
  - guest users, external sharing links, and shared channels are not in scope
  - no current legal hold, litigation hold, retention block, or Customer Key blockers were reported
  - minimal end-user downtime is more important than simplest cutover

## Executive Decision

Use a split migration pattern:

1. Exchange Online mailbox migration: Microsoft native cross-tenant mailbox migration.
2. OneDrive migration: Microsoft native cross-tenant OneDrive migration.
3. SharePoint migration: Microsoft native cross-tenant SharePoint migration for all site collections.
4. Teams and Microsoft 365 Groups:
   - precreate target Microsoft 365 Groups and Teams in Org A
   - migrate the connected SharePoint content into the target group-connected sites
   - rebuild Teams configuration in Org A
   - preserve message history only through a separate Teams-specific path
5. Custom domain:
   - keep users on `@orga.onmicrosoft.com` during pre-staging
   - move the Org B custom domain only at final cutover
   - then switch target primary SMTP addresses to the moved domain

This gives the shortest realistic downtime while staying close to Microsoft-supported paths for mail, files, and sites.

## What Microsoft Natively Supports

### Exchange Online

Supported:

- cross-tenant mailbox moves initiated from the target tenant
- user-visible mailbox content: email, contacts, calendar, tasks, notes
- source mailbox converts to a MailUser for coexistence and forwarding
- mailbox permissions stored in the mailbox can move when both users move together

Key limits:

- mailboxes on any hold are blocked
- Teams chat folder content does not migrate as part of mailbox move
- source mailbox is deleted after successful migration
- cross-tenant mailbox and calendar permissions are not supported across tenants; move connected delegates together

References:

- [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)

### OneDrive

Supported:

- cross-tenant content move using SharePoint Online PowerShell
- permissions retained when identities exist in the target mapping
- redirect left behind on source
- existing sharing links redirect to the new location

Key limits:

- one-time move only, no incremental or delta passes
- target OneDrive must not already exist
- OneDrive accounts on hold are blocked
- max 5 TB or 1 million items per OneDrive

References:

- [Cross-tenant OneDrive migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration?view=o365-worldwide)

### SharePoint

Supported:

- group-connected sites, including sites associated with Teams
- modern, classic, and communication sites
- documents, versions, permissions, basic metadata, sharing links

Key limits:

- no incremental or delta pass pattern documented for cross-tenant content move
- max 5 TB or 1 million items per site
- workflows, apps, Power Apps, and automation tasks do not migrate
- labels removed before migration must be manually re-added later

References:

- [FastTrack cross-tenant migration](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/cross-tenant-migration)
- [SharePoint migration step 6](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-sharepoint-migration-step6?view=o365-worldwide)
- [SharePoint migration step 7](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-sharepoint-migration-step7?view=o365-worldwide)

### Teams and Microsoft 365 Groups

Important distinction:

- Microsoft documents SharePoint group-connected site migration.
- Microsoft does not document a full native tenant-to-tenant migration of Teams as a workload in the same way as Exchange, OneDrive, or SharePoint.
- FastTrack cross-tenant migration explicitly excludes Microsoft Teams and Microsoft 365 Groups.

What this means operationally:

- treat Team shell, tabs, apps, settings, Planner, and Group mailbox/calendar as rebuild or third-party/custom migration scope
- treat SharePoint content behind those Teams as migratable

References:

- [FastTrack cross-tenant migration](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/cross-tenant-migration)

## Teams History Preservation Strategy

There are two realistic options.

### Option A: Third-party migration tool

Use a proven tenant-to-tenant Teams migration product for:

- Teams/channel structure
- channel posts
- chat history where supported by the tool
- tabs, apps, and some Teams settings

This is the lowest-risk route for preserving user experience.

### Option B: Custom export/import workflow

This is possible, but it is engineering work, not a turnkey Microsoft tenant migration feature.

Microsoft currently documents:

- export APIs for Teams messages
- beta migration APIs to import historical messages into existing chats and channels

Important cautions:

- the import path is documented as migration of external messages
- parts of the migration mode workflow remain under Microsoft Graph `beta`
- meeting chats are not supported by the chat migration mode API

Recommended interpretation:

- channel post preservation via custom tooling is possible but should be treated as a custom migration project
- 1:1 and group chat preservation may be technically possible for some scenarios, but it is not the same as a Microsoft-supported tenant-to-tenant Teams migration runbook
- meeting chat preservation should be treated as not supported for this project unless a third-party tool proves otherwise

References:

- [Export content with the Microsoft Teams Export APIs](https://learn.microsoft.com/en-us/microsoftteams/export-teams-content)
- [Import third-party platform messages to Teams using Microsoft Graph](https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/import-messages/import-external-messages-to-teams)
- [chat: completeMigration (beta)](https://learn.microsoft.com/en-us/graph/api/chat-completemigration?view=graph-rest-beta)

## Custom Domain Strategy

This is the critical design constraint.

- the Org B custom domain can exist in only one tenant at a time
- you cannot keep it active in Org B while also assigning it in Org A
- therefore, pre-stage users in Org A with `@orga.onmicrosoft.com`
- cut over mailboxes and services
- remove the custom domain from every dependency in Org B
- add and verify the domain in Org A
- then switch primary SMTP addresses in Org A to that domain

Because you said Org B can eventually be decommissioned, this is the correct pattern.

References:

- [Remove a domain from Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/admin/get-help-with-domains/remove-a-domain?view=o365-worldwide)
- [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)

## Migration Phases

### Phase 0: Discovery and Assessment

Run:

- readiness inventory script
- domain dependency discovery script

Outputs required:

- mailbox inventory and size baseline
- OneDrive inventory
- SharePoint site inventory for all Org B sites
- Teams and Microsoft 365 Group inventory
- domain dependency list showing every Org B object using the custom domain
- cutover wave list for the 10 users

### Phase 1: Target Tenant Preparation

In Org A:

1. Acquire and assign the required Microsoft 365 base licenses.
2. Acquire Cross-Tenant User Data Migration licenses for mailbox and OneDrive moves.
3. Create the 10 target users with `@orga.onmicrosoft.com` UPNs.
4. Assign Exchange Online, SharePoint, OneDrive, and Teams entitlements.
5. Precreate required security groups and Microsoft 365 Groups.
6. Precreate target Teams that will own the rebuilt collaboration spaces.
7. Do not let target OneDrive sites auto-provision before migration.

### Phase 2: Exchange Setup

Configure per Microsoft cross-tenant mailbox guidance:

1. In Org A, create the Entra app and secret for mailbox migration.
2. Grant `Mailbox.Migration` application permission.
3. In Org B, consent to the app.
4. Create the target migration endpoint in Exchange Online PowerShell.
5. Create organization relationships in both tenants.
6. Prepare target MailUsers with:
   - `ExchangeGUID`
   - `ArchiveGUID` if needed
   - source `LegacyExchangeDN` as `x500`
   - all source `x500` proxies
   - target-side proxy using the `TargetDeliveryDomain`

Operational note:

- because you want minimal downtime, pre-stage mail sync early and complete cutover close to the domain move window

### Phase 3: OneDrive and SharePoint Setup

In both tenants:

1. Install the latest SharePoint Online Management Shell.
2. Connect to source and target SPO admin endpoints.
3. Exchange cross-tenant host URLs.
4. Establish trust with `Set-SPOCrossTenantRelationship`.
5. Verify trust returns `GoodToProceed`.
6. Verify compatibility with `Get-SPOCrossTenantCompatibilityStatus`.
7. Precreate users, groups, and Microsoft 365 Groups in Org A.
8. Upload identity mapping files to the target tenant.

For OneDrive:

- run `Start-SPOCrossTenantUserContentMove`

For SharePoint:

- run `Start-SPOCrossTenantSiteContentMove` for standalone sites
- run `Start-SPOCrossTenantGroupContentMove` for group-connected sites

### Phase 4: Teams and Group Reconstruction

Because native tenant-to-tenant Teams migration is not the primary Microsoft-supported path here, use this sequence:

1. Precreate target Microsoft 365 Groups in Org A.
2. Precreate Teams in Org A tied to those groups.
3. Migrate the connected SharePoint site content into those target group-connected sites.
4. Recreate:
   - channels
   - tabs
   - apps
   - policies if needed
   - team membership
5. Preserve history using one of:
   - third-party Teams migration tool
   - custom Graph export/import project

Recommendation:

- use third-party tooling for Teams history if preserving it is truly important
- do not make the entire runbook depend on a custom beta Graph migration workflow unless you are prepared to test and support it as a software project

### Phase 5: Pilot

Pilot 2 users and at least:

- 1 mailbox with delegates or shared access
- 1 OneDrive with meaningful sharing structure
- 1 standalone SharePoint site
- 1 Team with group-connected SharePoint site

Success criteria:

- mail flow works before and after domain cutover
- OneDrive redirect works
- SharePoint permissions and versions survive
- target Teams shell is usable
- target domain can be assigned cleanly

### Phase 6: Production Cutover

Recommended order for the final event:

1. Freeze change window.
2. Confirm no unresolved readiness blockers.
3. Complete final mailbox wave for the 10 users.
4. Complete final OneDrive moves for the 10 users.
5. Complete final SharePoint site moves.
6. Verify source-to-target mail routing still works using `onmicrosoft.com`.
7. Remove the Org B custom domain from every remaining object in Org B:
   - users
   - aliases
   - shared mailboxes
   - groups
   - Teams-connected groups
   - contacts
   - admin sign-in names
8. Remove the domain from Org B.
9. Add and verify the domain in Org A.
10. Update target users and groups so the migrated custom domain becomes primary.
11. Recreate or reconnect Teams and Microsoft 365 Groups in Org A.
12. Repoint DNS:
   - MX
   - Autodiscover
   - SPF
   - DKIM
   - DMARC as applicable
   - Teams-related records if applicable
13. Run post-migration validation script.

## Readiness Checklist

Before production, verify all of the following:

- both tenants are commercial and supported
- source mailboxes are not on hold
- source OneDrives are not on hold
- source SharePoint and OneDrive are read/write
- source does not use Purview Customer Key for SPO/OneDrive migration scope
- target users exist
- target licenses exist
- target OneDrive sites do not already exist
- identity mapping file is complete
- SharePoint trust is `GoodToProceed`
- SharePoint compatibility is `Compatible` or `Warning`
- Exchange migration endpoint exists
- Exchange organization relationships exist on both sides
- target MailUsers are stamped correctly
- all objects using the Org B custom domain are inventoried for later removal

## Post-Migration Validation Checklist

After cutover, verify:

- each migrated user can sign in to Org A
- each migrated user has correct license set
- mailbox exists and primary SMTP uses the moved custom domain
- mailbox item count is reasonable versus baseline
- OneDrive target exists
- OneDrive source redirect exists
- all SharePoint sites exist in Org A
- group-connected sites are attached to the intended Microsoft 365 Groups
- Teams exist in Org A and memberships are correct
- target DNS is authoritative and mail routing is stable
- no remaining objects in Org B reference the moved domain

## Unsupported or Limited Areas and Mitigations

### Microsoft Teams workload

Status:

- no straightforward Microsoft-native tenant-to-tenant migration runbook for the full Teams workload

Mitigation:

- rebuild Teams shell in Org A
- preserve SharePoint site content natively
- use third-party tool for Teams history if required
- if you insist on custom tooling, treat Teams export/import as a separate engineering stream and test the beta Graph migration APIs thoroughly

### Microsoft 365 Groups as full objects

Status:

- current Microsoft documentation reviewed here requires pre-creating groups on the target and does not present a complete native move of all Microsoft 365 Group resources as one atomic tenant-to-tenant operation

Mitigation:

- precreate target groups
- migrate connected SharePoint content
- rebuild Team binding and non-SharePoint group resources

### Group mailbox and group calendar

Status:

- I did not find a Microsoft-native cross-tenant move pattern in the current official docs reviewed for Microsoft 365 Group mailbox content itself

Mitigation:

- treat as rebuild or third-party/custom migration scope
- if the mailbox/calendar history is business-critical, validate a third-party product in pilot before production

### Teams chat history

Status:

- Exchange cross-tenant mailbox move does not move Teams chat folder content
- export is available, import path is custom and partially beta

Mitigation:

- best path: third-party Teams migration
- fallback path: export for archive/compliance and start fresh in target

### SharePoint workflows, apps, Power Apps, automation

Status:

- not supported in native SharePoint cross-tenant content move

Mitigation:

- inventory these items during readiness
- rebuild in Org A
- test dependencies before cutover

### Domain coexistence

Status:

- impossible to keep the same custom domain verified in both tenants at once

Mitigation:

- pre-stage on `onmicrosoft.com`
- perform final domain move during cutover window

## Scripts Included With This Runbook

- [Invoke-M365MigrationReadiness.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-Tenant-Migration/Invoke-M365MigrationReadiness.ps1)
- [Find-DomainDependencies.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-Tenant-Migration/Find-DomainDependencies.ps1)
- [Invoke-M365PostMigrationValidation.ps1](/Users/juan/GitHub/SecureLift-Research/Scripts/M365-Tenant-Migration/Invoke-M365PostMigrationValidation.ps1)

## Next Recommended Step

Run the readiness and domain dependency scripts in Org B first. That will tell you:

- exact mailbox counts and blockers
- exact SharePoint and OneDrive scope
- every object that must release the Org B custom domain
- which Teams and Microsoft 365 Groups need to be rebuilt or migrated with third-party tooling

## Source Notes

Primary Microsoft sources used:

- [Cross-tenant mailbox migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-mailbox-migration?view=o365-worldwide)
- [Cross-tenant OneDrive migration](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration?view=o365-worldwide)
- [OneDrive step 3](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step3?view=o365-worldwide)
- [OneDrive step 6](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step6?view=o365-worldwide)
- [OneDrive step 7](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-onedrive-migration-step7?view=o365-worldwide)
- [SharePoint step 3](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-sharepoint-migration-step3?view=o365-worldwide)
- [SharePoint step 6](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-sharepoint-migration-step6?view=o365-worldwide)
- [SharePoint step 7](https://learn.microsoft.com/en-us/microsoft-365/enterprise/cross-tenant-sharepoint-migration-step7?view=o365-worldwide)
- [FastTrack cross-tenant migration](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/cross-tenant-migration)
- [Remove a domain from Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/admin/get-help-with-domains/remove-a-domain?view=o365-worldwide)
- [Cross-tenant synchronization overview](https://learn.microsoft.com/en-us/entra/identity/multi-tenant-organizations/cross-tenant-synchronization-overview)
- [Teams Export APIs](https://learn.microsoft.com/en-us/microsoftteams/export-teams-content)
- [Import historical messages to Teams](https://learn.microsoft.com/en-us/microsoftteams/platform/graph-api/import-messages/import-external-messages-to-teams)

Where this runbook marks an item as "treat as rebuild or third-party/custom scope," that is an inference from the absence of a complete Microsoft-native tenant-to-tenant move path in the official docs reviewed above, combined with Microsoft's explicit exclusions for Teams and Microsoft 365 Groups in the FastTrack service documentation.
