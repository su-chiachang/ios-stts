# FoundationModels / LanguageModelSession — Research Findings

Research for ios-stts issue #22 (part of map issue #21): on-device chat feature design using Apple's FoundationModels framework.

Sources: Apple's official developer documentation (`developer.apple.com/documentation/foundationmodels/...`) and WWDC25 session pages. Every claim below is cited inline. Where Apple's docs did not state something explicitly, that is called out as **Not documented by Apple**.

Note on freshness: the docs reflect the framework as currently published (iOS/macOS 26.x, with watchOS 27 in beta and some symbols marked iOS/macOS 27.0+ beta). One important finding: **`LanguageModelSession.GenerationError` is now deprecated** in favor of three new error types (`LanguageModelError`, `SystemLanguageModel.Error`, `LanguageModelSession.Error`) — see the Errors section below. Any older blog posts, WWDC25 transcripts, or sample code referencing `GenerationError` predate this split and should be treated as legacy.

---

## 1. Session creation

`LanguageModelSession` is declared as a **`final class`**, not an actor:

```swift
final class LanguageModelSession
```

It conforms to `Copyable`, `Escapable`, `Observable`, `Sendable`, `SendableMetatype`.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession)

**Initializers found in the "Creating a Session" topic section:**

- `init(model:tools:instructions:)` — blank-slate session with an instructions builder:
  ```swift
  convenience init(
      model: SystemLanguageModel = .default,
      tools: [any Tool] = [],
      @InstructionsBuilder instructions: () throws -> Instructions
  ) rethrows
  ```
  Apple's docs note this initializer "has several overloads available": one taking `Instructions?`, one taking `String?`, one taking a generic `LanguageModel`-conforming model, and the throwing-builder-closure form shown above.
  (https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:))

- `init(model:tools:transcript:)` — rehydrate a session from an existing transcript:
  ```swift
  convenience init(model: SystemLanguageModel = .default, tools: [any Tool] = [], transcript: Transcript)
  convenience init(model: some LanguageModel, tools: [any Tool] = [], transcript: Transcript)
  ```
  (https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:transcript:))

- Additional "Creating a Session with a Dynamic Profile" initializers exist — `init(profile:history:)` and `init(model:dynamicInstructions:history:)` — for a newer `DynamicProfile`/`DynamicInstructions` mechanism. Not detailed further here as out of scope for basic chat.
  (https://developer.apple.com/documentation/foundationmodels/languagemodelsession)

**How `instructions` is supplied:** both as an initializer parameter (via `@InstructionsBuilder` closure, or a plain `String?`/`Instructions?` overload) **and** as a distinct standalone type. `Instructions` is its own `struct`:

```swift
struct Instructions
```
Abstract: "Details you provide that define the model's intended behavior on prompts." Conforms to `Sendable`. Has `init(_:)` to create instructions from a string or a conforming type. Apple's guidance: don't put untrusted content in instructions (the model is trained to obey instructions over prompt content), and keep instructions to roughly 1–3 paragraphs since they consume context-window tokens on every turn.
(https://developer.apple.com/documentation/foundationmodels/instructions)

**Lifetime / state model:** a session is stateful and **accumulates conversation history implicitly** — the caller does not need to manually resubmit prior turns. Apple's guide states directly: "For a multiturn interaction — where the model retains some knowledge of what it produced — reuse the same session each time you call the model."
(https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

This accumulated history is exposed via a mutable `transcript` property:
```swift
final var transcript: Transcript { get set }
```
Abstract: "A full history of interactions, including user inputs and model responses."
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/transcript)

The "Managing the context window" article demonstrates reading `originalSession.transcript` after several prior `respond()` calls and using its accumulated `.first`/`.last` entries to seed a new session via `init(model:tools:transcript:)` — confirming the transcript is populated automatically as the session is used, and that explicit `Transcript` management is only needed if you want to *intervene* (e.g., truncate/condense), not for ordinary multiturn use.
(https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)

**Sendable / `@MainActor`:** `LanguageModelSession` itself conforms to `Sendable` (and `Observable`); no `@MainActor` attribute is stated on the type. Its generation methods carry an explicit `nonisolated(nonsending)` modifier (see Concurrency section, Q6) rather than main-actor isolation.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession)

---

## 2. Streaming

**Method / signature (verified from the docs, not assumed):**
```swift
final func streamResponse(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions()
) -> sending LanguageModelSession.ResponseStream<String>
```
Abstract: "Produces a response stream to a prompt." Return value described as "A response stream that produces aggregated tokens."
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:))

Overloads exist (per the `LanguageModelSession` topic listing) for: prompt-builder closures (`streamResponse(options:prompt:)`), structured/`Generable` output (`streamResponse(to:generating:includeSchemaInPrompt:options:)`), raw `GenerationSchema` output (`streamResponse(to:schema:includeSchemaInPrompt:options:)`), and "with Metadata" variants adding `contextOptions:`/`metadata:` parameters.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession)

**Stream element type:**
```swift
struct ResponseStream<Content> where Content: Generable
```
Abstract: "An async sequence of snapshots of partially generated content." Conforms to `AsyncSequence`, `Copyable`, `Escapable`. Its element is `LanguageModelSession.ResponseStream.Snapshot` ("A snapshot of partially generated content"), which exposes `content: Content.PartiallyGenerated`, `rawContent: GeneratedContent`, `transcriptEntries: ArraySlice<Transcript.Entry>`, and `usage: LanguageModelSession.Usage`. So yes — the element type is explicitly constrained to `Generable` (via the generic `Content` parameter); `String` itself conforms to `Generable`, which is how the plain-text `streamResponse(to:options:)` overload returns `ResponseStream<String>`.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream, https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream/snapshot)

**Cumulative snapshots, not deltas — confirmed explicitly.** The API reference pages describe "snapshots of partially generated content" without spelling out the cumulative-vs-delta distinction on their own, but the WWDC25 session "Meet the Foundation Models framework" states this outright:

> "Instead of raw deltas, we stream snapshots. As the model produces deltas, the framework transforms them into snapshots. Snapshots represent partially generated responses. Their properties are all optional. And they get filled in as the model produces more of the response."

(https://developer.apple.com/videos/play/wwdc2025/286/)

This matches the `respond`/`streamResponse` reference page's own phrasing that the stream "produces aggregated tokens." (https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:))

**Cancellation: Not documented by Apple.** The complete topic-section listing for `ResponseStream` documents exactly two members — `collect()` and the nested `Snapshot` type — plus conformances to `AsyncSequence`, `Copyable`, `Escapable`. There is no `cancel()` method, no cancellation-related case, and no mention of `Task` cancellation semantics anywhere in that page's documented member list, nor in the `LanguageModelSession` topic sections, nor in the two WWDC25 sessions reviewed ("Meet the Foundation Models framework," "Deep dive into the Foundation Models framework"). Since `ResponseStream` conforms to `AsyncSequence`, standard Swift structured-concurrency cancellation (cancelling the enclosing `Task`, or breaking out of `for try await`) presumably applies, but Apple does not state this explicitly anywhere in the fetched documentation — flagged here as undocumented rather than assumed.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream)

One documented operational note that touches streaming: "If running in the background, use the non-streaming `respond(to:options:)` method to reduce the likelihood of encountering `rateLimited(_:)` errors."
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:))

---

## 3. Availability

`SystemLanguageModel`:
```swift
final class SystemLanguageModel
```
Conforms to `Copyable`, `Escapable`, `Observable`, `Sendable`, `SendableMetatype`, and the `LanguageModel` protocol. Access the default on-device model via the static `default` property; `isAvailable: Bool` is a convenience getter, and `availability: SystemLanguageModel.Availability` is the full status.
(https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

**`Availability` enum — exact cases:**
```swift
@frozen enum Availability
```
- `available` — "The system is ready for making requests."
- `unavailable(SystemLanguageModel.Availability.UnavailableReason)` — "Indicates that the system is not ready for requests."

Conforms to `Equatable`, `Sendable`, `SendableMetatype`.
(https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum — note: the plain `/systemlanguagemodel/availability` path 404s, since that slug is already taken by the `availability` property; the enum's disambiguated canonical path uses the `-swift.enum` suffix. Verified both the `-swift.enum` and `-swift.enum/unavailablereason` paths resolve.)

**`UnavailableReason` enum — exact cases (verbatim):**
- `appleIntelligenceNotEnabled` — "Apple Intelligence is not enabled on the system."
- `deviceNotEligible` — "The device does not support Apple Intelligence."
- `modelNotReady` — "The model(s) aren't available on the user's device."

(https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason)

These same three case names are also used directly in Apple's own SwiftUI sample in the "Generating content and performing tasks with Foundation Models" guide, which switches on `model.availability` and matches `.available`, `.unavailable(.deviceNotEligible)`, `.unavailable(.modelNotReady)`, and a catch-all `.unavailable(let other)`.
(https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

**No dedicated "region restricted" case exists.** Apple's prose says only that "Model availability depends on whether the device and region supports Apple Intelligence" — region ineligibility is not broken out into its own `UnavailableReason` case in the docs; which of the three cases (if any) surfaces for a region-blocked-but-otherwise-eligible device is **not documented by Apple**.
(https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

**Snapshot vs. reactive:** `availability` is a plain `{ get }` property — you read it on demand, it is a snapshot. Apple does not document a separate NotificationCenter/KVO change-notification mechanism. However, because `SystemLanguageModel` conforms to `Observable`, and Apple's own example reads `model.availability` directly inside a SwiftUI `body: some View` (switching on it to select UI), the Observation framework is the implied mechanism by which a SwiftUI view re-evaluates when availability changes — this is shown by example rather than stated as a formal guarantee in prose.
(https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel, https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

---

## 4. Errors

**Important: the error surface has been split and `GenerationError` deprecated.** The `LanguageModelSession.GenerationError` reference page states verbatim:

> "Use `LanguageModelError`, `SystemLanguageModel.Error`, or `LanguageModelSession.Error` instead. Apps built with Xcode 26 will continue to catch this error until you rebuild with Xcode 27. You must update to Xcode 27 to catch the new error types before submitting your app."

(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror)

**Legacy `GenerationError` cases** (still present, but deprecated — conforms to `Error`, `LocalizedError`, `Sendable`, `SendableMetatype`):
`assetsUnavailable(_:)`, `decodingFailure(_:)`, `exceededContextWindowSize(_:)`, `guardrailViolation(_:)`, `rateLimited(_:)`, `refusal(_:_:)`, `concurrentRequests(_:)`, `unsupportedGuide(_:)`, `unsupportedLanguageOrLocale(_:)`.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror)

**Current, non-deprecated error types:**

- **`LanguageModelError`** — "A failure that may occur while generating a response when using any language model." Conforms to `Error`, `LocalizedError`, `Sendable`, `SendableMetatype`, `CustomDebugStringConvertible`. Cases:
  `contextSizeExceeded(_:)`, `rateLimited(_:)`, `refusal(_:)`, `timeout(_:)`, `guardrailViolation(_:)`, `unsupportedCapability(_:)`, `unsupportedTranscriptContent(_:)`, `unsupportedGenerationGuide(_:)`, `unsupportedLanguageOrLocale(_:)`.
  (https://developer.apple.com/documentation/foundationmodels/languagemodelerror)

  This is the error actually thrown by generation calls in current sample code — the "Generating content and performing tasks with Foundation Models" guide shows a `try await session.respond(to: prompt)` call caught with a `catch LanguageModelError.contextSizeExceeded(let context)` clause, confirming `LanguageModelError` (not the deprecated `GenerationError`) is the type surfaced by `respond`/`streamResponse` in current guidance.
  (https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models, also https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)

  One gap worth flagging: the deprecated `GenerationError` had a `decodingFailure(_:)` case (session failed to deserialize a `Generable` type from model output). None of the three replacement types (`LanguageModelError`, `LanguageModelSession.Error`, `SystemLanguageModel.Error`) documents an obvious successor case for this specific failure mode in the pages fetched — **not documented by Apple** where guided-generation decoding failures now surface.

- **`LanguageModelSession.Error`** — "A failure caused by incorrect use of a language model session." Conforms to `Error`, `LocalizedError`, `Sendable`, `SendableMetatype`, `Equatable`, `Hashable`, `CustomDebugStringConvertible`. Cases: `concurrentRequests` ("Multiple requests were made to the session concurrently"), `transcriptMutationWhileResponding` ("The session's transcript was mutated while a request was in progress"). Listed at iOS/iPadOS/macOS/visionOS/watchOS/Mac Catalyst **27.0+ (beta)** in the fetched docs.
  (https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error)

- **`SystemLanguageModel.Error`** — "An error specific to the on-device system language model." Conforms to `Error`, `LocalizedError`, `Sendable`, `SendableMetatype`, `CustomDebugStringConvertible`. Case: `assetsUnavailable(_:)` (associated value: `SystemLanguageModel.Error.AssetsUnavailable`).
  (https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/error)

- `LanguageModelSession.ToolCallError` also exists (listed in the session's "Errors" topic section) for failures during tool invocation specifically — not enumerated in detail here as it's tangential to plain chat `respond`/`streamResponse` usage.
  (https://developer.apple.com/documentation/foundationmodels/languagemodelsession)

Separately, an older WWDC25 "Deep dive into the Foundation Models framework" transcript excerpt references `LanguageModelSession.GenerationError.exceededContextWindowSize` and says "errors might include guardrail violation, unsupported language, or context window exceeded" — this predates the `LanguageModelError` split described above and should be read as describing the now-deprecated error type.
(https://developer.apple.com/videos/play/wwdc2025/301/)

---

## 5. Context window

**Exact documented number: 4,096 tokens.** Stated identically on two separate doc pages:

> "the system model supports up to 4,096 tokens" — (https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

> "Apple's on-device foundation model has a context window of 4096 tokens per session" — (https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)

Token accounting: "A single token corresponds to three or four characters in languages like English, Spanish, or German, and one token per character in languages like Japanese, Chinese, or Korean." The **sum of all tokens in the instructions, all prompts, and all outputs** counts toward this one limit, for the lifetime of the session.
(https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

**Behavior when exceeded:** generation throws `LanguageModelError.contextSizeExceeded(_:)`, and the session **does not auto-truncate** — "After reaching the context size, the session can no longer process additional requests and throws a `contextSizeExceeded` error." Recovery is manual: create a new `LanguageModelSession` (a new session gets a fresh context window but loses the old session's state), optionally seeded from a condensed/summarized `Transcript` (e.g., keeping only the first and last entries) via `init(model:tools:transcript:)`.
(https://developer.apple.com/documentation/foundationmodels/managing-the-context-window)

There is also a runtime-queryable property on the model itself:
```swift
@backDeployed(before: iOS 26.4, macOS 26.4, visionOS 26.4)
final var contextSize: Int { get }
```
Abstract: "Returns the maximum context size (in tokens) supported by the model." The property page itself does not restate the 4,096 figure. The framework's `SystemLanguageModel` page separately notes there are currently **3 model versions** in the field, aligned to iOS/iPadOS/macOS/visionOS 26.0–26.3, 26.4, and 27.0/watchOS 27.0 — raising the possibility that `contextSize` could differ across model versions, but **Apple does not explicitly state per-version context-size numbers anywhere in the fetched docs**; treat 4,096 as the number documented for "the system model" generally, and prefer querying `contextSize` at runtime over hardcoding 4,096.
(https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize, https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)

---

## 6. Concurrency

Neither `respond` nor `streamResponse` is `@MainActor`-isolated per the docs. Their declarations:

```swift
@discardableResult
nonisolated(nonsending) final func respond(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions()
) async throws -> LanguageModelSession.Response<String>
```
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/respond(to:options:))

```swift
final func streamResponse(
    to prompt: Prompt,
    options: GenerationOptions = GenerationOptions()
) -> sending LanguageModelSession.ResponseStream<String>
```
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:))

`respond` carries the explicit Swift 6 concurrency modifier `nonisolated(nonsending)` (not main-actor-isolated); `streamResponse` returns a `sending` value (safe to hand across isolation domains). Neither declaration mentions `@MainActor` anywhere in the fetched reference content.

**`Sendable` conformances documented on the relevant types:**
- `LanguageModelSession` — conforms to `Sendable` (and `Observable`). (https://developer.apple.com/documentation/foundationmodels/languagemodelsession)
- `Instructions` — conforms to `Sendable`. (https://developer.apple.com/documentation/foundationmodels/instructions)
- `Prompt` — conforms to `Sendable` (also `PromptRepresentable`, `Copyable`, `Escapable`, `SendableMetatype`). (https://developer.apple.com/documentation/foundationmodels/prompt)

Together, these mean session creation and generation can, per the docs, happen off the main actor / from background async contexts, and the core types are safe to pass across concurrency domains.

**One constraint that is *not* about actor isolation:** a single `LanguageModelSession` instance can only process one request at a time. The `isResponding: Bool { get }` property's docs warn: "You should not call any of the respond methods while this property is `true`" — doing so is a same-session serialization violation (surfaces as the `concurrentRequests` case in both the legacy `GenerationError` and the new `LanguageModelSession.Error`), not a threading/actor-isolation restriction.
(https://developer.apple.com/documentation/foundationmodels/languagemodelsession/isresponding)

---

## Also: minimum platform version and Apple Intelligence eligibility

The FoundationModels framework landing page lists:

| Platform | Minimum version |
|---|---|
| iOS | 26.0 |
| iPadOS | 26.0 |
| macOS | 26.0 |
| Mac Catalyst | 26.0 |
| visionOS | 26.0 |
| watchOS | 27.0 (beta, as currently listed) |

Framework abstract: "Perform tasks with models that specialize in language understanding, structured output, and tool calling. The Foundation Models framework provides access to any large language model, like the on-device and Private Cloud Compute models designed for Apple Intelligence."

Device/region eligibility is called out explicitly: "To use Apple Foundation Models, people need a device that supports Apple Intelligence." (This links out to the non-developer marketing page `apple.com/apple-intelligence` for the supported-device list — that linked page is not a `developer.apple.com` doc page, so its specific device list is not re-verified here.)
(https://developer.apple.com/documentation/foundationmodels)

The guide article restates the region dimension explicitly: "Model availability depends on whether the device and region supports Apple Intelligence," and separately notes it can take time for the model to finish downloading after a person turns Apple Intelligence on — plan for that as another "unavailable" state to handle in UI (surfacing via `modelNotReady`, per the enum cases above).
(https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)

---

## Sources

- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:instructions:)
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/init(model:tools:transcript:)
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/transcript
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/respond(to:options:)
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/streamresponse(to:options:)
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream/snapshot
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/responsestream/collect()
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/isresponding
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror
- https://developer.apple.com/documentation/foundationmodels/languagemodelsession/error
- https://developer.apple.com/documentation/foundationmodels/languagemodelerror
- https://developer.apple.com/documentation/foundationmodels/instructions
- https://developer.apple.com/documentation/foundationmodels/prompt
- https://developer.apple.com/documentation/foundationmodels/generable
- https://developer.apple.com/documentation/foundationmodels/generable/partiallygenerated
- https://developer.apple.com/documentation/foundationmodels/transcript
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/tokencount(for:)
- https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/error
- https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models
- https://developer.apple.com/documentation/foundationmodels/managing-the-context-window
- https://developer.apple.com/videos/play/wwdc2025/286/ (Meet the Foundation Models framework)
- https://developer.apple.com/videos/play/wwdc2025/301/ (Deep dive into the Foundation Models framework)
