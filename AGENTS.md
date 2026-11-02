# AGENTS.md

## Task

1. Read the project instructions that apply to the task.
2. Identify the required result and the checks that can confirm it.
3. For a request for information, give the findings without changing files.
4. Ask the user when a missing decision changes the required result.
5. Continue work within the agreed scope without repeated approval requests.

## Changes

1. Make only the changes necessary for the task.
2. Use the existing project structure and tools.
3. Preserve changes made by other people.
4. Remove unused code that your changes cause.
5. Ask before you change an existing interface or an agreed requirement.
6. Get approval before you publish, spend money, change access rights, or delete user data.
7. Use existing approval when it covers the proposed action.

## Verification

1. Use the repository's documented commands and tool versions. Prefer project-local tools.
2. Add or update tests for changed behavior. For a bug, reproduce the failure before the fix when practical.
3. Test relevant boundary cases and failure paths. Use the existing test framework.
4. Run formatting checks, the affected build, and relevant tests after the final code edit.
5. Run wider checks when required by CI or by the change's impact.
6. Inspect the final diff for unintended edits, secrets, generated output, and compatibility changes.
7. Report checks that failed or could not run, and say why. Never present a planned check as completed.

Use sanitizers for relevant memory or concurrency risks when supported.
For performance changes, record the workload, environment, baseline, and result.
State that the task is complete only when the results support this statement.

## Communication

1. Give the result first, then the necessary evidence and limits.
2. Read the relevant skill or procedure when its stated conditions apply.

## C++ rules

- Match nearby code and the configured formatter. Keep unrelated edits out of the change.
- Prefer simple control flow and existing abstractions. Add templates or layers only when they reduce real complexity.
- Use RAII for resources. Make ownership and object lifetimes clear.
- Prefer values and unique ownership. Use shared ownership only when required.
- Use raw pointers and references for non-owning access. Document lifetime constraints when needed.
- Initialize objects. Use `const` where mutation is not required.
- Check bounds, conversions, overflow, and external input. Avoid undefined behavior.
- Use types that match the contract. Use fixed-width types where binary width matters.
- Follow the local error policy. Use assertions for internal invariants, not input validation.
- Keep headers self-contained. Limit dependencies and public interface exposure.
- Preserve supported compilers, platforms, and architectures. Isolate platform-specific code.
- Explain non-obvious constraints in comments. Update documentation when behavior changes.
- Measure before optimizing. Compare correctness and performance under the same conditions.

## Finish

Report the result, key changes, checks run with outcomes, and remaining limitations.
Claim completion only when the evidence supports the agreed acceptance criteria.
Keep the report concise. Include exact commands when they help reproduce verification.

## Agent skills

### Issue tracker

任务与规格使用 GitHub 仓库 Coh1e/coop 的 Issues 跟踪。
详见 `docs/agents/issue-tracker.md`。

### Triage labels

使用五个默认 triage 标签。
详见 `docs/agents/triage-labels.md`。

### Domain docs

采用 single-context：根目录 GLOSSARY.md 与 docs/adr/。
详见 `docs/agents/domain.md`。

### Next-step guidance

For coding and directly related work, read
`C:/Users/Neo/.agents/skills/pipkit-next-step/SKILL.md` before ending a response.
Follow its decision on continuing work or selecting a closing mode. If missing or
unreadable, report the dependency and do not claim the rules were loaded.
