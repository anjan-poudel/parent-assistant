# Personal OS Enhancement Proposals

## Status

Product and implementation proposals for the iOS voice-driven personal operating system. Android is out of scope for this document.

## Product thesis

The strongest marketing position is not “an AI assistant for seniors.” It is:

> **One trusted voice interface for everyday life, in the user's own language, with family support when needed.**

The product should make the iPhone feel less like a collection of unfamiliar apps and more like a calm, voice-driven operating system:

- “What do I need to do today?”
- “Remind me to buy rice tomorrow.”
- “Add milk to the shopping list.”
- “Arrange my weekly grocery pickup.”
- “Call my daughter.”
- “What is next?”
- “Help me use the television.”
- “Tell my caregiver I need help.”

The product's differentiation comes from the combination of:

1. Voice-first operation for most daily tasks.
2. Nepali and other underserved-language support.
3. A unified daily-life model across reminders, lists, routines, calendar, calls, errands, and home devices.
4. Local-first operation for essential tasks.
5. A caregiver layer for setup, oversight, and exception handling.
6. Honest handoff to existing iOS apps and providers instead of pretending to replace them.

---

## 1. Product principles

### 1.1 Voice is the primary interface

Every feature should have a voice path for:

- Create.
- Read.
- Update.
- Complete.
- Cancel.
- Reschedule.
- Ask for help.

Touch remains useful for confirmation, visual review, and caregiver setup, but it must not be the only way to operate the feature.

### 1.2 The assistant owns the user's mental model

The user should not need to know whether an item lives in Calendar, Reminders, a plugin database, a provider app, or the caregiver system.

The assistant should answer from a unified model:

```text
Today
  - medication
  - appointments
  - routines
  - errands
  - shopping pickups
  - personal tasks
  - family calls
```

The underlying systems remain separate where reliability or privacy requires it. The spoken experience should feel unified.

### 1.3 Core safety is not a plugin

The existing plugin architecture correctly keeps medication, emergency detection, and safety-critical reminders in core. Preserve that boundary.

Plugins should add optional capabilities such as:

- Shopping.
- Personal tasks.
- Home control.
- Appliance help.
- Cultural calendars.
- Provider handoffs.

A plugin may fail, be disabled, be unavailable for a locale, or lose network access. None of those conditions may disable emergency calling, medication acknowledgement, or local safety reminders.

### 1.4 Local-first, provider-aware

The app should remain useful without a provider account or network connection:

- Lists are local.
- Tasks are local.
- Schedules are local.
- Spoken queries are local where the intent is closed-vocabulary.
- Provider integration is an optional fulfillment layer.

Provider integrations can prepare carts, open apps, create pickup requests, or schedule handoffs, but they must not make unsupported claims about completion.

### 1.5 Payments stay outside the app

The app should not store payment cards, bank credentials, wallet secrets, or payment authorization tokens for shopping.

The app may:

- Build a shopping list.
- Group items by store or provider.
- Prepare a cart where an official provider API supports it.
- Schedule a delivery or pickup reminder.
- Open the provider's official app or website.
- Tell the user exactly what remains to be completed externally.

The app must not say “your order is placed” unless a documented provider API returns a confirmed order identifier.

---

## 2. Marketing pillars

### Pillar A: “Your day, in your voice”

The assistant answers “what next?” across all personal-life modules. This is more compelling than a list of isolated features.

### Pillar B: “Works in the language you think in”

Nepali should not be treated as a translation layer over an English product. Each feature needs:

- Nepali intent examples.
- Nepali date/time vocabulary.
- Nepali confirmation language.
- Localized item names and categories.
- Dialect-tolerant synonyms.
- Native-script and transliterated input handling where practical.

The plugin architecture's locale gating is a good foundation for geography and language-specific features.

### Pillar C: “Family peace of mind without taking over”

The parent remains in control of daily use. Caregivers can configure, assist, receive alerts, and manage exceptions without turning every operation into a caregiver workflow.

### Pillar D: “Helpful, not pretending”

The app should clearly distinguish:

- Saved locally.
- Scheduled locally.
- Prepared for handoff.
- Opened in another app.
- Confirmed by an external provider.
- Failed or unavailable.

This honesty is especially important for shopping, payments, transportation, health, and emergency features.

---

## 3. Priority feature portfolio

### Tier 1: build first

1. Shopping List plugin.
2. Personal Todo plugin.
3. “My Day” unified briefing and planner.
4. Shared caregiver-managed lists and tasks.
5. Recurring shopping and household schedules.
6. Better voice correction and confirmation flows.

### Tier 2: strong differentiation

7. HomeKit voice control.
8. Pharmacy and household refill reminders.
9. Errand and pickup planner.
10. Family check-ins and simple social routines.
11. Trusted personal memory.
12. Voice-first document and message helper.

### Tier 3: provider expansion

13. Grocery provider adapters.
14. Pharmacy provider adapters.
15. Delivery and pickup handoffs.
16. Transportation handoffs.
17. Package and appointment tracking.
18. Apple Watch check-ins and complications.

Tier 1 should be mostly local and testable. Tier 3 should remain optional and provider-specific.

---

# 4. Shopping List plugin

## 4.1 User promise

> “Tell Sahayak what you need. It remembers, organizes, and reminds you. When you are ready, it helps you hand the list to the store or arrange a pickup without handling your payment.”

## 4.2 Voice examples

English:

- “Add rice to my shopping list.”
- “Add two bottles of cooking oil.”
- “What is on my shopping list?”
- “Remove milk.”
- “Mark rice as bought.”
- “Create a weekly grocery list.”
- “Remind me every Saturday morning to review shopping.”
- “Arrange a grocery pickup for tomorrow afternoon.”
- “Use the family grocery store.”
- “Open the shopping provider.”
- “I bought everything except tea.”

Nepali examples should be added as real training/evaluation data rather than translated documentation only:

- “मेरो किनमेल सूचीमा चामल थप।”
- “आजको किनमेल सूची पढ।”
- “दूध किनेँ, सूचीबाट हटाऊ।”
- “हरेक शनिबार बजारको सम्झना गराऊ।”

## 4.3 Core data model

```swift
struct ShoppingList: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var items: [ShoppingItem]
    var isSharedWithCaregiver: Bool
    var updatedAt: Date
}

struct ShoppingItem: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var quantity: Decimal?
    var unit: String?
    var category: ShoppingCategory
    var notes: String?
    var preferredProviderID: String?
    var state: ShoppingItemState
    var addedAt: Date
    var completedAt: Date?
}

enum ShoppingItemState: String, Codable {
    case needed
    case prepared
    case handedOff
    case completed
    case unavailable
}
```

Do not over-interpret free-form item names into products unless a provider confirms the mapping. “Rice” is a valid list item even when there is no product catalog match.

## 4.4 List behavior

Support:

- Multiple lists: groceries, pharmacy, household, festival, travel.
- Default list for simple commands.
- Quantity and units.
- Categories.
- Notes and brand preferences.
- Item aliases and pronunciation hints.
- Mark bought, remove, restore, and clear.
- Shared caregiver visibility.
- Local history of changes.
- Optional recurring templates.

Avoid silent destructive behavior. “Clear the shopping list” should require confirmation and offer a recovery window.

## 4.5 Shopping schedules

Shopping schedules are local recurring plans, not orders.

```swift
struct ShoppingSchedule: Codable, Identifiable, Equatable {
    let id: UUID
    var listID: UUID
    var recurrence: RecurrenceRule
    var preferredWindow: TimeWindow?
    var fulfillmentMode: FulfillmentMode
    var providerID: String?
    var reminderLeadMinutes: Int
    var enabled: Bool
}

enum FulfillmentMode: String, Codable {
    case reviewOnly
    case pickup
    case delivery
    case inStore
}
```

Examples:

- Every Saturday at 10:00: remind the user to review groceries.
- Every first Monday: remind the caregiver to review pharmacy supplies.
- Every Wednesday afternoon: open the configured grocery provider.
- Tomorrow at 15:00: remind the user that a pickup is scheduled.

A schedule may create a reminder, open a provider app, or prepare a handoff. It must not silently purchase anything.

## 4.6 Provider integration model

Use an adapter protocol:

```swift
protocol ShoppingProvider {
    var providerID: String { get }
    var displayNameKey: String { get }
    var supportedModes: Set<FulfillmentMode> { get }

    func prepareCart(items: [ShoppingItem]) async throws -> PreparedShoppingCart
    func openCheckout(for cart: PreparedShoppingCart) async throws
    func schedulePickup(_ request: PickupRequest) async throws -> PickupHandoff
}
```

Provider states should be explicit:

```text
localList
cartPrepared
providerOpened
pickupRequestPrepared
externalConfirmationRequired
confirmedByProvider
failed
```

The app may only move to `confirmedByProvider` when the provider returns a real confirmation. Opening a URL is not confirmation.

### Initial provider strategy

Do not start by integrating multiple grocery platforms. Start with:

1. Local-only list and schedules.
2. A generic “open configured provider” handoff.
3. One provider adapter only if it has a supported public API or reliable official deep link.

Avoid scraping websites or automating payment pages. That creates reliability, privacy, and App Store risk.

## 4.7 Caregiver features

The caregiver app may:

- Create or edit shared lists.
- Add recurring shopping schedules.
- Configure preferred provider.
- Set a default store or pickup location.
- See whether the parent reviewed the list.
- Mark an item as urgent or important.
- Receive a “shopping help requested” alert.

The caregiver app must not silently modify the parent's active list without a visible change history.

## 4.8 Marketing surface

A compelling demo:

```text
User: “Add rice, lentils, tea, and two kilos of potatoes to my Saturday list.”

Assistant: “I added four items to your Saturday shopping list. Would you like
me to remind you Friday evening to review it?”

User: “Yes.”

Assistant: “Done. I will remind you Friday at six.”
```

This is useful without payments, provider APIs, or cloud dependency.

---

# 5. Personal Todo plugin

## 5.1 Boundary with existing routines

The current `RoutinePlugin` already supports recurring reminders such as walking, meals, bedtime, and calls. Preserve a clear distinction:

- **Medication**: safety-critical core, acknowledgement and escalation.
- **Routine**: recurring time-based activity, non-safety-critical.
- **Todo**: discrete task that can be created, delegated, completed, postponed, or cancelled.
- **Calendar**: event with a time/place/attendee semantics.
- **Shopping**: item-oriented list and fulfillment schedule.

A todo can have a due date without being a repeating routine.

## 5.2 Voice examples

- “Remind me to call the dentist tomorrow.”
- “What do I need to do today?”
- “Mark call the dentist as done.”
- “Move that task to Friday.”
- “Give this task to my caregiver.”
- “What did I postpone?”
- “Add ‘take the documents to the bank’ to my errands.”
- “I cannot do this today; move it to next week.”

## 5.3 Data model

```swift
struct TodoItem: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var notes: String?
    var dueAt: Date?
    var recurrence: RecurrenceRule?
    var priority: TodoPriority
    var context: TodoContext
    var state: TodoState
    var assignedTo: TodoAssignee
    var createdAt: Date
    var completedAt: Date?
    var source: TodoSource
}
```

Support:

- Inbox capture without a due date.
- Today, upcoming, overdue, and completed views.
- Recurring tasks.
- Contexts: home, errands, phone, family, documents.
- Delegation to caregiver.
- Snooze/postpone.
- Voice correction.
- Confirmation for destructive actions.

## 5.4 Caregiver collaboration

The caregiver app may:

- Assign a task to the parent.
- Add a due date.
- See completion state.
- Mark a task as caregiver-owned.
- Send a gentle reminder.
- Reassign or cancel a task.

The parent should be able to say:

- “I finished it.”
- “Not today.”
- “Ask my son to help.”
- “What is this task about?”

The task should not become a surveillance mechanism. Caregiver visibility should be explicit and configurable.

## 5.5 Marketing surface

The strongest message is not “task management.” It is:

> “Nothing important gets lost just because it is hard to type or remember.”

---

# 6. “My Day” personal OS layer

This should become the product's most visible cross-feature experience.

## 6.1 Voice commands

- “What is my day like?”
- “What is next?”
- “What have I missed?”
- “What should I do before lunch?”
- “Read my appointments and shopping plans.”
- “What do I need to prepare for tomorrow?”

## 6.2 Unified day model

Aggregate, without merging ownership:

- Medication reminders.
- Routine occurrences.
- Calendar events.
- Imported Reminders items.
- Todo items.
- Shopping schedules.
- Family check-ins.
- Travel/errand plans.
- Health monitoring status.

Every item needs a source label internally, but the voice response should be concise and natural.

## 6.3 Priority ordering

Use deterministic ordering:

1. Immediate safety or medication.
2. Time-sensitive appointment or pickup.
3. Overdue task.
4. Next routine.
5. Shopping or errand reminder.
6. Optional suggestion.

Do not let an LLM decide safety priority. The planner can use an LLM for wording only after deterministic ordering is complete.

## 6.4 Daily briefing

Offer an opt-in morning briefing:

```text
Good morning. You have one medicine at eight, a doctor's appointment at eleven,
and groceries to review this evening. Your daughter asked you to call her today.
```

Allow the user to control:

- Time.
- Length.
- Categories.
- Language.
- Voice speed.
- Whether health information is included.

---

# 7. Additional high-value plugins

## 7.1 HomeKit comfort and safety plugin

Voice control of safe, non-medical HomeKit actions:

- Turn lights on/off.
- Adjust thermostat.
- Open or close blinds.
- Set a scene such as “bedtime” or “morning.”
- Ask whether a light or appliance is on.

Commands:

- “Turn on the bedroom light.”
- “Make the living room warmer.”
- “Set bedtime.”

Safety boundaries:

- Require confirmation for locks, garage doors, ovens, or high-risk devices.
- Keep a visible action history.
- Fail honestly when the home hub is unavailable.
- Do not expose arbitrary device control to generated commands.

Marketing value: the phone becomes a voice remote for the home, not just a reminder app.

## 7.2 Pharmacy and household refill plugin

This should start as reminders, not transactions:

- “Remind me to ask the pharmacy for a refill.”
- “How many days of supplies are left?”
- “Add blood-pressure tablets to the refill list.”
- “Tell my caregiver I need a refill.”

Later provider handoff may open a pharmacy app or create a refill request where officially supported. Payments remain external.

Medication content remains connected to the core medication model and must not be duplicated in a non-safety plugin.

## 7.3 Errands and pickup planner

Unify:

- Grocery pickup.
- Pharmacy pickup.
- Doctor appointment preparation.
- Library or bank errands.
- Transport reminders.

Voice example:

> “On Friday I need to go to the pharmacy and the bank. Remind me to take my wallet and prescription.”

This can use existing saved places and navigation services. The planner should create a task bundle and optional route, not promise transport availability.

## 7.4 Family check-in plugin

A simple, non-surveillance social routine:

- Scheduled “call family” reminder.
- One-command check-in message.
- “I am okay” status.
- “I need help” escalation.
- Caregiver-requested check-in.
- Missed check-in alert with clear policy and retry behavior.

Voice examples:

- “Tell my daughter I am okay.”
- “Call my son.”
- “Remind me to call my sister every Sunday.”

This feature is highly marketable because it connects independence with family reassurance.

## 7.5 Trusted personal memory

A bounded local memory system for user-approved facts:

- Names and relationships.
- Preferred pronunciations.
- Where important items are stored.
- Household routines.
- Appliance instructions.
- Questions to ask at the next doctor visit.
- Important dates.

Commands:

- “Remember that the spare keys are in the blue drawer.”
- “Where are the spare keys?”
- “Forget that memory.”
- “What did I want to ask the doctor?”

Privacy boundaries:

- Explicit “remember” command required for durable memory.
- Voice confirmation before storing sensitive facts.
- Per-memory deletion.
- No automatic storage of every conversation.
- Caregiver access disabled by default.

## 7.6 Document and message helper

Voice-first assistance for:

- Reading a letter aloud.
- Explaining a bill in simple language.
- Translating a message.
- Drafting an SMS or email.
- Reading back a drafted message before sending.
- Extracting an appointment date into Calendar after confirmation.

The user must approve any outbound message or calendar mutation. Photos and document cloud processing must remain a separately consented capability because it conflicts with the project's strict local-AI promise.

## 7.7 Cultural and language packs

Use the existing locale-gated plugin model for:

- Nepali calendar and festivals.
- Regional foods and shopping terms.
- Local holidays.
- Dialect vocabulary.
- Religious or cultural routines where explicitly enabled.
- Local emergency numbers and service vocabulary.

Each pack should contain:

- Intent examples.
- Entity aliases.
- Spoken response templates.
- Date/time conventions.
- Cultural terms.
- Evaluation corpus.

The app's long-term defensibility is likely to come from language and cultural fit, not from generic task CRUD.

---

# 8. Plugin architecture improvements required for scale

The current plugin design is a good starting point:

- Namespaced action names.
- Locale gating.
- Plugin-owned handling.
- Plugin-owned presentation.
- Collision detection.
- Core safety boundary.

To support Shopping and Todo cleanly, add the following deliberately.

## 8.1 Plugin capabilities

Each plugin should declare capabilities:

```swift
enum PluginCapability {
    case localStorage
    case notifications
    case calendar
    case contacts
    case location
    case network
    case externalAppHandoff
    case caregiverSync
}
```

The registry or configuration layer can then explain why a permission or network connection is needed.

## 8.2 Plugin metadata

Add metadata for a future caregiver configuration surface:

```swift
struct PluginMetadata {
    let pluginID: String
    let displayNameKey: String
    let version: Int
    let capabilities: Set<PluginCapability>
    let isUserDisableable: Bool
    let supportsCaregiverConfiguration: Bool
    let requiresNetwork: Bool
}
```

## 8.3 Plugin-specific storage

Use namespaced encrypted keys:

```text
plugin.shopping_list.v1
plugin.shopping_schedule.v1
plugin.todo.v1
plugin.personal_memory.v1
plugin.homekit.v1
```

Storage must be injected into the plugin. Do not make every plugin reach directly into `AppCoordinator`.

## 8.4 Confirmation policy

The current `PluginResult` shape is not sufficient for every future side effect. Add a result or policy that can represent:

- No confirmation required.
- Confirmation required before local mutation.
- Confirmation required before opening another app.
- Confirmation required before sending a message.
- Confirmation required before a provider handoff.
- Authentication required.

Shopping provider handoffs and HomeKit locks must never be treated like a spoken-only result.

## 8.5 Shared scheduling seam

`RoutineScheduler` already provides a useful non-safety scheduling shape. Avoid duplicating notification scheduling in every plugin.

Introduce a narrow protocol such as:

```swift
protocol NonCriticalReminderScheduling {
    func schedule(_ reminder: PluginReminder) async throws
    func cancel(id: UUID) async throws
}
```

The plugin owns its domain entry and identity. The shared scheduler owns OS notification mechanics.

Medication remains on its separate hardened scheduler.

## 8.6 Provider registry

Provider integrations should be adapters, not embedded in plugins:

```swift
protocol ProviderRegistry {
    func shoppingProvider(id: String) -> ShoppingProvider?
    func transportProvider(id: String) -> TransportProvider?
    func pharmacyProvider(id: String) -> PharmacyProvider?
}
```

This keeps the Shopping plugin useful when no provider is configured.

---

# 9. Voice intent design

## 9.1 Use one generic plugin action

Do not add `shoppingList`, `todo`, `homeKit`, and `pharmacy` cases to the core action enum.

Use namespaced actions:

```text
shopping.add_item
shopping.remove_item
shopping.query
shopping.complete_item
shopping.create_schedule
shopping.prepare_handoff
shopping.open_provider

todo.create
todo.query
todo.complete
todo.postpone
todo.assign

day.query
day.briefing
family.check_in
memory.remember
memory.recall
memory.forget
homekit.control
```

## 9.2 Entity schemas

Each plugin should define its own entity requirements.

Shopping:

```text
listName
itemName
quantity
unit
category
schedule
provider
fulfillmentMode
```

Todo:

```text
title
dueDate
dueTime
recurrence
priority
context
assignee
```

The parser must distinguish missing entities from uncertain entities. Do not silently guess a provider, date, quantity, or list.

## 9.3 Confirmation rules

Require confirmation for:

- Clearing a list.
- Deleting multiple tasks.
- Creating a provider handoff.
- Opening a checkout or order page.
- Sending a message to a caregiver.
- Controlling a lock, garage, oven, or other high-risk HomeKit device.

Do not require confirmation for:

- Adding one shopping item.
- Reading a list.
- Marking a task complete when the user explicitly says it is done.
- Scheduling a local non-critical reminder, except where ambiguity is high.

## 9.4 Disambiguation examples

If the user says “add tea,” ask only what is missing:

> “Which list should I use: groceries or pharmacy?”

If the user says “schedule shopping,” ask:

> “When should I remind you to review the list?”

Do not ask five questions at once. Resolve one ambiguity at a time.

---

# 10. Caregiver app integration

The future caregiver app should manage configuration and collaboration, but the parent app must remain capable of local daily use.

Caregiver-configurable fields:

- Shared list membership.
- Shopping schedule.
- Preferred provider and store.
- Todo assignment.
- Daily briefing preferences.
- Family check-in schedule.
- HomeKit access policy.
- Plugin enable/disable state.
- Memory sharing policy.

Parent-owned fields by default:

- Personal task completion.
- Personal notes.
- Spoken memories.
- Voice preferences.
- Final provider confirmation.
- Payment and checkout.
- Sensitive health data.

Every remote change should carry:

- Schema version.
- Revision ID.
- Source caregiver ID hash.
- Timestamp.
- Atomic apply semantics.
- Audit entry.

The parent app should speak a short confirmation after a valid remote configuration change:

> “Your Saturday grocery reminder was updated.”

---

# 11. Marketing demonstrations

## Demo 1: Shopping without typing

```text
User: “Add rice, lentils, tea, and two kilos of potatoes to my Saturday list.”
Assistant: “I added four items to your Saturday shopping list.”
User: “Remind me Friday evening to review it.”
Assistant: “Done. I will remind you Friday at six.”
```

## Demo 2: Family collaboration

```text
Caregiver: Adds “pick up prescription” for Friday at 3 PM.
Parent: “What do I need to do today?”
Assistant: “You have a prescription pickup at three. Your daughter added it.”
Parent: “Tell her I will do it.”
Assistant: “I drafted a message. Would you like me to send it?”
```

## Demo 3: My Day

```text
User: “What is next?”
Assistant: “Your medicine is due in 20 minutes. After that, you have a doctor
appointment at eleven. You also asked me to remind you about groceries tonight.”
```

## Demo 4: Independence with escalation

```text
User: “I cannot find the bus card.”
Assistant: “I remember that you keep it in the blue drawer. Would you like me to
call your daughter?”
```

## Demo 5: Native iOS home control

```text
User: “It is dark here.”
Assistant: “Would you like me to turn on the living room lights?”
User: “Yes.”
Assistant: “The living room lights are on.”
```

Every demo must show the actual state transition, not a simulated success message.

---

# 12. Prioritized roadmap

## Release A: useful personal OS core

Build:

1. Shopping List plugin, local-only.
2. Todo plugin, local-only.
3. Shared “My Day” readout.
4. Recurring shopping review schedule.
5. Caregiver shared-list configuration.
6. English and Nepali voice corpus for the above.
7. Local notification scheduling through a shared non-critical reminder seam.

Do not add provider checkout or payment functionality in this release.

## Release B: collaboration and handoff

Build:

1. Caregiver assignment of todos.
2. Shopping provider configuration.
3. Generic provider app/web handoff.
4. Explicit handoff state machine.
5. Family check-in plugin.
6. Pharmacy refill reminders.
7. Daily briefing customization.

## Release C: connected home and Apple surfaces

Build:

1. HomeKit safe controls.
2. App Intents.
3. Widgets and controls.
4. Apple Watch read-only health/status support.
5. Watch medication acknowledgement if validated.
6. Package and appointment tracking where official APIs exist.

## Release D: provider ecosystem

Build only provider adapters with reliable official interfaces:

1. One grocery provider.
2. One pharmacy provider.
3. One transport or pickup provider.
4. Provider-specific handoff and confirmation.
5. Caregiver-visible fulfillment state.

Do not make provider availability part of the core product promise. The local list and schedule must always work.

---

# 13. Success metrics

Measure behavior, not feature count.

### Voice usability

- Percentage of shopping items added without touch.
- Percentage of todos completed by voice.
- Successful first-attempt intent rate in English and Nepali.
- Clarification rate.
- Cancellation and correction rate.
- Time from request to confirmed local state.

### Personal OS value

- Daily active voice sessions.
- “What is next?” usage.
- Number of modules used by one household.
- Number of recurring plans maintained.
- Reduction in missed routine tasks.
- Caregiver intervention rate: lower is better when independence is preserved, but not at the expense of safety.

### Trust and safety

- False confirmation rate.
- Provider handoff mismatch rate.
- Duplicate reminder rate.
- Wrong-list or wrong-date rate.
- Number of actions requiring manual repair.
- Percentage of failures explained honestly.

### Language quality

- Nepali intent accuracy by dialect.
- Date/time interpretation accuracy.
- Item-name preservation accuracy.
- Spoken confirmation comprehension by target users.
- Rate of English fallback in Nepali flows.

---

# 14. Safety and scope boundaries

The following must remain outside optional plugins:

- Emergency detection and dispatch.
- Medication acknowledgement and escalation.
- Health threshold decisions.
- Voice-biometric authorization.
- PIN fallback.
- Durable safety event handling.

The following require explicit confirmation or handoff:

- Payments.
- Checkout.
- Sending messages.
- External provider scheduling.
- Home locks and high-risk appliances.
- Destructive list/task operations.
- Sharing memories or sensitive information with caregivers.

The following must never be claimed without provider confirmation:

- Order placed.
- Delivery scheduled.
- Pickup confirmed.
- Payment completed.
- Ride booked.
- Family member notified.

---

# 15. First implementation plan

Implement the Shopping List plugin and Todo plugin as a single product slice, but keep their storage and domain models separate.

### Step 1: plugin contracts

- Confirm namespaced actions.
- Add plugin-local encrypted storage injection.
- Add non-critical reminder scheduling protocol.
- Add explicit confirmation policy to plugin results.
- Add plugin configuration metadata.

### Step 2: Shopping List

- Add local list/item models.
- Add CRUD store.
- Add voice actions.
- Add list query and spoken summaries.
- Add shopping schedule.
- Add localized English/Nepali strings.
- Add destructive-operation confirmation.
- Add a simple list view.

### Step 3: Todo

- Add local todo model/store.
- Add create/query/complete/postpone actions.
- Add due dates and recurrence.
- Add caregiver assignment field without remote transport initially.
- Add a simple todo view.

### Step 4: My Day aggregation

- Add deterministic planner over existing medication, routine, Calendar, shopping, and todo sources.
- Add “what is next?” and “what is my day?” commands.
- Add a morning briefing preference.
- Keep health data excluded until the HealthKit plan is implemented and permissioned.

### Step 5: caregiver sync

- Add versioned DTOs for shopping lists, schedules, and todos.
- Apply remote updates atomically.
- Record revision history.
- Speak confirmation after application.
- Do not add provider or payment behavior yet.

### Step 6: provider handoff

- Define `ShoppingProvider` and fulfillment state machine.
- Implement one non-payment provider handoff or generic configured-app opener.
- Test failure, cancellation, unavailable app, and ambiguous status.
- Never report success from merely opening a URL.

---

# Final recommendation

The most attractive next product story is a working, localized “My Day” experience built from three voice-first capabilities:

```text
Shopping List
      +
Todo
      +
Unified My Day
```

This gives the user immediate daily value, gives caregivers useful collaboration tools, and establishes the personal operating system model without waiting for payments, provider contracts, Bluetooth peripherals, or a full health platform.

Build the local experience first. Add provider handoffs second. Keep payments external. Make every state transition truthful. That combination is more marketable and more trustworthy than a broader but unreliable collection of integrations.
