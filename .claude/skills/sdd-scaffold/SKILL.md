---
name: sdd-scaffold
description: Scaffold a new ai-sdd project or feature. Detects greenfield vs brownfield,
             asks tailored questions, then generates constitution, config, workflow, and
             init report. Run this once per project or feature.
context: fork
allowed-tools: Bash, Task
---
Scaffold an ai-sdd project or feature. Follow these steps:

1. Check if .ai-sdd/ exists. If not, run `ai-sdd init --tool claude_code` via Bash.

2. **Context Probe** — Run these via Bash (silently — do NOT show raw output to the developer):

   ```bash
   test -f constitution.md && grep -c '^\S' constitution.md 2>/dev/null
   ls src/ lib/ app/ 2>/dev/null | head -3
   git log --oneline -3 2>/dev/null
   ls specs/*/constitution.md 2>/dev/null
   ```

   Use the results internally to infer a mode:
   - **greenfield**: No meaningful constitution.md, no source dirs, no/little git history
   - **brownfield-feature**: Existing constitution.md with real content, source dirs present, git history exists
   - **brownfield-quickfix**: Same as brownfield-feature but developer says it's a bug fix (confirmed in Q1)

   Hold this inference — Q1 will confirm or override it.

3. Ask **Q1** (all modes):

   > What are you building — and is this a new project, a new feature in an existing project, or a quick fix?
   > (type ? for help on this question)

   [? help]: "New project" = greenfield, no existing codebase.
   "New feature" = adding capability to an existing codebase with an existing constitution.
   "Quick fix" = bug fix or small patch in an existing codebase.
   If unsure, describe what you're doing and I'll help classify it.

   Combine the probe results with the Q1 answer to finalize the mode.
   If there is a conflict (probe says brownfield but developer says greenfield, or vice versa),
   ask ONE disambiguation question:
   > "I see [probe evidence]. You said [their answer]. Can you clarify — is this truly [X]?"

   Announce the mode:
   > "Got it — this is [a new project / a new feature in an existing project / a quick fix].
   > Tailoring questions accordingly."

4. Ask the remaining questions ONE AT A TIME based on the mode.
   After each question, add "(type ? for help on this question)" on a new line.
   Wait for the developer's response before continuing.

   If the developer responds with "?" (or "help", "?help", "more info"):
   - Show the detailed help text for that question (see below)
   - Re-ask the same question
   - Wait for a real answer before moving to the next question

   ## GREENFIELD path (Q2-Q8)

   Q2: Target platform(s)?
       Options: mobile iOS | mobile Android | web frontend | backend API | desktop |
       embedded/IoT | other (list all that apply)
       [? help]: Where does the software run?
       - Mobile iOS: iPhone/iPad; access to HealthKit, CoreML, on-device LLM
       - Mobile Android: Android phones; Health Connect, TensorFlow Lite
       - Web frontend: runs in a browser; React, Vue, Angular
       - Backend API: server-side REST or GraphQL service
       - Desktop: Windows/macOS/Linux; Electron, Tauri
       - Embedded/IoT: hardware with constrained resources
       List all that apply. Describe the device the end user touches if unsure.

   Q3: Tech stack preferences — or "none, let the architect decide"?
       [? help]: Only list things already decided or constrained (existing team skills,
       systems to extend). Leave the rest open. Examples: "TypeScript + Bun + PostgreSQL",
       "Must use Python — team has no other skills", "none — let the architect decide".

   Q4: Does this project involve safety-critical features? (yes/no + brief description)
       [? help]: Safety-critical = a failure could directly harm a person, cause
       significant financial loss, or create serious legal liability. Examples: health
       monitoring, emergency alerts, financial transactions, systems used by vulnerable
       users, autonomous decisions with real-world impact. If yes: T2 gates + paired
       review are applied automatically.

   Q5: Privacy or compliance requirements?
       Options: GDPR | HIPAA | SOC2 | PCI-DSS | APRA CPS 234 | Children's data |
       none/unknown
       [? help]: Regulations that impose design constraints.
       - GDPR: EU data protection (any EU users' data)
       - HIPAA: US healthcare patient records
       - SOC2: security certification for B2B SaaS
       - PCI-DSS: payment card processing or storage
       - APRA CPS 234: Australian financial sector cybersecurity
       - Children's data: COPPA (US), UK Children's Code

   Q6: Expected scale?
       Options: quickfix | feature | greenfield product | regulated enterprise
       [? help]:
       - Quickfix: known bug, hours to a day; workflow: implement -> review; cost ~$5
       - Feature: new capability in existing system, one sprint; cost ~$15
       - Greenfield product: new system from scratch, all 6 agents, weeks/months; cost ~$25
       - Regulated enterprise: formal audit trail + T2 gates throughout, months; cost ~$50

   Q7: What are your fixed constraints?
       List anything that is given and cannot be changed — or answer "none".
       [? help]: Fixed constraints are boundaries the architect must work within, not decide.
       Examples by category:
       - Existing systems: "Must integrate with our SAP ERP"
       - Technology mandates: "All backend must be Python"
       - Performance SLAs: "API responses < 200ms at p99"
       - Budget: "Hosting budget $200/month maximum"
       - Team: "One developer, 10h/week"
       - Deployment: "On-premise servers only — no public cloud"
       - Data residency: "All user data must remain in Australia"
       - Integrations: "Must use our existing Azure AD for SSO"
       Anything you're hoping for but not requiring belongs in Q3 as a preference.

   Q8: Who is the primary user and what does success look like?
       [? help]: Name the person (role, not name) who will use the system most, and
       describe the outcome that means the project worked. Example: "Primary user is
       a clinic nurse. Success = medication errors drop 50% in 6 months."

   ## BROWNFIELD-FEATURE path (Q2-Q6)

   Q2: What's the feature name and scope? (what it does, what it does NOT do)
       [? help]: Be specific about boundaries. Example: "User notification preferences —
       lets users choose email vs push for each notification type. Does NOT change the
       notification delivery pipeline itself."

   Q3: Any new safety or compliance concerns beyond what the project already handles?
       [? help]: The root constitution.md already documents the project's safety and
       compliance baseline. Only mention NEW concerns this feature introduces.
       Example: "This feature adds payment processing — need PCI-DSS compliance
       (the rest of the app doesn't handle payments)." Answer "none" if the feature
       stays within the existing safety/compliance profile.

   Q4: What existing code or modules does this feature touch?
       [? help]: List the files, directories, services, or APIs this feature will
       modify or integrate with. Example: "src/notifications/, the user-settings API,
       and the email service adapter." This helps the architect understand the
       integration surface.

   Q5: Feature-specific constraints?
       [? help]: Constraints that apply to this feature specifically, beyond the
       project-level constraints in constitution.md. Example: "Must ship by March 15",
       "Cannot change the database schema", "Must work offline".
       Answer "none" if there are no feature-specific constraints.

   Q6: Who is the primary user of this feature and what does success look like?
       [? help]: Name the person (role) who benefits most from this feature and
       the outcome that means it worked. Example: "Primary user is the ops team.
       Success = alert fatigue drops — fewer than 5 false-positive notifications per day."

   ## BROWNFIELD-QUICKFIX path (Q2-Q4)

   Q2: What is the bug or issue? (symptoms, where it occurs, steps to reproduce if known)
       [? help]: Describe what's going wrong, where in the system it happens, and
       how to trigger it. Example: "Login fails with 500 error when email contains
       a plus sign. Happens in src/auth/login.ts. Steps: enter 'user+tag@example.com',
       click login."

   Q3: Any safety or compliance implications?
       [? help]: Could this bug cause data loss, security exposure, or compliance
       violations? Example: "Yes — the bug exposes user emails in error responses
       (GDPR concern)." Answer "no" if it's a straightforward functional bug.

   Q4: Constraints? (timeframe, things that must NOT break)
       [? help]: Example: "Must fix today — blocking production users. Do not change
       the auth middleware signature — other services depend on it."

5. Check for any existing requirements.md, brief.md, or similar files in the project root
   via Bash and note their paths.

6. PHASE 2 — Review answers and ask targeted clarifying questions.

   Before asking anything, say:
   "Thanks — just a few follow-up questions to fill in any gaps.
   Type -> or 'skip' at any time to stop. I'll ask for confirmation first."

   Review all answers and any existing brief files for:
   a) Answers too vague to generate a useful artifact
   b) Conflicts between answers
   c) Missing critical information that cannot be reasonably defaulted

   For brownfield modes, also read the existing constitution.md to understand the
   project's current context and avoid asking about things already documented there.

   Ask only the necessary clarifying questions. Maximum 5 for greenfield, 3 for
   brownfield-feature, 2 for brownfield-quickfix.

   After each clarifying question, check if the developer's response is a skip signal
   (->, skip, proceed, go ahead, enough, continue, s).
   If so, ask for confirmation:
     "Proceed with what we have? I'll fill any remaining gaps with defaults and document
      assumptions in Open Decisions. [yes / no, keep going]"
   - On yes (y, yes, ok, sure, confirm): stop asking and proceed to step 7
   - On no (n, no, keep going): resume from the next unanswered clarifying question

   Do NOT ask about:
   - Minor vagueness where a reasonable default exists
   - Tech preferences (the architect decides those)
   - Future features or nice-to-haves

7. Build a JSON brief file and run the scaffold CLI command:

   a. Write a temporary brief JSON to `/tmp/sdd-brief-<timestamp>.json`:
      ```json
      {
        "mode": "<greenfield|brownfield-feature|brownfield-quickfix>",
        "answers": { ... all answers keyed by field name ... },
        "clarifications": { ... any Phase 2 clarifications ... },
        "existing_brief_paths": [ ... paths from step 5 ... ]
      }
      ```

      Field names for each mode:
      - **greenfield**: what, platform, tech_stack, safety_critical, compliance, scale, constraints, user_success
      - **brownfield-feature**: what, feature_scope, safety_delta, affected_modules, constraints, user_success
      - **brownfield-quickfix**: what, bug_description, safety_implications, constraints

      The `scale` field (greenfield only) must be one of: quickfix, feature, greenfield, regulated

   b. Run via Bash:
      ```bash
      ai-sdd scaffold --brief /tmp/sdd-brief-<timestamp>.json --project /Users/anjan/workspace/projects/ai/ai-sdd/ai-sdd-claude/examples/elderly-ai-assistant
      ```

      This generates: ai-sdd.yaml, workflow YAML, directory structure, and init-report.
      The output is JSON with `files_created` and `constitution_prompt`.

   c. Spawn Task(sdd-scaffold) with the `constitution_prompt` from the CLI output.
      The agent writes `constitution.md` (greenfield) or `specs/<feature>/constitution.md`
      (brownfield-feature). Quickfix mode does not need a constitution.

   d. Clean up: `rm /tmp/sdd-brief-<timestamp>.json`

8. When complete:
   - Show the developer: which files were created (from CLI output + agent output)
   - For greenfield: Show the Open Decisions list from constitution.md.
     Say: "Review constitution.md, resolve the open decisions, then type /sdd-run to start."
   - For brownfield-feature: Show what was generated.
     Say: "Review specs/<feature>/constitution.md, then type /sdd-run to start the feature workflow."
   - For brownfield-quickfix: Show the quickfix report.
     Say: "Review the quickfix workflow, then type /sdd-run to start."
