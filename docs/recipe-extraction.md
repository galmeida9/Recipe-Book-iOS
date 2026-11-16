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
