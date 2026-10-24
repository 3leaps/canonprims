# Decision records

Record types and naming follow
[crucible ADR-0003](https://github.com/3leaps/crucible/blob/main/docs/decisions/ADR-0003-decision-record-taxonomy.md):
`<TYPE>-<NNNN>-<slug>.md`, numbered per type, never reused. Gates follow
[crucible EPR-0002](https://github.com/3leaps/crucible/blob/main/docs/decisions/EPR-0002-verification-gate-integrity.md)
(a gate checks resolved state and has a control that fails at that gate).

| ID | Title | Status |
| --- | --- | --- |
| [ADR-0001](ADR-0001-release-identity-and-tags.md) | Release identity: two signed tags at one commit, committed public pins | accepted |
| [ADR-0002](ADR-0002-no-links-in-release-paths.md) | Release and configuration paths never follow links | accepted |
| [PDR-0001](PDR-0001-crates-io-publication.md) | crates.io publication: packages verified in CI, token released only for the verified package | accepted |
| [PDR-0002](PDR-0002-dependency-and-build-policy.md) | Dependencies come from crates.io only, cool before adoption, and build at a pinned toolchain | accepted |
| [PDR-0003](PDR-0003-public-source-review.md) | Public source, history and change text carry no private context | accepted |
