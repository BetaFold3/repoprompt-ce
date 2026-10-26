# Verifier live scenarios for Steps 8 and 9 (draft)

Scope: read when the task touches live verification of the recovery banner popover, Needs Attention changes (O34), Check and resolve, or activated recovery actions (O32).
Authority: Reference
Last-verified: 2026-10-26
Covers: scenarios the external verifier (Pi in Terminal, using rpce-cli-debug and accessibility tools) runs after each step lands; merged from the OracleA and OracleD scenario lists. Draft: accessibility IDs and wording are confirmed per step as the code lands.

## Ground rules for the verifier

- Run against the Dev build named in the step's commit; record the commit hash, app PID and provider (Claude Code or Codex) for each scenario.
- Use only synthetic sessions named `RPCE_VERIFY_<scenario>_<date>`; never touch the owner's real sessions. Record every session ID created.
- Ask the owner for approval immediately before each app kill, relaunch or quit, and before any process signal. A scenario with a "Kill/relaunch" mark cannot start without it.
- Evidence per scenario: screenshots or accessibility dumps of the banner/sheet, the session's recovery record (`~/Library/Application Support/RepoPrompt CE/AgentRecovery/v1/sessions/<id>.json`, read only, never edited), `ps -eo pid,ppid,pgid,comm` before and after for process scenarios, and the provider's own history (Claude JSONL / Codex thread) for send counts.
- Universal hard fail: any message sent to a provider that the steps did not ask for, any second copy of a message, or any lost typed text.
- Afterwards, delete the scenario's synthetic sessions through the UI (with owner approval) and list what was deleted.

## Housekeeping (before the first scenario, owner approval)

H1. Delete the 14 leftover synthetic sessions from the earlier live run through the UI. The main agent holds the list (titles T2–T14, "Restart acceptance M: 600s foreground wait", RPCE_RESTART_ACCEPTANCE_20261025_Z). Pass: they disappear from the sidebar and their Needs Attention items go with them.

## Step 8-popover (no kill)

P1. On a row with a View button, open View; with it open, click Edit (or Remove / Restore / Discard…) once. Pass: popover closes and the button acts on the same click.
P2. Open View, click once in the composer. Pass: closes and the composer has focus; typing works at once.
P3. Open View, click a sidebar session or toolbar button once. Pass: closes and that item activates.
P4. Open View, click View again. Pass: closes and stays closed; a third click reopens.
P5. Open View, press Escape right away without clicking inside. Pass: closes. (If not, report; this is a known open question.)
P6. On an edit-proposal row: open View, wait for the comparison line to change from "Comparing with the current file…", close, reopen. Pass: the result appears on the first open and is recomputed on the second, never stuck or stale.
P7. Same as P1 from the Needs Attention sheet. Pass: same as P1.
P8. With View open, click a control in another RepoPrompt window once. Pass: the popover closes and that window activates; normal macOS first-click rules apply there (a second click may be needed), and nothing else changes focus.
P9. Cmd-Tab away with View open, come back, click View once. Pass: it had closed; reopens with one click.
P10. Open View, then remove that row while it is open (act on it from the sheet or another window); when a row with a View button appears again, click View once. Pass: the popover went away with the row, and View opens with one click (never looks dead).
P11. Open View inside the Needs Attention sheet, then click the window behind the sheet. Pass: the popover closes; keyboard focus does not land in the composer behind the still-open sheet.

## Step 8-attention (no kill unless marked)

A1. Clean session open while another session has a saved unsent message. Pass: the clean session shows no recovery banner; the other session shows its banner; the sidebar badge counts needs-action items only.
A2. Kill/relaunch: kill the app mid-turn (Claude). Relaunch, open Needs Attention. Pass: crash hold under Needs action; the run note under Information (collapsed); the badge does not count the run note.
A3. After A2, click It stopped, send a new message normally, reopen the sheet. Pass: the run note is gone from Information; "Show dismissed and cleared" shows it marked as cleared; no new acknowledgement was written to the record for it.
A4. Bulk Dismiss on Information with three notes. Pass: summary "Dismissed 3 of 3"; each record has an acknowledgement; saved inputs, questions and crash holds unchanged.
A5. Bulk Dismiss on a Needs action workspace group that contains a non-dismissible item (save failure or surviving process). Pass: confirmation text says Dismiss only hides cards; the non-dismissible item is reported as skipped; crash holds still pause sending (the "Sending paused" row remains).
A6. Start a bulk Dismiss and change one item before it is reached (for example, restore its draft in another window). Pass: that item is reported skipped/changed, never dismissed in its new form.
A7. Sheet sections: open Needs Attention. Pass: header `agent.recoveryNeedsAttention.section.needsAction` reads "Needs action (n)" and the disclosure `agent.recoveryNeedsAttention.section.informational` reads "Information (m)", collapsed (accessibility value `collapsed`); n equals the sidebar badge (`agent.recoveryNeedsAttention.sidebarButton`); turning on Show dismissed does not change n or m.
A8. Section move during an action (after activation): on a run note in Information, start Continue or Reconcile. Pass: the row may move to Needs action while the action runs and back afterwards; no confirmation or typed text is lost, and the composer banner flash is acceptable only while the action runs. Record what happens.
A9. Unsent continuation (after activation, Claude or Codex): type a continuation that is refused before sending (e.g. while the old process may still be running). Pass: the run row is under Needs action and its detail ends with "The message you typed to continue it was not sent."; a following Reconcile that does not confirm completion leaves it under Needs action.

## Step 9-check

C1. Before activation: run Check and resolve on existing items. Pass: report says process and provider-history checks are not active; nothing is resolved automatically; no session is opened; no message is sent.
C2. Kill/relaunch, after activation: mixed state (one Claude process still running a long tool, one Codex run that finished while closed, one unsent saved message, one pending question). Run Check. Pass: running process → "needs you" (Let finish or Stop); finished Codex run → resolved via history; unsent message → "needs you"; question → "needs you"; run-attempt counts unchanged.
C3. Cancel a running Check part-way. Pass: completed items stay completed; remaining items untouched; the report says cancelled.

## Step 9-activation (Claude Code = C, Codex = X)

V1. Kill/relaunch (C): kill the app during a long Bash tool. Before the kill, confirm the child process carries the `RPCE_RUNTIME_ID` marker (`ps eww <pid>`). Relaunch. Pass: a surviving-process item names provider, PID and worktree; sends to that conversation are refused while it lives; Let finish keeps the item with "You chose to let it finish"; after the process exits, Refresh clears it and sending resumes.
V2. Kill/relaunch (X): same as V1. Pass: if Codex children exit with the app, no survivor item after Refresh; the crash hold remains until It stopped.
V3. Stop (C), only if Stop is wired: on a disposable survivor, open Stop, cancel once, then confirm. Pass: cancel signals nothing; confirm signals only the listed PIDs (compare `ps` before/after); final rediscovery decides success.
V4. Kill/relaunch (X): Reconcile twice after It stopped. Pass: first run imports rows and records how the turn ended; second run imports 0 rows; no new Codex turn exists.
V5. Kill/relaunch (C): Reconcile twice; watch `ps` for any `claude --resume`. Pass: rows imported and marked recovered, completion shown as unconfirmed; second run 0 rows; no Claude process started.
V6. Kill/relaunch (X, then C): It stopped → Continue… → edit text → Send; double-click Send. Pass: exactly one continuation and one run attempt; same thread/session ID in the provider's history; the second click joins, it doesn't resend. For C, also kill during a tool call: Continue either works or refuses with a typed reason, never starts a fresh conversation.
V7. Kill/relaunch (X, C): kill while a queued follow-up is saved but unsent. Relaunch → Send saved, click twice. Pass: one dispatch, provider history shows one copy; on refusal it stays unsent.
V8. Kill/relaunch (X, C): kill while a question is pending. Relaunch → Send answer as message. Pass: a new user message is sent; no old question callback fires; double click sends once.
V9. Unqualified provider sanity (OpenCode or Oh My Pi, if the owner uses one): kill/relaunch mid-turn. Pass: actions either work through the same fences or refuse with a visible reason; never a silent send.

## Reporting

For each scenario: pass/fail, evidence paths, session IDs, approvals obtained, and any unexpected UI text. Failures go back to the main agent; the verifier does not change code.
