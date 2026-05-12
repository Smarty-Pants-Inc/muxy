# Muxy

Requires macOS 14+ and Swift 6.0+. No external dependency managers needed — everything is SPM-based.

## Linting & Formatting

Requires `swiftlint` and `swiftformat` (`brew install swiftlint swiftformat`).

```bash
scripts/checks.sh        # Run all checks (formatting, linting, build)
scripts/checks.sh --fix  # Auto-fix formatting and linting issues
scripts/build-smarty-code.sh --channel stable  # Build the stable Smarty Code app bundle
scripts/build-smarty-code.sh --channel dev     # Build the dev Smarty Code app bundle
swiftformat --lint .      # Check formatting only
swiftlint lint --strict   # Check linting only
```

Smarty Code app bundles are Apple Silicon-only. Do not run
`scripts/build-smarty-code.sh` under Rosetta, do not build `x86_64`/Intel, and
do not create universal Smarty Code app bundles. Dependency xcframework paths
may include `arm64_x86_64`; the app target must still be `arm64`. The build
script thins copied frameworks/helpers to arm64 before signing; if macOS warns
about deprecated Intel apps, inspect nested Mach-O slices with `lipo -archs`.
For local dogfood builds, keep the app's code-signing identity stable so macOS
privacy/TCC grants survive app updates. On Paul's machine,
`scripts/build-smarty-code.sh` auto-uses the trusted local identity `Smarty Code
Local Development` when it exists; if prompts repeat after rebuilds, inspect
`codesign -dr - /Applications/Smarty\ Code\ Dev.app` and fix signing rather
than repeatedly approving prompts.
Terminal child processes inherit the hosting app as the macOS TCC
"responsible" process. If a shell inside `Smarty Code`/`Smarty Code Dev` runs
tools such as `op` or reads Desktop/Downloads/app containers, prompts may say
the app wants access even when the Swift app did not touch that data. Verify the
real accessor with `/usr/bin/log show --style compact --last 10m --debug
--predicate 'subsystem == "com.apple.TCC" AND eventMessage CONTAINS[c]
"com.smartypants.smarty-code"'`. The durable local fix is to grant Full Disk
Access to both app bundles in System Settings, then restart each app; from the
parent repo run `./scripts/open-smarty-code-full-disk-access.sh` to open the
pane and print the exact app paths/signing requirements. CLI `tccutil` can
reset but cannot grant, and PPPC pre-grants require MDM.

Run `scripts/checks.sh --fix` after every task.

## Top Level Rules

- Security first
- Native Only
- Maintainability
- Scalability
- Clean Code
- Clean Architecture
- Best Practices
- No Hacky Solutions

## Main Rules

- No commenting allowed in the codebase
- All code must be self-explanatory and cleanly structured
- Use early returns instead of nested conditionals
- Don't patch symptoms, fix root causes
- For every task, Consider how it will impact the architecture and code quality, not just the immediate problem
- Follow the existing code's pattern but offer refactors if they improve code quality and maintainability.
- Use logs for debugging.
- If the feature is testable, then you must write tests.
- Avoid long PR descriptions. It is for humans and keep it in 3 lines maximum.
- Upload screenshots or recordings for the PRs.
- Never answer any question without a proper investigation and exploring the codebase.
- Prioritize problem comprehension over premature implementation. Validate the approach before execution to avoid rework
- Plan properly before executing to not double work

## Code Review

- Review the PRs/Code against the purpose of the PR/Issue/Asked. If you find unrelated issues to the PR during the review, Report them in a separate section.
- Apply review recommendations only after user's confirmation.
