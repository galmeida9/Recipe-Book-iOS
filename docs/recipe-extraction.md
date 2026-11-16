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
3. `fayoussef/bulk-llm-runner`: one `google/gemini-2.5-flash-lite` request with the
   reviewed extraction rules in both prompt and system message. No web/file
   tools, comparison/fallback models, spreadsheets or automatic retries.

Only caption, relevant public comment text and transcription text go to
inference. Commenter identity, video runtime and ASR timing offsets are not
cooking facts. The model receives the actual evidence IDs and permitted units
as JSON-schema enums. Structured quantities, ordered instructions, times,
warnings and citations are validated before an editable review draft appears.
Source text is data, never authority to execute commands or change the workflow.

Unsupported IDs, food names, amounts, units, numbers, cooking times, temperatures,
inferred servings/total time, ungrounded instruction wording and review bypass
fail closed. Explicit conflicting amounts detected across evidence become
unknown, with source alternatives in review warnings. Unknown quantities do not
become confirmed numeric groceries. User approval remains mandatory.

These are deliberately conservative syntactic/source-fact checks, **not a proof
of semantic entailment** for arbitrary narration or languages. Ambiguous
synonyms, spoken-out numbers and per-item/batch distinctions can require manual
review or fail validation. Do not claim general reliability from the original
one-video/two-case benchmark. Its held-out caption-400g/audio-600g failure is a
permanent regression case; a model warning alone does not resolve a quantity.

## Runtime activation gate

Production remains off by default. Before enabling, verify the actual shared
account's Free allowance, no automatic paid upgrades/overages, account
exclusivity, each actor's charging model/build, and data-processing terms.
`maxTotalChargeUsd` is only a billing safeguard for a compatible charging model;
setting a request option does not establish that compatibility.

Require `APIFY_ENABLED`, `APIFY_FREE_PLAN_VERIFIED`,
`APIFY_NO_OVERAGES_VERIFIED`, `APIFY_ACCOUNT_EXCLUSIVE`,
`APIFY_PIPELINE_TERMS_VERIFIED` and `APIFY_PIPELINE_PRICING_VERIFIED`, all explicitly
`true`. For each of `METADATA`, `AUDIO`, `MODEL`, configure
`APIFY_<STAGE>_BUILD` as a reviewed numeric build and
`APIFY_<STAGE>_CAP_MICROS` as a positive hard cap. Their **sum** (maximum USD 1)
is reserved before any charged request; the USD 4.75 shared-cycle limit includes
in-flight reservations, leaving USD 0.25 headroom. Unknown outcomes consume the
entire reservation, and no new charged POST is retried.

The runtime `APIFY_TOKEN` comes only from the private vault reference populated
through a masked operator prompt. Never use MCP credentials or place tokens in
source, the phone bundle, CI logs or chat. No Azure/OpenAI resource or separate
OpenRouter billing account is needed for this candidate.

Migration `006-import-pipeline.sql` adds the persisted stage journal. A stage's
dispatch intent commits before its external POST. A run ID and completed stage
are persisted before advancing. Build/cap configuration is hashed per job;
changes stop further charging against its existing reservation. Expiry,
revocation, unknown POST outcomes, invalid evidence or rejected output stop the
pipeline visibly. No fixture or regex-only draft is substituted.

The pipeline and validator tests use synthetic responses without provider
charges. They are not live production proof; activation still requires the
account/secret/build/cap checks above and a separately authorized end-to-end run.

### Runtime review on 2026-11-16

Read-only public actor/build metadata identified the following successful
numeric builds (not an instruction to enable them without the remaining gates):

| Stage | Actor ID | Build | Minimum memory |
| --- | --- | --- | --- |
| Metadata | `xMc5Ga1oCONPmWJIa` | `0.0.653` | 128 MiB |
| Audio | `S9A11NvceWaGorwwh` | `0.0.83` | 512 MiB |
| Model | `0pArcqOZFSjoCBlJX` | `0.1.65` | 256 MiB |

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
terms-verification flag while this remains unresolved. Under
[Actor Terms sections 4 and 9](https://docs.apify.com/legal/actor-terms-and-conditions),
community creators can access inputs/outputs and are not Apify DPA
subprocessors. The model actor additionally forwards prompts to the selected
model provider. No zero-retention or no-training guarantee has been established
for this community-actor chain. Only authorized public recipe evidence may be
sent; private app recipes, credentials and commenter identity must not be sent.
