# Dementia-Specific Requirements — Elderly AI Assistant

**Project:** Elderly AI Assistant
**Version:** 1.0 (MVP)
**Document Type:** Supplement to `requirements.md`
**Status:** Draft — pending review and integration
**Date:** 2026-05-24

---

This document defines requirements specific to users with **early-onset and moderate dementia**. It supplements the baseline requirements in `requirements.md` (46 FRs, 32 NFRs). Requirements here are additive — they do not replace baseline requirements unless explicitly stated.

---

## 0. Target User Reframing

### 0.1 Primary User Profile

The primary user is an elderly person (60+) with **early-onset or moderate dementia**. Key characteristics relevant to design:

- **Memory impairment**: May not remember taking medication, whether they ate, who called, or what day it is. Repetition of questions is common and expected.
- **Word-finding difficulty**: May struggle to recall specific words, including the wake word. Speech may be intact but vocabulary retrieval is impaired.
- **Reduced processing speed**: May need 10-20 seconds to process a spoken announcement and formulate a response. Rushed interactions cause confusion and distress.
- **Time/place disorientation**: May not know the day, date, or time. May confuse morning and evening. Orientation cues reduce anxiety.
- **Intact long-term memory**: Names of family members, childhood places, and deeply familiar words are often preserved. Design should leverage this.
- **Variable capacity**: Cognitive function fluctuates — the person may be lucid in the morning and confused by evening. The system must degrade gracefully across this spectrum.
- **PIN/memory difficulty**: Many people with moderate dementia cannot reliably recall a 4-6 digit PIN. This is not a compliance issue — it is a neurological reality.

### 0.2 Secondary User (Caregiver / Family Member)

The caregiver is an adult child or family member who manages the primary user's care remotely. They need:

- Visibility into daily patterns (medication taken? meals? activity?)
- Alerting when patterns break (missed doses, no interaction, possible confusion)
- Remote override capability when the primary user cannot self-authenticate

### 0.3 Design Principles (Binding)

These principles override any conflicting general accessibility guidelines:

| Principle | Rule |
|-----------|------|
| **One idea per utterance** | The assistant never presents choices ("Would you like A or B?"). It asks one yes/no question or gives one instruction at a time. |
| **No time pressure** | No system interaction requires a response within less than 15 seconds. Default acknowledgement windows accommodate processing delays. |
| **Familiar over novel** | Use words the person has known for decades (family names, common objects). Avoid technical terms, abbreviations, or unfamiliar concepts. |
| **Confirm, don't assume** | Medication acknowledgements require a confirmation challenge. The system treats "I took it" as a signal to verify, not as ground truth. |
| **Silence is a signal** | Extended absence of interaction during daytime is treated as a potential wellness event and escalated to the caregiver. |
| **Caregiver is the safety net** | When the system cannot resolve a situation (authentication failure, suspected double-dose, confusion state), it escalates to the caregiver rather than failing silently or guessing. |

---

## 1. Functional Requirements — Dementia-Specific

### 1.1 Medication Safety — Double-Dose Prevention

**FR-D01**
After the user acknowledges a medication reminder (FR-026 through FR-029), the system must issue a confirmation challenge before recording the dose as taken. The challenge must reference a concrete, familiar attribute of the medication, configurable by the caregiver.

*Example:* "You said you've taken your Amlodipine. Is that the small white tablet in the blue box?"

*Rationale:* People with dementia may say "Taken" reflexively without having taken the medication. A concrete confirmation challenge anchors the acknowledgment to a physical action the person can verify. If the caregiver has not configured a description, the system defaults to repeating the medication name: "Did you take your Amlodipine just now?"

**FR-D02**
If the user answers "No" or does not respond to the confirmation challenge within 30 seconds, the system must:
- (a) NOT record the dose as taken
- (b) Announce: "That's okay. I'll remind you again in a few minutes."
- (c) Re-enter the re-fire escalation sequence (FR-027) from the next re-fire interval

**FR-D03**
The system must detect potential double-dosing: if a medication acknowledgment is recorded and the user subsequently attempts to acknowledge the same medication within the same scheduled window (e.g., within 4 hours for a once-daily medication), the system must:
- (a) Announce: "You already took your [medication name] earlier today. Let me check with [caregiver name]."
- (b) NOT record a second dose
- (c) Send a "possible double-dose attempt" alert to the caregiver via the companion app, including the medication name and timestamp

This window is configurable per medication by the caregiver (default: 4 hours for once-daily, 2 hours for twice-daily medications).

**FR-D04**
The companion app must display a medication adherence timeline for the current day showing:
- Each scheduled medication with its scheduled time
- Status: TAKEN (with timestamp), MISSED (with timestamp), PENDING, or DOUBLE_DOSE_ATTEMPT (with timestamp)
- A visual indicator (color-coded) so the caregiver can assess adherence at a glance

This replaces and extends the generic adherence log in FR-030 for the caregiver-facing view.

**FR-D04a**
The system must support **photo verification of medication intake** as an optional complement to the confirmation challenge (FR-D01). When enabled by the caregiver, after the user acknowledges a medication reminder:
- (a) The assistant announces: "Please show me your empty hand so I can confirm you've taken your [medication name]."
- (b) The device camera activates (front-facing, if available) and captures a single still image.
- (c) The assistant announces: "Thank you. [Caregiver name] will see that you've taken your medication."
- (d) The image is processed on-device to confirm a hand is visible in frame and the scene is not completely dark or obscured. This is NOT facial recognition or medication identification — it is a presence/gesture check only.

*Rationale:* The confirmation challenge (FR-D01) is the primary safeguard. Photo verification provides an additional layer of evidence for the caregiver. A person with dementia who reflexively says "Yes" to the confirmation challenge cannot easily fake an empty-hand photo. This is the closest feasible proxy for "medication actually taken" without requiring pill-level computer vision.

**FR-D04b**
The captured verification photo must be:
- (a) Compressed to a maximum of 200 KB before transmission
- (b) End-to-end encrypted in transit to the companion app (using the same Signal Protocol channel as remote config)
- (c) Stored on the primary device only until successfully delivered to the companion app, then deleted from the primary device within 1 hour
- (d) Never stored on the relay server
- (e) Never used for any purpose other than caregiver medication verification

**FR-D04c**
The companion app must display the verification photo alongside the corresponding medication acknowledgment in the adherence timeline (FR-D04), showing:
- Medication name and scheduled time
- Acknowledgment timestamp
- The verification photo with capture timestamp
- A thumbnail that the caregiver can tap to view full-size

**FR-D04d**
Photo verification is configurable per medication and per time of day by the caregiver:
- (a) **Enabled/disabled per medication**: The caregiver may enable photo verification for high-risk medications (e.g., blood pressure, blood thinners, insulin) and disable it for supplements or low-risk medications.
- (b) **Enabled/disabled per time of day**: The caregiver may require photo verification for morning doses but not evening doses (when a family member is physically present).
- (c) **Graceful degradation**: If the camera is unavailable (hardware failure, permissions revoked, device face-down), the system falls back to the voice confirmation challenge (FR-D01) alone and sends a "photo unavailable" indicator to the caregiver alongside the acknowledgment.

*Rationale:* Camera access may not always be possible. The system must not block medication acknowledgment on camera availability — the voice confirmation challenge is the floor, photo verification is the ceiling.

**FR-D04e**
The primary device must provide a clear audio cue (not just visual) when the camera is about to activate and when it has finished capturing, so the user knows what is happening without needing to see the screen. Example announcement: "I'm going to take a quick picture now. Hold up your empty hand."

---

### 1.2 Wake Word — Dementia Accessibility

**FR-D05**
The wake word must be configurable by the caregiver via the companion app. The system must support wake words in Nepali, English, or a caregiver-provided custom word or short phrase (maximum 3 words).

*Rationale:* A person with dementia may not remember "Hey Sahayak" but may reliably remember their own name, a family nickname, or a lifelong-familiar word. Let the caregiver choose what works.

**FR-D06**
The system must support caregiver-configured **scheduled auto-activation** mode. At specified times (e.g., medication times, meal times, morning), the assistant initiates interaction by announcing itself and delivering the relevant prompt without requiring the wake word.

*Example:* At 08:00 the assistant says "Good morning, Aama. It's time for your Amlodipine."

*Rationale:* If the person cannot recall the wake word, scheduled auto-activation ensures they still receive medication reminders and daily structure. Wake-word detection remains active in parallel for unscheduled interactions.

**FR-D07**
When auto-activation mode fires, the assistant must:
- (a) Announce itself with the configured greeting
- (b) State the reason for activation in one short sentence
- (c) Ask exactly one yes/no question or give one instruction
- (d) Wait for a response without time pressure (no timeout shorter than 30 seconds)

---

### 1.3 Orientation and Daily Structure

**FR-D08**
On the first wake-word activation or scheduled auto-activation each morning (configurable time window, default: 05:00-12:00), the system must deliver a **daily orientation briefing**. The briefing includes:

- (a) Day of week and date (e.g., "Today is Tuesday, the 24th of May")
- (b) One-sentence weather summary if available (e.g., "It will be sunny and warm today")
- (c) Number of scheduled events for the day (e.g., "You have two things on your calendar today")
- (d) The name of the primary caregiver and when they plan to call (if configured)

Each item is spoken as a separate short sentence with a pause between sentences. Total briefing length must not exceed 45 seconds of TTS output.

**FR-D09**
The orientation briefing content and timing window are configurable by the caregiver. The caregiver may disable individual briefing elements (e.g., weather off, calendar count only).

**FR-D10**
The system must support a caregiver-configured **evening wind-down reminder**. At a specified time, the assistant announces a simple evening routine prompt (e.g., "It's 8pm. Time to get ready for bed."). This is a single announcement with no required acknowledgment.

---

### 1.4 Inactivity and Wellness Monitoring

**FR-D11**
The system must track **interaction presence** — whether the user has activated the assistant (wake word or auto-activation) within a caregiver-configured daytime window (default: 07:00-21:00).

**FR-D12**
If no interaction is detected for a caregiver-configured inactivity threshold (default: 4 hours) during the daytime window, the system must:
- (a) Attempt a scheduled auto-activation wellness check: "Good afternoon, [name]. Are you doing okay?"
- (b) Wait 30 seconds for any verbal response (not limited to specific keywords — any speech counts as a response)
- (c) If no response is detected, escalate:
  - Send an "inactivity alert" notification to the caregiver via the companion app
  - Include the time of last known interaction
  - The alert must be marked as high-priority on the push notification channel

**FR-D13**
The inactivity threshold, daytime window, and auto-activation check behavior are configurable by the caregiver per day of week (e.g., different thresholds for weekends when family visits).

---

### 1.5 Repetition and Confusion Detection

**FR-D14**
The system must detect **repetition loops**: when the user asks the same or semantically equivalent question three or more times within a 30-minute window. Detection is based on intent classification similarity, not exact text matching.

**FR-D15**
When a repetition loop is detected:
- (a) On repetition #3: the assistant answers the question with a calming, simplified response, then gently redirects: "It's still Tuesday, Aama. Aarav will call you at 4pm. Would you like to hear some music?"
- (b) On repetition #5: the assistant answers, then adds: "I'll let Aarav know you're thinking of him." A low-priority "repetition detected" event is logged.
- (c) On repetition #7: the assistant answers briefly, then sends a "possible confusion episode" notification to the caregiver. The notification includes the question topic (not the full transcript) and the repetition count.

All repetition thresholds (3, 5, 7) and the 30-minute window are configurable by the caregiver.

**FR-D16**
When a repetition loop is detected, the assistant must NOT:
- Show frustration, irritation, or impatience in its tone or wording
- Say "you already asked that" or "I already told you"
- Refuse to answer
- Go silent

---

### 1.6 Authentication — Dementia-Friendly Fallback

**FR-D17**
The PIN fallback mechanism (FR-014) is supplemented with a **caregiver remote override** path. If both voice biometric and PIN authentication fail (voice biometric locked out after 3 failures AND PIN incorrect after maximum attempts as defined by the PIN lockout policy), the system must:
- (a) Announce: "I'm having trouble recognizing you. Let me ask [caregiver name] to help."
- (b) Send a "authentication override request" to the caregiver via the companion app
- (c) Display a screen notification on the primary device: "[Caregiver name] has been asked to help. Please wait."
- (d) When the caregiver approves via the companion app, the system executes the requested command and announces: "[Caregiver name] has approved this. [Proceed with command]."
- (e) If the caregiver denies or does not respond within 30 minutes, the command is not executed

**FR-D18**
The caregiver override is valid for a single command only. Each sensitive command requires a fresh override or successful authentication. The override is scoped to the specific command type (call, health data access, config change) that triggered the authentication requirement.

**FR-D19**
The companion app must support a **caregiver presence mode**: when the caregiver is physically present, they can authenticate on the device using their own biometric (fingerprint/face) stored on the device, bypassing the voice biometric + PIN path entirely. This is for setup, re-enrolment, and in-person assistance sessions.

---

### 1.7 Emergency Response — Dementia-Specific Adjustments

**FR-D20**
The emergency countdown duration (FR-033) is configurable by the caregiver, with a range of 30-120 seconds and a default of 60 seconds for users with documented cognitive impairment.

*Rationale:* 30 seconds is appropriate for a cognitively intact person. Someone with moderate dementia may need 10-15 seconds to process the announcement plus additional time to formulate a response. A 60-second default provides a safety margin without materially delaying emergency response.

**FR-D21**
During the emergency countdown, the assistant must repeat the cancellation instruction every 15 seconds, using the same simple words each time (e.g., "Say Cancel to stop the call" — not rephrased differently each time).

*Rationale:* Consistent, repeated phrasing reduces cognitive load. Varying the wording ("cancel," "stop," "abort," "discontinue") introduces confusion.

**FR-D22**
The assistant must support a caregiver-configured **simple cancel word** (default: the word "Cancel" spoken clearly). The caregiver may set an alternative word if the primary user finds another word easier to produce under stress (e.g., "No," "Stop," or a Nepali equivalent like "Haina").

---

### 1.8 Voice Interaction — Dementia Adaptation

**FR-D23**
All assistant responses must follow these rules:
- (a) One idea per sentence. Compound sentences are broken into separate TTS utterances with a 1.5-second pause between them.
- (b) Never present multiple options in a single utterance. Instead of "Would you like to call Aarav or listen to music?", the assistant says "Would you like to call Aarav?" and, only after receiving a response, offers the next option if needed.
- (c) Closed questions preferred over open questions. "Would you like me to call Aarav?" rather than "Who would you like to call?"
- (d) No rhetorical questions, no sarcasm, no idioms, no metaphors.
- (e) All time references are absolute and anchored: "Your medication is at 2 o'clock this afternoon" not "Your medication is in 3 hours."

**FR-D24**
The assistant must never say phrases that could cause anxiety in a confused person, including but not limited to:
- "You already asked me that"
- "Don't you remember?"
- "I told you earlier"
- "You're confused"
- "That doesn't make sense"

The full list of prohibited phrases must be documented in the TTS response template review.

**FR-D25**
When the assistant cannot understand the user after two STT attempts (low confidence or timeout), it must:
- (a) NOT say "I don't understand" (which can cause frustration)
- (b) Instead say a calming phrase like "Let's try again. Take your time." and re-activate listening
- (c) After a third failed attempt, say "That's okay. Let's try again later." and return to IDLE — do NOT keep the user in a failure loop

---

### 1.9 Daily Routines — Exercise and Activity Guidance

**FR-D26**
The system must support caregiver-configured **routine blocks** — named sequences of reminders and guidance steps that form a daily activity. A routine block has:
- A name (e.g., "Morning exercise")
- A scheduled time
- A sequence of steps, each with: a spoken instruction, an expected duration, and an optional follow-up prompt
- A completion condition (all steps delivered, or user says "Done" at any point)

*Example routine block:*
```
Name: "Morning chair exercises"
Scheduled: 07:30 daily
Steps:
  1. "Let's start with your ankles. Gently lift your toes up and down 10 times. I'll count." [pauses 30s]
  2. "Good. Now your shoulders. Slowly roll them forward 5 times." [pauses 20s]
  ...
```

**FR-D27**
Routine blocks are created and edited by the caregiver via the companion app. The companion app provides a simple step editor with pre-written templates for common routines (chair exercises, breathing exercises, stretching).

**FR-D28**
The system must support a caregiver-configured **meal prompt routine** at meal times. The assistant announces the meal time, asks if the user has eaten, and if the user says "No" or does not respond, reminds them of what was planned (if configured) and suggests simple food options.

**FR-D29**
The system must support a caregiver-configured **hydration reminder** independent of meal reminders. Default: every 2 hours during the daytime window (07:00-21:00), the assistant announces a brief hydration prompt: "Aama, please have some water."

*Rationale:* Dehydration is among the leading causes of preventable hospitalization in elderly people with dementia. Hydration reminders are a low-cost, high-impact safety feature.

---

### 1.10 Companion App — Caregiver Dashboard

**FR-D30**
The companion app must provide a **daily status dashboard** showing at a glance:
- (a) Medication status for the day (TAKEN / MISSED / PENDING for each scheduled dose)
- (b) Last interaction time ("Last spoke to assistant: 2:15pm")
- (c) Any active alerts (inactivity, confusion episode, missed dose, double-dose attempt, health threshold breach)
- (d) Battery level of the primary device (low battery = assistant unavailable = safety risk)

**FR-D31**
The companion app must support the caregiver remotely triggering a **wellness check call**. When triggered, the primary device announces: "[Caregiver name] is checking in on you. They'd like you to say something so they know you're okay." The assistant then listens for any speech for 30 seconds and relays a confirmation (presence detected / no response) back to the companion app.

---

## 2. Non-Functional Requirements — Dementia-Specific

### 2.1 Voice Interaction Quality

**NFR-D01**
TTS speech rate: default speed must be configurable by the caregiver in the range 0.7x-1.5x of normal speech rate. The out-of-box default for dementia-configured profiles is 0.85x (slightly slower than normal).

**NFR-D02**
Inter-sentence pause duration: the system must insert a minimum 1.5-second pause between separate TTS sentences. This is a hard minimum, not an average.

**NFR-D03**
All TTS responses, including those generated by the LLM, must pass through a post-generation filter that enforces FR-D23 (one idea per sentence, no multiple options, no prohibited phrases). Responses that violate these rules trigger a regeneration with stricter constraints, not a silent fallback to the violating response.

### 2.2 Reliability — Dementia Safety Paths

**NFR-D04**
The double-dose detection path (FR-D03) is classified as safety-critical. It must have 100% unit test coverage and integration tests that simulate the scenario: user acknowledges medication → user attempts to acknowledge the same medication within the double-dose window.

**NFR-D05**
The inactivity detection path (FR-D12) is classified as safety-critical. It must be tested end-to-end: simulate no interaction for the threshold period → verify wellness check activation → simulate no response → verify caregiver alert sent.

**NFR-D06**
The caregiver override path (FR-D17) must complete an end-to-end authorization within 60 seconds of the caregiver tapping "Approve" in the companion app (measured from companion app approval to primary device command execution, assuming both devices are online).

### 2.3 Privacy

**NFR-D07**
Interaction presence data (timestamps of last interaction, but NOT transcripts) may be transmitted to the companion app for the caregiver dashboard. Full conversation transcripts remain on-device only and are never transmitted.

**NFR-D08**
Repetition alerts sent to the caregiver (FR-D15) must include the topic category (e.g., "asking about family member") but NOT the user's full utterance. The utterance content remains on-device.

### 2.4 Usability — Dementia

**NFR-D09**
The assistant must not require the user to remember any command vocabulary beyond:
- The wake word (or respond to auto-activation)
- "Yes" / "No" (or their Nepali equivalents "Ho" / "Hoina")
- "Done" or "Taken" (for acknowledgements)
- "Cancel" (or caregiver-configured alternative, for emergency stop)
- "Call [name]" where [name] is a family member's name

Any interaction that requires more than these five vocabulary items is a design failure.

**NFR-D10**
The primary device UI (settings, onboarding screens) is not designed for the person with dementia. All configuration, setup, and management functions are accessed via the companion app or by a caregiver physically present at the device using caregiver presence mode (FR-D19). The primary device's in-app UI may be minimal but must not be the only path to any essential function.

---

## 3. Gherkin Acceptance Criteria

### Feature: Double-Dose Prevention (FR-D01, FR-D02, FR-D03)

```gherkin
Feature: Medication double-dose prevention
  As a caregiver
  I want the assistant to prevent the user from taking medication twice
  So that my parent is not harmed by an accidental overdose

  Scenario: User acknowledges medication — confirmation challenge issued
    Given the medication schedule has "Amlodipine" due at 08:00
    And the caregiver has configured a description "small white tablet in the blue box"
    When the reminder fires at 08:00
    And the user says "Taken"
    Then the assistant must ask "You said you've taken your Amlodipine. Is that the small white tablet in the blue box?"
    And the dose must NOT yet be recorded as taken

  Scenario: User confirms the challenge — dose recorded
    Given the assistant has issued the confirmation challenge
    When the user says "Yes" within 30 seconds
    Then the dose must be recorded as taken with timestamp
    And no further reminders for this dose must fire

  Scenario: User denies the challenge — dose not recorded, reminder re-enters escalation
    Given the assistant has issued the confirmation challenge
    When the user says "No"
    Then the dose must NOT be recorded as taken
    And the assistant must say "That's okay. I'll remind you again in a few minutes."
    And the reminder must re-enter the escalation sequence at the next re-fire interval

  Scenario: User does not respond to challenge — dose not recorded
    Given the assistant has issued the confirmation challenge
    And the user does not respond
    When 30 seconds elapse
    Then the dose must NOT be recorded as taken
    And the reminder must re-enter the escalation sequence at the next re-fire interval

  Scenario: User attempts to acknowledge same medication twice — double-dose blocked
    Given the medication "Amlodipine" was recorded as taken at 08:05 today
    And the double-dose window is configured as 4 hours
    When at 09:00 the user says "I need to take my Amlodipine"
    And the assistant recognizes this as a medication acknowledgment intent
    Then the assistant must say "You already took your Amlodipine earlier today. Let me check with Aarav."
    And a second dose must NOT be recorded
    And a "possible double-dose attempt" alert must be sent to the caregiver via the companion app
```

---

### Feature: Photo Verification of Medication Intake (FR-D04a, FR-D04b, FR-D04c, FR-D04d, FR-D04e)

```gherkin
Feature: Photo verification of medication intake
  As a caregiver
  I want to see a photo confirming my parent has taken their medication
  So that I can be confident the dose was actually taken, not just acknowledged

  Scenario: Photo verification captures and delivers image on acknowledgment
    Given photo verification is enabled for "Amlodipine"
    And the medication reminder has fired
    When the user acknowledges the reminder and passes the confirmation challenge
    Then the assistant must announce "Please show me your empty hand"
    And the front camera must capture a single still image
    And the image must be compressed to a maximum of 200 KB
    And the image must be transmitted to the companion app via the E2E encrypted channel
    And the image must be deleted from the primary device within 1 hour of successful delivery

  Scenario: Camera unavailable — graceful fallback to voice confirmation only
    Given photo verification is enabled for "Amlodipine"
    And the device camera is unavailable (hardware failure or permissions revoked)
    When the user acknowledges the reminder and passes the confirmation challenge
    Then the assistant must fall back to voice confirmation only
    And the acknowledgment must still be recorded
    And a "photo unavailable" indicator must be sent to the caregiver alongside the acknowledgment

  Scenario: Photo verification disabled for low-risk medication — voice confirmation only
    Given photo verification is disabled for "Vitamin D" by caregiver configuration
    When the user acknowledges the Vitamin D reminder
    Then no camera must be activated
    And the voice confirmation challenge alone is sufficient to record the dose

  Scenario: Caregiver views verification photo in adherence timeline
    Given a medication acknowledgment with photo verification has been recorded
    When the caregiver opens the companion app adherence timeline
    Then the acknowledgment must show the medication name, scheduled time, and acknowledgment timestamp
    And a thumbnail of the verification photo must be displayed
    And the caregiver must be able to tap to view the photo full-size

  Scenario: Photo never stored on relay server
    Given a verification photo is captured on the primary device
    When the photo is transmitted to the companion app
    Then the relay server must never store the photo payload
    And the encrypted photo must pass through the relay as an opaque envelope only
```

---

### Feature: Inactivity Wellness Check (FR-D11, FR-D12)

```gherkin
Feature: Inactivity detection and wellness check
  As a caregiver
  I want to be alerted if my parent has not interacted with the assistant
  So that I can check on them if something might be wrong

  Scenario: No interaction for threshold period — wellness check fires
    Given the daytime window is configured as 07:00-21:00
    And the inactivity threshold is configured as 4 hours
    And the last user interaction was at 08:30
    When the current time reaches 12:30
    Then the assistant must activate and announce "Good afternoon, Aama. Are you doing okay?"
    And must listen for any verbal response for 30 seconds

  Scenario: User responds to wellness check — no alert sent
    Given the wellness check has been triggered
    When the user says anything within 30 seconds
    Then the interaction timestamp must be updated
    And no caregiver alert must be sent

  Scenario: User does not respond to wellness check — caregiver alerted
    Given the wellness check has been triggered
    And the user does not respond
    When 30 seconds elapse
    Then a high-priority "inactivity alert" must be sent to the caregiver
    And the alert must include the time of last known interaction (08:30)

  Scenario: Interaction resets the inactivity timer
    Given the inactivity threshold is 4 hours
    And the user activates the assistant at 10:00 (via wake word or voice command)
    When the interaction completes
    Then the inactivity timer must reset
    And the next wellness check must be scheduled no earlier than 14:00
```

---

### Feature: Repetition Detection (FR-D14, FR-D15)

```gherkin
Feature: Repetition loop detection
  As a caregiver
  I want to know when my parent is repeatedly asking the same question
  So that I can assess whether they are having a confusion episode

  Scenario: User repeats question 3 times in 30 minutes — gentle redirection
    Given the user has asked "When is Aarav coming?" twice within the last 20 minutes
    When the user asks "When is Aarav coming?" a third time
    Then the assistant must answer the question calmly
    And must add a gentle redirection like "Would you like to hear some music?"
    And must NOT say "You already asked that"

  Scenario: User repeats question 5 times in 30 minutes — event logged
    Given the user has asked the same question 4 times within 30 minutes
    When the user asks the same question a 5th time
    Then the assistant must answer briefly
    And must say "I'll let Aarav know you're thinking of him."
    And a "repetition detected" event must be logged

  Scenario: User repeats question 7 times in 30 minutes — caregiver notified
    Given the user has asked the same question 6 times within 30 minutes
    When the user asks the same question a 7th time
    Then the assistant must answer briefly
    And must send a "possible confusion episode" notification to the caregiver
    And the notification must include the question topic (not the full transcript) and repetition count
```

---

### Feature: Caregiver Remote Authentication Override (FR-D17, FR-D18)

```gherkin
Feature: Caregiver remote override when authentication fails
  As a caregiver
  I want to remotely authorize a command when my parent cannot authenticate
  So that they are not locked out of calling for help

  Scenario: Both biometric and PIN fail — caregiver override requested
    Given the user's voice biometric has failed 3 times (locked out)
    And the user's PIN has been entered incorrectly the maximum number of times
    When the user attempts a sensitive command (e.g. "Call Aarav on Messenger")
    Then the assistant must say "I'm having trouble recognizing you. Let me ask Aarav to help."
    And an authentication override request must be sent to the caregiver's companion app

  Scenario: Caregiver approves override — command executed
    Given an authentication override request is pending
    When the caregiver taps "Approve" in the companion app
    Then the primary device must execute the requested command within 60 seconds
    And the assistant must announce "Aarav has approved this. Calling now."

  Scenario: Caregiver denies override — command not executed
    Given an authentication override request is pending
    When the caregiver taps "Deny" in the companion app
    Then the command must not be executed
    And the assistant must announce "Aarav was not able to approve this right now."

  Scenario: Caregiver does not respond within 30 minutes — override expires
    Given an authentication override request is pending
    And the caregiver does not respond
    When 30 minutes elapse
    Then the override request must expire
    And the command must not be executed
```

---

### Feature: Daily Orientation Briefing (FR-D08, FR-D09)

```gherkin
Feature: Daily orientation briefing
  As a caregiver
  I want the assistant to orient my parent to the day each morning
  So that they feel grounded and less anxious

  Scenario: First morning activation triggers orientation briefing
    Given the orientation briefing window is configured as 05:00-12:00
    And no briefing has been delivered today
    When the user activates the assistant at 08:00 (wake word or auto-activation)
    Then the assistant must deliver the orientation briefing before responding to any command
    And the briefing must include the day, date, and number of events today
    And total briefing length must not exceed 45 seconds of TTS

  Scenario: Briefing delivered only once per day
    Given the orientation briefing was delivered at 08:00 today
    When the user activates the assistant again at 10:00
    Then the assistant must NOT repeat the orientation briefing
    And must proceed directly to the user's command

  Scenario: Activation outside briefing window — no briefing
    Given the orientation briefing window is configured as 05:00-12:00
    And no briefing has been delivered today
    When the user activates the assistant at 14:00
    Then the assistant must NOT deliver the orientation briefing
```

---

### Feature: Emergency Countdown — Dementia-Adjusted (FR-D20, FR-D21)

```gherkin
Feature: Dementia-adjusted emergency countdown
  As a caregiver
  I want the emergency countdown to give my parent enough time to process and respond
  So that a false emergency call is not triggered because they needed more time to speak

  Scenario: Emergency countdown uses configured duration
    Given the caregiver has configured the emergency countdown to 60 seconds
    When a health threshold breach triggers the emergency response
    Then the countdown must be 60 seconds, not the standard 30 seconds

  Scenario: Cancellation instruction repeated every 15 seconds
    Given the emergency countdown is active with 45 seconds remaining
    When 15 seconds have elapsed
    Then the assistant must repeat the cancellation instruction
    And must use the same exact wording each time
    And the user must be able to cancel at any point during the countdown
```

---

## 4. Integration Notes — Changes to Baseline Requirements

### 4.1 Baseline Requirements Modified

| Baseline Requirement | Change |
|---------------------|--------|
| FR-013 (PIN fallback only) | Supplemented by FR-D17 (caregiver remote override as third path after biometric + PIN failure) |
| FR-027 (medication re-fire escalation) | Supplemented by FR-D01 (confirmation challenge required before dose recorded), FR-D03 (double-dose detection), and FR-D04a through FR-D04e (photo verification of intake) |
| FR-033 (emergency countdown) | Modified by FR-D20 (configurable duration 30-120s, default 60s for dementia users) |
| FR-014 (PIN storage) | Supplemented by FR-D17 (caregiver override path when PIN is inaccessible) |
| — (new) | FR-D04a through FR-D04e add photo verification of medication intake with on-device presence check, E2E encrypted delivery, and graceful fallback to voice-only confirmation |

### 4.2 Baseline Requirements Superseded

| Baseline Requirement | Superseded By | Reason |
|---------------------|---------------|--------|
| None | — | All baseline requirements remain valid. Dementia requirements are additive. |

### 4.3 New Safety-Critical Paths

The following new paths are classified as safety-critical and must meet NFR-026 (100% unit test coverage + integration tests):

1. Double-dose detection and prevention (FR-D03)
2. Photo verification capture and delivery (FR-D04a, FR-D04b) — the capture→encrypt→deliver→delete chain must not fail silently
3. Inactivity detection → wellness check → caregiver alert (FR-D12)
4. Caregiver remote authentication override (FR-D17)

### 4.4 Confidence Threshold Increase

The implementation confidence threshold for all dementia-specific safety paths (FR-D01, FR-D02, FR-D03, FR-D04a, FR-D04b, FR-D11, FR-D12, FR-D17) is **0.90** (raised from the baseline 0.85 for general safety-critical code). The higher bar reflects the direct risk of harm to a vulnerable user.

---

## 5. Out of Scope — Deliberately Deferred

These features are explicitly excluded from the MVP. They are noted here so the architecture does not block them, but they must not be implemented now.

| Item | Reason for deferral |
|------|-------------------|
| Location / geofencing for wandering detection | Requires GPS background monitoring, significant battery impact, and complex caregiver UX for safe zones. Architecture should reserve a location plugin slot. |
| Fall detection integration | Redundant with Apple Watch / medical alert devices that already handle this well. Assistant focuses on cognitive support. |
| Mood/affect detection from voice | Research-grade feature; models not reliable enough across Nepali speakers for safety-critical use. |
| — | — |
| Multi-user voice profiles on one device | Single primary user per device in MVP. Spouse/visitor detection is a post-MVP feature. |
| Cognitive assessment scoring (e.g., MMSE-style interaction tests) | Clinical responsibility, not an app feature. Could cause harm if misinterpreted. |
| Automated caregiver escalation based on interaction pattern trends | Requires trend analysis across days/weeks — MVP focuses on same-day detection. |

---

## 6. Traceability — Dementia Requirements to Risks

| Requirement(s) | Risk Addressed |
|---------------|---------------|
| FR-D01, FR-D02, FR-D03, FR-D04a, FR-D04b, FR-D04c, FR-D04d, FR-D04e | Double-dosing causing hypotension, falls, hospitalization; caregiver unable to verify medication was actually taken |
| FR-D05, FR-D06, FR-D07 | User cannot recall wake word → assistant inaccessible |
| FR-D08, FR-D09 | Time/place disorientation causing anxiety |
| FR-D11, FR-D12, FR-D13 | User fallen or unconscious with no one aware |
| FR-D14, FR-D15, FR-D16 | Confusion episode undetected by caregiver → escalating distress |
| FR-D17, FR-D18, FR-D19 | Authentication failure locking user out of emergency calls |
| FR-D20, FR-D21, FR-D22 | False emergency dispatch because user needed more processing time |
| FR-D23, FR-D24, FR-D25, NFR-D01, NFR-D02, NFR-D03 | Voice interaction patterns causing confusion or distress |
| FR-D26, FR-D27, FR-D28, FR-D29 | Physical deconditioning, dehydration, missed meals |
| FR-D30, FR-D31 | Caregiver unaware of daily status → delayed intervention |

---

*This document is a supplement to `requirements.md`. Both documents together form the complete requirements baseline. Where they conflict, this document takes precedence for dementia-specific concerns.*
