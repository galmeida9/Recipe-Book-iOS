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
Simulator success does not prove signing, live Google authentication or iPhone operation.

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

## Weekly planner API

Apply `backend/sql/004-planner.sql` before enabling the planner routes or shopping
reads in this backend version. Recipe drafts accept an explicit nullable
`mealStyle`: `simple`, `complicated` or `full`; legacy drafts default to null.
No category is inferred from duration.

All planner endpoints require the existing authenticated account/invitation gate.
`weekStart` is a Monday date-only `yyyy-MM-dd`; slots use recipe references from
the selected accessible book, with no stored title/image snapshots.

| Method and path | Request | Result |
| --- | --- | --- |
| `GET /plans?bookId=UUID&weekStart=yyyy-MM-dd` | No body | Stored plan result, or JSON null |
| `POST /plans` | `{bookId,listId,weekStart,dayStyles}`; seven nullable styles, Monday first | Generated/reconciled plan |
| `PATCH /plans?bookId=UUID&weekStart=yyyy-MM-dd` | `{date,replacement:{recipeId,recipeVersion,servings}}`; replacement may be null | Replaced, serving-adjusted or cleared slot |
| `DELETE /plans?bookId=UUID&weekStart=yyyy-MM-dd` | No body | `{removed:true}` |
| `PATCH /plans/items/UUID?bookId=UUID&weekStart=yyyy-MM-dd` | `{bought:boolean}` | Updated generated check state |

Use the plan's numeric `If-Match` version for every mutation of an existing plan;
omit it only on first generation. `servings` is null only when the recipe's normal
yield is unknown; otherwise send the normal or user-selected positive serving
count. Quantity increases reset generated bought checks; compatible equal/reduced
amounts preserve checks. Unknown quantities or unsupported units preserve checks
only when both ingredient and full contribution provenance are unchanged.

Shopping responses keep user rows in `items` and return automatic rows separately
in `generated`, an array of `{planId,bookId,weekStart,planVersion,items}` sections.
Every shopping read revalidates membership and current recipe versions in the
same transaction, removes stale/inaccessible generated ingredients, then rereads
the final list version. Manual rows, quantities and bought checks are not changed.
Account deletion removes owned plans before tombstoning the account.

The bounded SQL planner test is separately gated by
`RUN_PLANNER_SQL_INTEGRATION=true`; run only
`node --import tsx --test test/planner.sql.integration.test.ts` from `backend`
against the explicitly owned database, with `RUN_SQL_INTEGRATION` unset. Ordinary
`npm run check` uses local fixtures and skips both live SQL suites.

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
or assume Azure credits cover third-party usage.

`infrastructure/main.bicep` uses Flex Consumption Node 24, maximum one 512 MiB
instance **per independently scaling function group** (HTTP and queue groups can
each have an instance), with no always-ready instances. This is not an app-wide
single-instance or monetary cap; subscription spending limits and import
reservations remain mandatory. See the [Flex maximum-instance documentation](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan#maximum-instance-count-the-ceiling).
SQL uses General Purpose serverless Gen5
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
- An Entra SQL administrator for workload access, not customer authentication.
- One central Google Web OAuth client and server-only secret in the existing
  vault. Configure `GOOGLE_SERVER_CLIENT_ID` and the vault reference for
  `GOOGLE_OAUTH_CLIENT_SECRET`.
  No CIAM directory, trial, delegated API scope, customer MAU service or Google
  client secret is used.
- Approved Functions outbound SQL firewall addresses and operator IP, or
  separately approved private networking. The template deliberately does not
  open SQL to all Azure services. Apply schema and grant the API managed identity
  only required SELECT/INSERT/UPDATE/DELETE permissions via a contained SQL user.
- Code package deployment, queue/host identity permissions and startup checks.
- Populate non-secret mobile configuration keys; secrets stay in Key Vault.

## Google-only customer sign-in

Customers use **Google only** through AppAuth 2.0.0's native system-browser flow
and the official `google-auth-library` server broker. There is **one owner-managed
Web OAuth client for everyone**, not an iOS client/project per friend or signing
team. The coordinator selected this fix for the rejected per-team setup; no
separate user architecture approval is claimed. No passwords, app-issued JWTs,
CIAM trial/MAU service, Firebase/Identity Platform or paid Apple membership.

AppAuth owns OAuth state, nonce, S256 PKCE and secure-session serialization. The
HTTPS server callback binds Google's short authorization code to the native
challenge/nonce in `dbo.OAuthFlows`; it returns only code/state through the stable
`recipebook://oauth` scheme, never tokens. Code bindings expire after 90 seconds
and are atomically consumed before the official library's token exchange.
At most 100 ten-minute login flows exist; expired rows are reclaimed on demand.
Google credentials travel only in HTTPS responses and refresh state is stored
in device-only Keychain. The Web client secret stays in the vault/backend.
The
Google **ID token**, not its Google-services access token or plain user ID, is
sent as the existing HTTPS API bearer credential. The established `jose`
verifier uses Google's fixed HTTPS rotating-key endpoint and RS256, requires the
exact central Web audience (and the same authorized party when supplied), issuer,
stable numeric subject, issued/expiry times and a maximum one-hour token lifetime.
Both documented Google issuer spellings map to `https://accounts.google.com`.
Email/name claims never create membership or link identities. Key-service
unavailability is a visible 503, not a false invalid-login response.

**Exact human setup:** open https://console.cloud.google.com/auth/overview,
select/create an unbilled project, configure Recipe Book branding/support contact
and External audience in Testing, and add the intended trial Google accounts as
test users. Request only basic OpenID/profile/email scopes. In Clients create
one **Web application** client with authorized redirect:
`https://recipe-api-nb2yqx3agzmou.azurewebsites.net/api/auth/google/callback`.
Supply only its public client ID. Put its secret directly in Azure Portal >
the existing `recipe-kv-nb2yqx3agzmou` vault > Secrets > Generate/Import >
`google-oauth-client-secret`. Never put the secret in chat/CI/the phone/repo.
The owner may need vault-scoped **Key Vault Secrets Officer** to enter it;
the Function identity already has **Key Vault Secrets User**.
Google's server setup: https://developers.google.com/identity/protocols/oauth2/web-server ;
backend-token requirements: https://developers.google.com/identity/sign-in/ios/backend-auth .

The mobile build needs only `RECIPEBOOK_API_URL` and its existing stable callback.
It fetches the public Web client ID from `/auth/google/config`; there is no
Google client secret or signed-bundle OAuth registration in the mobile bundle.
Pinned SideStore `4f3d18d` preserves existing URL schemes except its own
`sidestore-*` entries, even when changing CFBundleIdentifier. Keep App Groups,
application identifier and Keychain authorization intact for share/refresh.
Real device callback/group verification remains required.

Unknown Google users may authenticate with Google, but cannot access books,
recipes, images, imports or shopping. Their pending app UUID is unique per
canonical issuer/subject and capped at 100 live inactive accounts globally under
SQL serializable locks. Full capacity fails visibly; invited first sign-ins
bypass pending capacity. This is not creation of an app-owned IdP identity.
Operators must verify the stable Google subject before issuing an invitation;
Google Console test-user access is a separate gate, not a book/app invitation.

Local sign-out clears Keychain credentials; it cannot invalidate a previously issued
Google bearer token before its expiry. Every data operation still checks the live
SQL invitation and account tombstone, so invitation revocation/account deletion
denies even an unexpired token. Late restore/sign-in callbacks cannot revive a
signed-out session or overwrite a newer one. Real Console consent/login, Keychain
restore, callback routing and SideStore refresh remain physical-device gates.
Historical native-client run `43758846685` at `d568f7a` passed SDK compilation,
seven Core tests, fifteen presentation tests and eleven native tests (five
Google configuration/restore/sign-out race cases). The expanded actual SQL run
passed all sixteen tests with zero skips, including repeated pending identity,
invited first login, unknown denial, revocation/deletion and a concurrent
100-pending-account boundary. The temporary operator firewall was removed.
That native-client checkpoint is preserved in Git, but its per-team Google
registration instructions are superseded by the central Web broker.

## Private installation-check delivery

An installation-check IPA is explicitly **not a usable authenticated trial**.
Its DEBUG bootstrap displays the actual signed bundle ID and shared-group
authorization result without connecting to Google/the API. This lets SideStore
signing and Google iOS registration proceed while cloud configuration is finished.
Keep the embedded share extension; unsupported profiles remain a visible gate.

Only a manual standard-macOS build may upload this unsigned package (maximum
64 MiB) and its SHA256 file to a verified, existing **draft** release tied to the
exact source commit. It contains no provisioning profiles/signing keys. No
public release, Actions artifact, IPA log payload or paid runner is used.
GitHub documents each release asset below 2 GiB with no total/bandwidth limit:
https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases .
Only push-access users can list drafts:
https://docs.github.com/en/rest/releases/releases .
The account creates the draft because GITHUB_TOKEN cannot create releases whose
target changes workflows; the manual job only uploads to the guarded existing
draft, with scoped contents-write permission and no overwrite.

The owner signs into GitHub in Safari, downloads the draft IPA to Files, then
imports that local file into SideStore. A draft URL is not a public SideStore
download URL; do not embed GitHub tokens or make the release public. SideStore
handles the user's Apple login/signing locally. Verify both profiles/entitlements
after re-signing and test the device; an unsigned layout or Simulator pass is
not installation proof. `Verify-Ipa.ps1 -UnsignedInstallationCheck` checks only
the explicitly named unsigned diagnostic; normal verification still requires
both profiles and subsequent cryptographic/device checks.
Private draft `446357525`, built by run `43760393301` in 2m7s at `a1b21f7`,
contains a 2,246,152-byte unsigned diagnostic IPA. SHA256:
`18be88ace0dae20de5a181453a8edff5335eb69d0e296e14bfc6a3a2e7050cff`.
Authenticated download and read-only ZIP inspection confirmed the retained app/
extension, no profiles or signing keys, and matching checksum. The anonymous
asset returned 404; draft/published flags and zero Actions artifacts were read
back. Windows execution policy blocked running the verification PS1 directly;
no policy was changed or bypassed. Equivalent ZIP inspection used supported
interactive .NET APIs.

## Closed core provisioning

`main.bicep` defaults the API to `publicNetworkAccess=Disabled`, leaves unknown
Google IDs empty (never fabricated), and explicitly has no always-ready instances.
`existingSqlServerName` reuses the verified owned free database without changing
the server/admin/schema. New owned Flex/identity/storage resources remain under
the subscription's read-back credit hard-stop; no premium plan/NAT gateway/private
endpoint is added.
The fresh Flex subnet is delegated first; `enableSqlServiceEndpoint=true` then
adds only that subnet's SQL service-endpoint rule. Service endpoints have no
additional charge and regional VNet integration supports endpoint-secured data
services: https://learn.microsoft.com/en-us/azure/azure-functions/functions-networking-options .
Verify actual provider acceptance and network/identity behavior; never substitute
an entire data-center/Allow-Azure-services firewall or a paid network fallback.
The workload SQL user must use the managed identity's **client ID** as its
binary SID/TYPE=E, not its object ID, per Microsoft's CREATE USER guidance.
Grant only dbo SELECT/INSERT/UPDATE/DELETE, not database owner/DDL/Graph roles.
Deployment ZIPs must use `/` entry separators even when packaged on Windows.
Windows PowerShell 5 `Compress-Archive` produced backslash entries that are not
valid Linux module paths; use `ZipArchive.CreateEntry` with normalized names (or
a supported POSIX packager), and verify `host.json`, `package.json` and
`dist/functions.js` at their exact paths before deployment. A successful file
upload is not proof that the Functions host indexed its handlers.
Owned closed core provisioning is real: Node 24, maximum one 512-MiB on-demand
instance per group, no always-ready instances and `APIFY_ENABLED=false` were
read back. The SQL subnet rule is Ready and the workload user has only CONNECT
plus dbo CRUD. A temporary administrative-only read probe executed on the
actual Function and returned `principal=recipe-api-identity`,
`sqlReadSucceeded=true`; it was disabled immediately afterward and operator
access removed. A leading-dot SQL environment suffix originally caused a
double-dot DNS name; source/live hostname are corrected. This is actual managed-
identity/network SQL proof, not customer Google login or native callback proof.
Central Web broker checkpoint `34f6ffe` passed hosted AppAuth compilation and
the expanded eighteen-test real SQL suite, including nonce/PKCE/code-expiry/
single-use races. Owner Web client/vault-secret configuration and physical
callback/account checks are still required before opening the core trial.
App Group resolution is deferred until inbox I/O, with an explicit once-per-
launch error if unavailable. No different container is substituted. Shared
recipe books use backend memberships and are independent of the native Reel
share inbox, so an unprovisioned share container does not fabricate or block
core Google/books/shopping service construction.

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
transfer authorization before screenshots can be retained and shown.

The subsequently authorized screenshot-only alternative uses ordinary workflow
logs, which GitHub explicitly excludes from artifact storage billing:
https://docs.github.com/en/billing/concepts/product-billing/github-actions .
Manual `screenshot_logs=true` with `upload_artifact=false` emits only the four
named attachments from the successful disclosed fixture capture test, never an
IPA, arbitrary file, credential or live user data. The default remains off.
`scripts/native-preview-transfer.mjs` enforces four ordinary PNG files, the
expected manifest/test/name mapping, 512 KiB per image and 1 MiB combined.
Base64 is split into 3,072-character log frames tagged with filename, byte count,
sequence and SHA256. The decoder requires complete ordered frames, exact
canonical base64/length/checksum and PNG headers/dimensions before writing to an
empty output directory. Missing/truncated/masked payloads fail explicitly.
This does not authorize artifact uploads or relax their cap/headroom gate.
Run `43757024879` at `e511ca3` verified this alternative end-to-end in
3m11s: four native PNGs totaling 784,026 bytes were retrieved from ordinary
logs, decoded with exact length/SHA256 checks, and visually inspected. All
four contain the fixture disclosure and intended sign-in/library/recipe/
shopping UI. The run uploaded zero artifacts. This completes screenshot
delivery, not live authentication/backend/import or signed-device proof.
Share inbox files remain independent atomic writes. Acknowledgement normalizes
UUID casing and is idempotent if a concurrent committed submission removed the
same file; scans ignore only files concurrently removed, not malformed content
or other I/O errors. A DEBUG-only internal filesystem test seam exercises this
on temporary directories without authorizing an unprovisioned production group.

On the actual iPhone, test launch, Google SDK/system-browser callback, invite rejection,
private/shared isolation, promotion/demotion/last-owner errors, image/data
revocation, concurrent writes, paste and Instagram native share, offline/errors,
review/save, shopping quantity/bought/already-have behavior, and SideStore
free re-signing plus on-device refresh. Verify whether the free signing team
actually authorizes the required app group/extension capabilities. Do not silently
replace the native share requirement if it does not. A simulator, web preview,
unsigned archive or Windows compilation claim is not this proof.
