# TG-06: Safety-Critical Services

> **Jira Epic:** Safety-Critical Services

## Description

Delivers all SAFETY CRITICAL components: health monitoring (HealthKit / Health Connect), alert evaluation and emergency dispatch (TTS countdown + emergency call), and medication scheduling with family notifications. All services are isolated from the LLM — no LlamaInferenceEngine import is permitted in any build target in this group. Each component has iOS and Android subtasks.

## Tasks

| ID | Title | Effort | Depends on | Risk |
|----|-------|--------|------------|------|
| [T-024](T-024-health-monitor-service/) | HealthMonitorService | M+M | T-002, T-004 | HIGH (SAFETY CRITICAL) |
| [T-026](T-026-alert-evaluator-emergency-dispatcher/) | AlertEvaluator + EmergencyDispatcher | M+M | T-024, T-012, T-004 | HIGH (SAFETY CRITICAL) |
| [T-028](T-028-medication-scheduler-family-notifier/) | MedicationScheduler + FamilyNotifier | M+M | T-002, T-004 | HIGH (SAFETY CRITICAL) |

## Group effort estimate

- Optimistic (full parallel, 2 devs on all iOS+Android subtasks): 3–5 days
- Realistic (2 devs, sequential component delivery): 9–15 days
