# FR-CDP-012: Voice path — MethodResolver global default becomes the settings primary, mapped by call type

## Metadata
- **Area:** Voice Path / Method Resolution
- **Priority:** MUST
- **Source:** Frozen design §5 bullet 1 ("`MethodResolver`'s global-default step (currently hardcoded `.phone`) becomes the **settings primary**, mapped `CallApp → CallMethod` by call type ... Injected (closure/config struct) so `MethodResolver` stays coordinator-free and unit-testable") and Goal 3; feature constitution "In scope" bullet 4 and "Integration Surfaces"; workflow scope comment ("MethodResolver global-default step → settings primary, mapped CallApp→CallMethod by call type"); DV-6.

## Description
`MethodResolver`'s global-default step (step 4, today hardcoded `.phone` at `MethodResolver.swift:74-78`) **must** resolve to the settings primary (`defaultCallApp`), mapped `CallApp → CallMethod` by call type:

| Settings primary | Audio call | Video call |
|---|---|---|
| `phone` | `.phone` | `.phone` |
| `faceTime` | `.facetimeAudio` | `.facetimeVideo` |
| `messenger` | `.messengerAudio` | `.messengerVideo` |
| `whatsApp` | `.whatsappChat` | `.whatsappChat` |

Binding rules:
- Steps 1–3 of the existing chain (explicit mention → family preference → confirmed history) **must** be unchanged and keep outranking the global-default step (`ResolutionSource` values still pin which step won).
- The mapped value **must** be supplied through injection (closure/config struct) so `MethodResolver` stays coordinator-free and unit-testable — it **must not** read coordinator state directly.
- Out of the box the settings primary defaults to `.phone`, so the zero-configuration behaviour remains the universal GSM fallback.

## Acceptance criteria

```gherkin
Feature: Voice-path global default

  Scenario: With nothing else configured, the settings primary is used, mapped by call type
    Given no explicit app mention, no family preference and no confirmed history
    And the settings primary is FaceTime
    When the user asks to call a contact without naming an app (audio)
    Then the resolved method is .facetimeAudio with source .globalDefault
    And when the request is a video call, the resolved method is .facetimeVideo

  Scenario: The mapping covers every channel
    Given no explicit app mention, no family preference and no confirmed history
    Then a settings primary of WhatsApp resolves to .whatsappChat
    And a settings primary of Messenger resolves to .messengerAudio (audio) or .messengerVideo (video)
    And a settings primary of phone resolves to .phone

  Scenario: Explicit mentions still outrank the global default
    Given the settings primary is FaceTime
    When the user explicitly asks for WhatsApp
    Then the resolved method is .whatsappChat with source .explicit
    And family preferences and confirmed history likewise still outrank the settings primary
```

## Related
- FR: FR-CDP-013 (fallback applied before the confirmation), FR-CDP-017 (localised copy), FR-CDP-014 (override preserved)
- NFR: NFR-CDP-008 (MethodResolverTests pin the mapping), NFR-CDP-009 (no regression to steps 1–3)
