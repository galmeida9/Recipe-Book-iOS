# Recipe Book operations

## Verified boundaries

The native iOS source is not yet an installable, device-tested application. On
2026-11-15 the official [Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)
was downloaded and locally text-extracted. Section 2.7 forbids installing, using
or running Apple software/services on non-Apple-branded computers. Another clause
expressly prohibits separately using Apple SDKs or attempting Apple software on
non-Apple hardware. The inspected document SHA256 was
`5E6BD16BCBA3DD591BDE1C57F7C6F19F08A194C84CDC54485C4660F90E2A26EC`.
No Apple SDK or Xcode binary was obtained or executed on Windows. WSL does not
remove the license restriction.

OpenFruit's inspected experimental `0.1.0-dev` Windows ZIP is 6,425,301 bytes,
but bootstrap downloads further tooling/SDKs. Its README explicitly says
extensions without matching authorized profiles are stripped, and app groups
require the owning team. This is not a verified build path for this app.
WinXcode and xtool are not a substitute for authorization or extension proof.

The checked-in `ios/RecipeBook.xcodeproj` is the actual project artifact;
`ios/project.yml` is supplementary metadata, not a Windows generator dependency.
The GitHub Actions native-source workflow is authorized for this foundation
branch on standard Apple-hardware macOS runners, with manual dispatch available.
Artifact upload is off by default. It can compile on the licensed host, but its unsigned
artifact is not an IPA, installation proof, or signing success. Do not dispatch
unapproved branches or paid/larger runners. Ordinary backend CI runs on Windows.
The workflow reports the actual installed SDKs/runtimes and includes a native
Simulator launch test of the explicit unconfigured-service state. This is
automated CI, not an interactive Windows preview or evidence of device signing.
The first corrected host run passed 3 Core Swift Testing checks, 15 presentation
XCTest checks, and the unsigned app/extension build using Xcode 26.6/iOS SDK
26.5. Its Simulator test initially failed because the extension built both
architectures while its package dependency built only the active architecture;
Debug now uses the standard active-architecture setting consistently. Run
`43752216145` subsequently passed all 3 Core tests, 15 presentation tests and
5 native Simulator tests (4 adapter checks plus unconfigured launch). Artifact
upload was skipped and the run has zero uploaded artifacts. The host's newest
installed Xcode was 26.6, so the guarded iOS 27-specific APIs remain uncompiled.
Simulator success does not prove signing, Google federation or iPhone operation.

## Local backend

Use Node 24 or newer. In PowerShell:

```powershell
npm.cmd --prefix backend ci --no-audit --no-fund
npm.cmd --prefix backend run check
```

Tests use bounded provider transport fixtures only; production always uses SQL,
validated OAuth access tokens and configured managed-identity storage. There is
no in-memory production fallback, mocked user or fabricated imported recipe.

SQL integration tests are explicitly gated by `RUN_SQL_INTEGRATION=true`,
`SQL_SERVER` and `SQL_DATABASE`, and a Microsoft identity with database access.
Apply `backend/sql/001-foundation.sql` to a dedicated empty test database first.
The schema is a versioned initial migration, not an idempotent startup script.
The test creates a unique test issuer, cleans up only its own seeded rows, and
checks isolation, stale writes, two-owner demotion races and account revocation.
Without SQL access these tests are reported skipped, not passed.
Real validation on the owned Sweden Central free database passed all 15 tests
with no skips. The deployed flags were read back before activity: free allowance
enabled, exhaustion AutoPause, minimum 0.5 vCore, 60-minute idle pause and 32 GiB.
The subscription spending limit was On, and temporary single-IP SQL access was
removed after the run. No Functions API or customer identity was exposed.

`scripts\Test-Foundation.ps1` also runs portable Swift tests when Swift is already
installed. Portable tests do not prove SwiftUI, extension capabilities or iPhone
installation. No SDK needs to be installed just to run TypeScript tests.

## Azure account and deployment gates

GitHub login is independent of Azure login. The verified native Windows CLI is
`C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd` (2.92.0 when installed).
This is **operator Azure administration**, not customer sign-in. Operator
Microsoft credentials/MFA are entered directly in Microsoft's browser/broker:

```powershell
& 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' login
& 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd' account list --all --output table
```

If no subscriptions appear, use the intended subscription's actual Directory
(tenant) ID from portal Overview for `login --tenant <tenant-id>`. Do not infer a
tenant from an email address. Select only the user-confirmed subscription:
`account set --subscription <subscription-id>`. Never print access tokens or
store the Azure authentication cache in this repository.

The user has authorized their Visual Studio Enterprise credit subscription for
the intended use. Microsoft's published benefit documentation generally limits
credits to individual dev/test; user authorization is not a verified published
exception. Check the actual subscription terms/offer, spending limit, permitted
services, selected region, SQL SKU, Flex Consumption support and complete monthly
estimate before any deployment. Never remove spending limits, upgrade billing,
or assume Azure credits cover Entra External ID/third-party usage.

`infrastructure/main.bicep` uses Flex Consumption Node 24, one maximum 512 MiB
instance with no always-ready instances, SQL General Purpose serverless Gen5
2 vCore/0.5 minimum/60-minute idle pause, private Blob containers, queues and a
user-assigned managed identity. SQL explicitly sets `useFreeLimit=true` and
`freeLimitExhaustionBehavior=AutoPause`; never omit these or fall back to
`BillOverUsage`. The initial free tier has 100,000 vCore-seconds and 32 GiB data
and backup allowances per month, with no SLA. Actual subscription capability
must be verified, and the post-deployment properties must confirm both settings.
The actual free offer rejected a 15-minute idle pause with `ProvisioningDisabled`
and requires the default 60 minutes, even though general serverless capabilities
advertise a 15-minute minimum. Database cold resume may take time; quota pauses are surfaced as unavailable,
not invented successful reads/writes.
No always-ready Functions instances, Application Insights paid retention,
automatic provider subscription, or paid upgrades are provisioned.
Template compilation does not prove subscription eligibility or deployment.

Deployment prerequisites:

- Explicit resource-group/region/cost authorization and a verified subscription.
- An Entra SQL administrator and a separate External ID consumer tenant/app/API.
- Disable External ID self-sign-up at the identity provider before exposure:
  verify the actual external tenant, application and user flow, use the Graph
  authenticationEventsFlow update with `isSignUpAllowed=false`, and read it back.
  Operator-controlled identity provisioning, combined tenant MAU billing and
  enforceable no-overage protection are separate prerequisites. A workforce AAD
  tenant or backend allowlist is not this proof. No SMS/M2M/premium features.
  The [Graph flow-update permission](https://learn.microsoft.com/en-us/graph/api/authenticationeventsflow-update?view=graph-rest-1.0)
  is `EventListener.ReadWrite.All`; delegated operation requires the External ID
  User Flow Administrator role or an appropriate higher role. Do not assume the
  Azure CLI's existing workforce sign-in has these consumer-tenant permissions.
- Exact hosted authorize/token URLs, issuer, JWKS URL, audience and delegated API
  scope from the tenant configuration; register `recipebook://oauth` as the
  native public-client callback and allow PKCE/offline access. No mobile secret.
- Approved Functions outbound SQL firewall addresses and operator IP, or
  separately approved private networking. The template deliberately does not
  open SQL to all Azure services. Apply schema and grant the API managed identity
  only required SELECT/INSERT/UPDATE/DELETE permissions via a contained SQL user.
- Code package deployment, queue/host identity permissions and startup checks.
- Populate non-secret mobile configuration keys; secrets stay in Key Vault.

## Google-only customer sign-in

Customers use **Google only**, not a Microsoft account, Apple sign-in or native
email/password authentication. The app opens the secure iOS system authentication
session with PKCE into the branded customer tenant's Google federation; Azure
still issues the API access token and persists the separate app account/data.
Do not accept a Google ID token as an API bearer token or infer app access from
an email claim. No customer identity provider has been configured or exposed yet.

The [official Google federation setup](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-google-federation-customers)
requires the operator to create a Google Cloud OAuth **web** client, configure
its exact customer-tenant federation redirect URIs, and enter its client ID and
secret directly in Entra External Identities > All identity providers > Google.
Select Google alone in the application's user flow; do not enable Microsoft,
Apple, email/password or SMS alternatives. The native mobile app remains a
separate public client with no client secret. No Google billing account, paid
API/product or provider enrollment is authorized by this source implementation.

Before exposure, verify actual no-cost OAuth eligibility, the associated
customer flow's disabled self-sign-up readback, and controlled provisioning of
the invited social identity. Test that the intended existing Google identity
can sign in for the first time while an unknown Google identity cannot create
an account. Disabling sign-up can also reject an unprovisioned legitimate social
identity; a backend invite alone does not solve this. Any provider identity
mapping must use the verified stable subject, never an unverified email.
Combined customer-tenant MAU usage and enforceable no-overage protection still
require live verification before the API is exposed.

## Account access and ownership

Operators issue access invitations bound to the **verified immutable OIDC issuer
and subject**, with expiration/revocation. Access invitations and book membership
are distinct. No email claim automatically enrolls an account. Authenticated identities receive a pending internal UUID before app access,
so they can request an operator invitation without seeing product data. Owners add active invited
accounts by this UUID; users can set a display name.

All writes use SQL serializable transactions. Book mutations lock the parent
book before checking roles/members/recipes. Last-owner demotion, leaving and
account deletion cannot auto-promote another member. Shared-book owners must
first explicitly promote another owner, or explicitly delete the book.
Client adapter multi-step resolutions are not a substitute for the server's
per-transaction invariant; concurrent edits remain detectable through If-Match.

Members see all book recipes but edit/delete only their own contributions.
Owners manage all contributions and membership. Missing membership returns
not-found, including after revocation. Shopping lists and import jobs are scoped
to the caller. Deleted accounts keep an inactive identity tombstone for shared
authorship; a broader privacy/retention policy is required before public operation.
Recipe image bytes are proxied only after current membership authorization;
no persistent public URLs/SAS tokens can survive revocation. Blob metadata must
match bounded content size/type. Image ingestion is not yet a product API.

## Import provider approval and cost safety

Imports are **disabled by default**. No actor has been selected, output-guaranteed
or exercised against a real account. Apify MCP is not a runtime dependency.
Before enabling, verify the actor's license, public-Reel access, pinned build,
input shape, caption/comments/transcript fields, response sizes and actual prices.
Captions/transcripts are not assumed available; missing evidence fails visibly.

Server-only settings:

| Setting | Requirement |
| --- | --- |
| `APIFY_ENABLED` | Explicit `true` only after review |
| `APIFY_FREE_PLAN_VERIFIED` | Verified shared USD 5 allowance |
| `APIFY_NO_OVERAGES_VERIFIED` | Free-plan spending/overage limit remains enabled |
| `APIFY_ACCOUNT_EXCLUSIVE` | No independent charged jobs outside this backend budget |
| `APIFY_TOKEN` | Key Vault reference, never app/repo/chat |
| `APIFY_ACTOR_ID`, `APIFY_ACTOR_BUILD` | Reviewed actor and pinned numeric build |
| `APIFY_RUN_CAP_MICROS` | Approved hard run cap, at most USD 1 |
| `APIFY_INPUT_URL_FIELD` | Reviewed top-level field accepting a URL array |
| `APIFY_OUTPUT_CAPTION_FIELD` | Optional reviewed top-level string field |
| `APIFY_OUTPUT_COMMENTS_FIELD` | Optional reviewed top-level array of strings |
| `APIFY_OUTPUT_TRANSCRIPT_FIELD` | Optional reviewed top-level string field |

The provider adapter sends `maxTotalChargeUsd`, `maxItems=1`, timeout 300 seconds,
no restarts and limited permissions. The current
[Apify API documentation](https://docs.apify.com/api/v2/actors-runs-post)
states that maxTotalChargeUsd caps all pricing models; verify the actual selected
actor confirms this cap. The adapter refuses an unconfirmed cap.

The backend checks account monthly-cycle usage, reserves all in-flight spending
transactionally across app accounts and uses a conservative USD 4.75 ceiling,
leaving USD 0.25 for bounded storage/reads. Job settlement counts the full
reservation as spent, even when actual costs were lower. This can exhaust the
app budget early by design; it never silently charges additional credits.
Account-wide free spending controls must remain enabled: a local ledger cannot
prevent unrelated external jobs or unlimited provider storage charges.

Idempotency keys are persisted separately from canonical-URL deduplication.
Duplicate submissions in the same billing cycle reuse the job. Charged dispatch
intent is committed before the POST; unknown outcomes never trigger a second POST.
Jobs have ten-minute deadlines; each active job schedules its next bounded queue
delivery after 30 seconds. There is no global SQL polling timer to prevent idle
database pause. SQL persistence precedes delivery; if initial delivery fails,
the API returns an explicit recoverable error and retrying the same idempotency
key repairs delivery without another reservation/charged POST. Duplicate queue
deliveries poll an existing run. Poison messages visibly fail the persisted job.
Deliveries carry the attempt's immutable deadline: stale deliveries, poison
messages and completion callbacks cannot affect a later pre-dispatch retry.
Authenticated import reads/submissions reconcile at most three overdue jobs,
so an expired queue message or a quota outage cannot leave jobs queued forever.
This occurs only during actual requests, never through an idle database timer;
dispatched runs retain their hard provider timeout/cap and are never restarted.
Unsafe failed jobs cannot be retried. A pre-dispatch failure can retry only with
a new reservation and approved configuration. Evidence is preserved for manual
review; only explicitly labelled sections are parsed. Unknown amounts/servings
remain null, not guessed. Approval saves to an explicitly chosen accessible book.

## Required device gate

Before calling the app functional, verify an actual signed device build with:
app and extension executables intact; authorized provisioning profiles for both
bundle IDs; matching app-group entitlements owned by the team; valid signatures;
and no stripped extension after any re-sign operation.
`scripts\Verify-Ipa.ps1` verifies only archive layout and both embedded profiles,
not cryptographic validity or capabilities.

The [current SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
support Windows for initial installation and require Wi-Fi plus LocalDevVPN.
The [free-account limits](https://docs.sidestore.io/docs/faq) are three active
apps including SideStore, ten App IDs per week and seven-day renewal. Keep the
share extension; do not use extension-removal or limit-bypass options. Group IDs
can change during re-signing, so confirm the group's runtime configuration still
matches both signed targets before testing share delivery. An unchanged original
Info.plist value alone does not prove a usable re-signed app group.
Both native targets now use `SharedAppGroup.current()`: it reads the loaded
target's bounded thin-64 Mach-O XML entitlement metadata, matches only the
original group or its signed ten-character team suffix, rejects ambiguity, and
requires iOS to authorize the actual container. This uses Foundation/public file
formats, not private entitlement APIs or a third-party signer dependency.
Unsupported/missing signature metadata fails explicitly; it is not proof of
cryptographic profile validity or a substitute for real re-signing tests.

Trial delivery remains gated on usable auth/API configuration and an approved
bounded package. Artifact upload is opt-in with one-day retention; verify the
GitHub account's shared artifact-storage headroom and spending controls plus the
actual archive size before enabling it. A free public macOS runner does not
prove that artifact storage has an enforceable zero-overage cap.
An explicit `-RecipeBookFixtureShowcase <screen>` launch flag selects the Opus
fixture harness only in DEBUG Simulator builds. Release/device builds exclude
the entry point. Every screen discloses that no live backend/Google sign-in is
connected; external actions fail rather than pretend to succeed. Native XCTest
captures sign-in, library, recipe detail and shopping locally in its result
bundle, with PNG exports bounded to 10 MiB. Exports are not uploaded while the
account storage cap/headroom gate remains unverified.
Native run `43755557279` at `4d90d4e` passed on Xcode 26.6: five Core
tests (including group-resolution/metadata cases), fifteen presentation tests,
and six native tests including the four-screen capture. The unsigned device
app retained its share extension. The local export produced exactly four PNGs,
787,255 bytes combined; the run uploaded zero artifacts. These ephemeral runner
images were not transferred to the user. Capture must run again after verified
storage-cap/headroom approval before screenshots can be retained and shown.

On the actual iPhone, test launch, hosted sign-in/PKCE callback, invite rejection,
private/shared isolation, promotion/demotion/last-owner errors, image/data
revocation, concurrent writes, paste and Instagram native share, offline/errors,
review/save, shopping quantity/bought/already-have behavior, and SideStore
free re-signing plus on-device refresh. Verify whether the free signing team
actually authorizes the required app group/extension capabilities. Do not silently
replace the native share requirement if it does not. A simulator, web preview,
unsigned archive or Windows compilation claim is not this proof.
