# Evidence-grounded Instagram extraction

The runtime implementation is `backend/src/import-pipeline.ts`; the reusable
prompt, dynamically restricted output schema and local validation are in
`backend/src/recipe-extraction.ts`. The legacy deterministic labelled-section
parser is not the production pipeline.

The pipeline uses one public video only:

1. `apify/instagram-reel-scraper`: caption and available public comments, with
   paid transcription/download/shares options disabled.
2. `apple_yang/instagram-transcripts-scraper`: actual audio recognition segments,
   with enhanced crawling and profile/bulk crawling disabled. Missing audio is
   an explicit failure, not a caption-only success.
3. Direct Azure OpenAI `gpt-4.1-mini`, version `2025-04-14`, through the workload
   managed identity and strict JSON output. No API key, web/file tools,
   comparison/fallback models, spreadsheets or automatic retries.

The original Apify relay returned a real
`actor-restricted-access-permission-mode-not-supported` denial from its Standby
gateway. Its previous Flash Lite benchmark is not proof of this different
Azure model. No restricted-token boundary was bypassed to make the relay work.

`MODEL_PROVIDER=azure-credits` selects the direct route. It requires
`AZURE_MODEL_CREDITS_VERIFIED`, `AZURE_MODEL_SPENDING_LIMIT_VERIFIED` and
`AZURE_MODEL_DEPLOYMENT_VERIFIED`, with the owned `AZURE_OPENAI_ENDPOINT`,
`AZURE_OPENAI_DEPLOYMENT` and `AZURE_MODEL_RUN_CAP_MICROS=50000`.
Each request is at most 24,000 UTF-8 bytes and 6,000 output tokens. Microsoft
retail Consumption meters were USD 0.0004/1K input and USD 0.0016/1K output.
A conservative byte-as-token upper bound plus protocol headroom fits the
USD 0.05 reservation. No charged POST is automatically retried.

The owned S0 account disables local/API-key authentication. Its deployment
is GlobalStandard token consumption, capacity 10, not PTU/reserved hosting,
fine-tuning, GPU or Marketplace billing. Capacity is a rate allowance, not a
fixed throughput purchase. After provider registration, actual quota was
200 units for regular GlobalStandard GPT-4.1 Mini; ARM validation and deployment
succeeded. Nano's zero quota and the retired 4o Mini SKU were not bypassed.
Visual Studio credits [explicitly cover Azure OpenAI subject to access and
availability](https://learn.microsoft.com/en-us/visualstudio/subscriptions/vs-azure-eligibility);
subscription `spendingLimit=On` remains mandatory.

Only caption, relevant public comment text and transcription text go to
inference. Commenter identity, video runtime and ASR timing offsets are not
cooking facts. The model receives the actual evidence IDs and permitted units
as JSON-schema enums. Structured quantities, ordered instructions, times,
warnings and citations are validated before an editable review draft appears.
Source text is data, never authority to execute commands or change the workflow.

Unsupported IDs, food names, instruction numbers/actions, cooking times and
review bypass fail closed. An unconfirmed ingredient amount/unit or inferred
total time becomes null with an explicit review warning, not a failed whole
recipe or a confirmed shopping quantity. Explicit conflicting amounts become
unknown, with source alternatives in review warnings. Unknown quantities do not
become confirmed numeric groceries. User approval remains mandatory.

Localized explicit units such as Portuguese `c. sopa` normalize to `tbsp`
without density or batch-size guesses. An explicit approximate source yield
is flagged as approximate. A cited ingredient's already-validated caption can
support its precise name in a narrated method; unambiguous shortened references
retain that ingredient citation, while new foods/actions and ambiguous facts
remain invalid. Completed raw model output is retained privately before
validation so diagnosis/revalidation never requires another paid model call.

These are deliberately conservative syntactic/source-fact checks, **not a proof
of semantic entailment** for arbitrary narration or languages. Ambiguous
synonyms, spoken-out numbers and per-item/batch distinctions can require manual
review or fail validation. Do not claim general reliability from the original
one-video/two-case benchmark. Its held-out caption-400g/audio-600g failure is a
permanent regression case; a model warning alone does not resolve a quantity.

## Runtime activation gate

Production remains off by default. Before enabling, verify the actual shared
account's Free allowance, no automatic paid upgrades/overages, account
budget mode, each actor's charging model/build, and data-processing terms.
`maxTotalChargeUsd` is only a billing safeguard for a compatible charging model;
setting a request option does not establish that compatibility.

Require `APIFY_ENABLED`, `APIFY_CUSTOMER_IMPORTS_ENABLED`,
`APIFY_FREE_PLAN_VERIFIED`, `APIFY_NO_OVERAGES_VERIFIED`, `APIFY_BACKEND_LEDGER_VERIFIED`,
`APIFY_PIPELINE_REVIEW_ACKNOWLEDGED` and `APIFY_PIPELINE_PRICING_VERIFIED`, all explicitly
`true`. For each of `METADATA`, `AUDIO`, configure
`APIFY_<STAGE>_BUILD` as a reviewed numeric build and
`APIFY_<STAGE>_CAP_MICROS` as a positive hard cap. Their **sum** (maximum USD 1)
plus the Azure model cap is reserved before any charged request. The reviewed
pilot uses USD 0.01 metadata + USD 0.02 audio + USD 0.05 model = USD 0.08.
Unknown outcomes consume the entire reservation; no new charged POST is retried.
The explicit shared-account pilot below is not global live-usage accounting.

The runtime `APIFY_TOKEN` comes only from the private vault reference populated
through a masked operator prompt. Never use MCP credentials or place tokens in
source, the phone bundle, CI logs or chat. Azure model access uses the workload
identity, not this token. No Google API key or OpenRouter billing account is
required by the selected Azure route. The unused direct-Gemini adapter is not
selected or an automatic fallback.

### Explicit restricted-token budget mode

`APIFY_BUDGET_MODE=api-usage` is the default. It requires actual monthly usage
access and account exclusivity; HTTP 403 is an error, never a fallback trigger.
The reviewed three-actor scoped token has no account-usage permission in the
provider UI and actually returned 403 for `/users/me/usage/monthly`.

For this shared Free account, `APIFY_BUDGET_MODE=verified-free-stop` explicitly
uses the operator's dated console proof instead. It requires
`APIFY_BACKEND_LEDGER_VERIFIED=true`, verified Free/no-overage flags,
`APIFY_FREE_STOP_VERIFIED_AT`, `APIFY_VERIFIED_CYCLE_START`,
`APIFY_VERIFIED_CYCLE_END`, `APIFY_VERIFIED_SPENT_MICROS` and
`APIFY_PILOT_CAP_MICROS`. The pilot ledger cap cannot exceed USD 1, including
the observed usage lower bound and all app reservations. Proof expires after
24 hours or the conservative reviewed cycle end, whichever is earlier; new jobs
fail visibly when fewer than 15 minutes remain.

This mode does **not** claim visibility of global current usage or reservations
from MCP/other projects. `APIFY_ACCOUNT_EXCLUSIVE=false` is accurate for this
account. The real provider-wide USD 5 pause-at-exhaustion control, without a
payment method or upgrades, is the ultimate cross-project hard stop. Unknown
external usage can exhaust the allowance early; provider failures remain visible.
Only this backend's jobs share its transactional ledger. Preflight reports the
mode, observed snapshot, expiry and `globalUsageVisible=false` explicitly.

Migration `006-import-pipeline.sql` adds the persisted stage journal. A stage's
dispatch intent commits before its external POST. A run ID and completed stage
are persisted before advancing. Build/cap configuration is hashed per job;
changes stop further charging against its existing reservation. Expiry,
revocation, unknown POST outcomes, invalid evidence or rejected output stop the
pipeline visibly. No fixture or regex-only draft is substituted.

The unit tests use synthetic responses without provider charges. Separately,
the real staged run completed metadata and audio, then hit the relay denial.
An immutable model-only recovery journal reused that persisted evidence and
actually reached `review` via workload-identity Azure inference: seven
ingredients, exact fractions, six ordered method steps including all chilling
durations and "Serve chilled", unknown servings/total time, valid citations and
a private downloaded cover. The old failed journal and full USD 0.08 settlement
were preserved. The separate recovery also settled its full USD 0.08 reservation;
it did not rescrape or retranscribe.

Actual Azure usage was 1,479 input and 563 output tokens, an estimated
**model-only** USD 0.0014924 at the reviewed retail rates. This is not a complete
Apify/platform/Blob invoice or general recipe reliability proof. Physical
share-sheet authentication, book selection, dismissal, background progress and
review/save still require the matching signed iPhone build and device checks.

### Runtime review on 2026-11-16

Read-only public actor/build metadata identified the following successful
numeric builds (not an instruction to enable them without the remaining gates):

| Stage | Actor ID | Build | Minimum memory |
| --- | --- | --- | --- |
| Metadata | `xMc5Ga1oCONPmWJIa` | `0.0.653` | 128 MiB |
| Audio | `S9A11NvceWaGorwwh` | `0.0.83` | 512 MiB |
| Historical failed relay (not selected) | `0pArcqOZFSjoCBlJX` | `0.1.65` | 256 MiB |

The corresponding build IDs are `JRCDaeR2IqpWXAu2u`,
`dVBUTLy3gVk9PVtTq` and `WzI4lP7dqm8NOC3Q5`. Evidence comes from the
public [actor metadata API](https://docs.apify.com/api/v2/actor-get) and
`GET /v2/actor-builds/{buildId}`. All three builds reported `SUCCEEDED`.
Current effective Free-tier event prices read from each actor's `pricingInfos`
(not a complete per-import invoice):

| Stage | Free-tier event prices |
| --- | --- |
| Metadata | USD 0.001 actor start plus USD 0.0026/reel; shares USD 0.007, transcript USD 0.048/started minute and video download USD 0.02/started MiB are disabled |
| Audio | USD 0.001/result plus USD 0.0045/started audio minute; USD 0.002 enhanced crawl is disabled |
| Model | USD 0.002/result plus separately billed platform/model usage |

These are dated review evidence, not immutable guarantees or enabled runtime
settings. Numeric build pinning does not freeze account-level event prices.
Reconfirm actual prices and returned hard-cap options before activation.

The audio stage requests 512 MiB; a generic 256-MiB request is incompatible with
the reviewed build. The model actor's published Free-plan policy charges model
usage at **ten times** standard token rates, in addition to its USD 0.002/result
event and platform usage. Earlier benchmark model-only amounts are not complete
runtime prices. No nested run was identified in the existing benchmark log;
the README's phrase "openrouter actor" alone does not establish a dependency.
Start with only the three reviewed actors. If a real permission failure reveals
a nested dependency, identify and review it before expanding scope; do not assume
an outer run's requested cap covers independently billed children.

Scoped runtime tokens must use **Restricted access**, permit only the reviewed
actor executions and necessary usage reads, and allow access to default storages
of triggered runs. The restriction is transitive to nested actors. Do not select
full actor access or broad account-wide actor execution merely to avoid finding
the actual dependency. See [scoped token execution](https://docs.apify.com/integrations/api#actor-execution).

The [current General Terms](https://docs.apify.com/legal/general-terms-and-conditions)
(effective 2026-07-09) state that Services are intended for business use only and
not suitable for consumers. The document does not establish whether this
project's development use qualifies. A logged-in Free account alone proves
neither eligibility nor ineligibility; obtain applicable account-agreement or
provider clarification without requesting personal legal status. Do not set the
operator-review flag solely on the basis of account login. The owner has reviewed
the caveat and directed proceeding with private use for the owner and partner.
`APIFY_PIPELINE_REVIEW_ACKNOWLEDGED` records that integration assessment only;
it does not assert business eligibility, a published exception, provider
endorsement, or legal advice. A provider denial must be surfaced, not bypassed. Under
[Actor Terms sections 4 and 9](https://docs.apify.com/legal/actor-terms-and-conditions),
community creators can access inputs/outputs and are not Apify DPA
subprocessors. The model actor additionally forwards prompts to the selected
model provider. No zero-retention or no-training guarantee has been established
for this community-actor chain. Only authorized public recipe evidence may be
sent; private app recipes, credentials and commenter identity must not be sent.
