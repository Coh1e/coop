# Next-step guidance

## When to apply

Apply this document only to coding and directly related work: design, verification,
debugging, release preparation, retrospectives, or a necessary independent review.
Ordinary conversation, explanations, and standalone multimodal tasks use normal
responses. Media used as evidence for coding does not change the task category.

At a response boundary, choose at most one mode below. Continue authorized work
that you can complete now. Do not stop early to manufacture a next step.
Optional advice and routine acceptance do not create required work. When the user
explicitly requests only candidates or analysis, deliver only that output: omit
closing sections, questions, and publication. Use the user's response language for
headings and explanations; keep the AI continuation field names shown below.

For an applicable closing section, separate it from the result with `---` and use
one level-three heading. Select only one mode, including across question-tool text
and the final response. An active planning conversation can ask several rounds;
do not append a different closing mode to each round.

## Complete

Report the result, verification, and material limitations. When no required work
remains, close with `### 已完成` and a short statement that no additional action is
needed and the current chat can end. Do not ask for routine acceptance or invent
a continuation. A retrospective with no actionable candidates uses this mode.

## Human decision or action

Use this mode for an ordinary blocker requiring a human decision, permission,
information, or an operation that the agent cannot perform. Use `### 需要你决定`
or `### 需要你操作`. It takes priority over an AI continuation when human input
blocks that continuation. Do not turn a temporary blocker into a planning workflow.
For retrospective candidates or new improvement scope, use Improvement planning.

Explain the concrete decision or operation, why it is needed, and the recommended
choice. Use an available question tool within its supported purpose and mode.
If no suitable tool is available, ask a direct text question with numbered choices.

- For a decision, offer meaningful, mutually exclusive choices and identify the
  recommended choice. Allow free text when fixed choices cannot capture the answer.
- For an operation, state the steps and completion criteria. Ask for an outcome
  such as completed, blocked, or the relevant observed result. Use a normal text
  request when files or images are needed and the question tool cannot accept them.
- Wait for required input before dependent work. Continue independent authorized work.
  Silence and elapsed time are not approval or completion.
- Reuse existing authorization. Keep agent-performable work with the agent.
  Do not convert optional advice into a required human action.

Do not add Next Action, Chat, Reason, or Prompt fields in this mode.

## Improvement planning

Use `### 改进计划` for retrospective results or new improvement scope that needs
disposition. Show a draft plan, not just a prose recommendation or an untracked
to-do list. Explicit output-only constraints take precedence over this workflow.

### Establish decisions

1. Give every candidate a stable ID. Present a table with ID, candidate, recommended
   disposition, rationale, and open decisions. Preserve severity order and evidence.
   Merged candidates retain all source IDs and map to their common destination.
2. Read `docs/agents/issue-tracker.md`, `docs/agents/domain.md`, and
   `docs/agents/triage-labels.md` before using the corresponding workflows. Read the
   available grilling, to-spec, and to-tickets instructions before using them. Check
   availability; do not claim to invoke a missing skill. Report a missing prerequisite
   and resolve that specific dependency rather than silently replacing the configured
   tracker.
3. Use grilling's decision tree in rounds. Establish facts through investigation;
   ask only decisions affecting scope, behavior, acceptance, or priority. Give a
   recommendation and ask the current decision frontier with a supported question
   tool, or numbered text questions if none fits. Wait for required answers.
   Reuse settled decisions and existing authorization. Confirm shared understanding
   before acting; an approved concrete plan already provides that confirmation.

Every candidate must ultimately have one of these dispositions:

- **Spec:** behavior or design needs a full specification. Use to-spec to synthesize
  agreed decisions, including its test-seam check, then to-tickets when decomposition
  is needed. Do the interview before synthesis; do not restart it inside to-spec.
- **Ticket:** the change is bounded and independently verifiable. Use to-tickets
  directly; agree acceptance criteria, granularity, and blocking edges.
- **No action:** record why it needs no work and the conditions for that decision.
  Do not generate an implementation task for it.

If the human defers a decision, retain it as pending; it is not No action. Do not
claim planning is finished while candidate dispositions remain unresolved.

### Persist and verify

Create or reuse one retrospective tracking issue in the configured tracker. It is
an index of candidate IDs, decisions, spec/ticket links, and publication status;
it is not an executable ticket or a node in the implementation dependency graph.
Record No action decisions there too, including when every candidate is No action.

Follow `docs/agents/issue-tracker.md` for tracker commands and multi-line bodies.
Show reviewable tracking, spec, and ticket drafts before publication. Obtain approval
for scope and external writes, reusing explicit approval when it covers the concrete
drafts. Publishing artifacts does not authorize their implementation. On refusal,
do not publish; retain the visible draft and clearly state its unpublished status.
Do not create a fallback record elsewhere without authorization.

After publication, verify every candidate's mapping, real links, labels where
applicable, and ticket dependencies; native issue dependencies are canonical as
described in `docs/agents/issue-tracker.md`. Keep existing IDs on partial failure.
Report exactly what was published and what remains, and inspect for duplicates
before retrying. Unpublished drafts are not tracked issues. Unresolved decisions and
failed writes remain visible as such.

## Long-running implementation

This document controls response boundaries. It does not replace the active
implementation workflow (for example `implement` or `implement-spec`), its task
graph, or required tests, review, commits, and resolution. Read the active skill and
honor its actual completion criteria and authorization.

- Continue executable work within the approved goal. A completed ticket, milestone
  update, tool call, or context compaction does not require another human choice
  or an AI continuation section. Compaction is not a task boundary.
- Use a closing mode only for necessary human input, an explicit handover, actual
  inability to continue, or completion of the whole authorized goal. Do not delay
  a necessary decision until the end of a long implementation.
- Preserve the original objective, authorization, spec/ticket references, current
  task frontier and blockers, verification state, and remaining review/resolution
  work across turns. Resume from the tracker and context, without replanning settled
  scope or asking for the same authorization.
- Keep out-of-scope improvements out of implementation. Record them in an existing
  appropriate authorized location, if available; otherwise preserve them in the
  session context for retrospective disposition. Do not silently publish new work
  or interrupt the active goal for optional improvements.
- coop records single-agent execution in
  [ADR-0003](../adr/0003-single-agent-execution.md). Review, verification, and commits
  stay in that session. Use Complete only after the active implementation workflow is
  satisfied. Code written is not the same as tests, review, commits, and task
  resolution completed.

## AI continuation

Use this mode only when concrete coding or related work remains for a later turn
or another chat, and no required human decision or action blocks that work.
Recommend exactly one next action from the actual result, in this order:

1. Resolve unfinished verification or blockers that the agent can investigate.
2. Recommend an available, applicable skill when the project setup supports it.
3. Recommend the necessary ordinary continuation when no skill applies.

Before recommending a skill, confirm that the session skill catalog exposes it and
read its instructions to verify its trigger. Check only the configuration it
requires: `docs/agents/issue-tracker.md`, `docs/agents/domain.md`, and
`docs/agents/triage-labels.md` when relevant. Existing files do not prove external
service availability or authentication. These checks are read-only; they do not
authorize installation, configuration changes, or publication.

Recommend a missing setup step only if it prevents the required next action.
Do not invent work to use a skill. Include the skill name, goal, and necessary
context in the prompt when recommending one.

Separate this section from the result with a Markdown horizontal rule (`---`).
Use a level-three Next Action heading, one concrete action, a list for Chat and
Reason, and a level-four Prompt heading followed by a Markdown blockquote.
Render the structure as Markdown, outside code fences:

---

### Next Action

[One concrete action.]

- **Chat:** [SAME or NEW]
- **Reason:** [One short reason for this chat choice.]

#### Prompt

> [A ready-to-use prompt. Prefix every paragraph with >.]

Select SAME when current context remains useful. Select NEW for independent work
or a necessary separate review with a clear boundary. For NEW, make the prompt
self-contained: include the repository path, goal, relevant branch or commit,
changed files, verification evidence, unresolved issues, and acceptance criteria
as needed. Use verified facts and identify material unknowns.
