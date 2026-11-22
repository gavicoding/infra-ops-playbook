# Contributing to infra-ops-playbook

Thank you for contributing!

## Guidelines

1. **Zero Sensitive Infrastructure Data:** Never include real company names, branch codes, production IPs, internal hostnames, domains, certificates, or credentials. Use generic identifiers such as `app-server`, `store-NN`, or `example.internal`.
2. **Preserve Script Signatures:** Notice `.gitattributes` marks `windows/HostWatcher.ps1 -text` because `Sign-Script.ps1` verifies raw file bytes.
3. **Pass All Linting Checks Before Opening a PR:**
   - Bash scripts must pass `shellcheck` cleanly.
   - PowerShell scripts must pass `PSScriptAnalyzer` with zero errors (and use language-independent SIDs instead of localized group names where manipulating ACLs).
   - Compose templates must pass `docker compose --env-file ... config -q`.
