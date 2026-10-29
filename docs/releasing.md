<!--
SPDX-FileCopyrightText: 2026 gleam_mutants contributors
SPDX-License-Identifier: MIT OR Apache-2.0
-->

# Release preparation and publication

Version 0.1.0 is an unreleased development snapshot.
Preparation does not require creating a tag, GitHub Release, registry package, or publishing credential.
The [checklist](release-checklist.md) distinguishes preparation evidence from later publication approval.
The [artifact binding decision](adr/publish-verified-candidate-artifacts.md) records the architecture.

## Prepare without publication

Run `mise run check` before submitting a change.
The required `CI / required` check runs one Linux gate with compilation, unit tests, metadata and security linters, release-helper tests, the pinned RustSec audit, and native integration tests.
Release proposals receive the same CI through an explicit dispatch when GitHub's token-created PR would otherwise suppress it.
The proposal workflow skips GitHub Release creation.
Merging an implementation change does not publish a version.

The manual `Release candidate evidence` workflow performs the complete preparation campaign on protected `main`.
Pass its exact current commit as `source_sha` and leave `attest` false for an unsigned rehearsal.

```sh
gh workflow run release-candidate.yml --repo P4suta/gleam-mutants \
  --ref main -f source_sha=FULL_MAIN_COMMIT -f attest=false
```

The Linux build requires the exact fourteen gates in `tools/release/src/evidence.rs`.
They include the fast gate, integration and runtime tests, minimum-version compatibility, fixed-seed properties, fault tests, benchmark, score dogfood, ecosystem corpora, reproducible packages, both proof gates, SBOM scans, and the pinned RustSec audit.
Each of Linux, macOS, and Windows runs the integration suite, runtime matrix, and all sixteen mutation-host/test-runtime pairs.
Every pair must report nonempty, fresh, uncached results with no timeout, execution error, skipped work, or inconsistent count.
Expected survivors measure compatibility and do not imply a score threshold.
The minimum-version gate tests Gleam 1.17.0 and Node 20.0.0, plus the current compiler's JavaScript output on Node 20.0.0.
Node 20 is a compatibility floor, not a recommendation for the publishing runner.

`mise run package` builds the Hex source archive, portable Erlang escript, and portable JavaScript npm archive twice from clean staging copies.
It compares reproducibility, checks installed consumers and offline reports, and generates one CycloneDX SBOM per distribution.
SBOM validation requires the matching product version and embedded mutation-testing-elements dependency edge.
`mise run scan-sboms` requires all three reports to contain no known High or Critical vulnerabilities.
An advisory result describes the scanner database used by that invocation and does not predict undisclosed vulnerabilities.

The candidate manifest binds the source commit, version, repository and owner IDs, workflow, run, producer attempts, archive targets, byte sizes, SHA-256 and SHA-512 digests, and all four verification receipts.
`SHA256SUMS` covers the six distribution files with flat download names.
`CANDIDATE-SHA256SUMS` also covers the receipts and candidate manifest.
Missing files, unexpected entries, links, malformed metadata, changed bytes, and incomplete inventories fail validation.
Artifacts expire after seven days; an expired candidate must be prepared again.

Download the unsigned artifact from the completed run and inspect it without signing or publication.

```sh
gh run download RUN --repo P4suta/gleam-mutants \
  --name candidate-SOURCE-RUN-ATTEMPT-unsigned --dir build/review-candidate
mise run release verify build/review-candidate SOURCE VERSION RUN ATTEMPT
```

The preparation CLI has no tag, signing, release-creation, or registry-publication command.
`mise run release-candidate` checks already-built distributions, both proof gates, and SBOM scans locally.
Local receipts are explicitly local and cannot establish hosted builder identity.

## Retain provenance for a future release

A later candidate run with `attest=true` signs only previously verified files in a fresh job without a checkout or execution of candidate code.
It retains a GitHub artifact-attestation bundle and a separate npm Sigstore bundle with the package PURL and archive SHA-512 subject.
The workflow verifies both retained bundles and the online attestations against the exact source, protected-main workflow identity, repository, and GitHub-hosted runner constraint.
An unsigned rehearsal remains useful preparation but cannot pass the publication preflight.
Candidate attestation is an explicit operator choice and does not create a release or publish to a registry.

The [verification contracts](verification.md) identify the implementation-bound proofs and their trust boundaries.
Proof success establishes the named pure predicates, not GitHub's API, registry behavior, OS isolation, or every execution of the release adapter.

## Prepare protected publication inputs

The environments have distinct responsibilities.
`release-prepare` runs version proposals automatically on protected branches without production secrets or a production approval.
`release-github`, `release-hex`, `release-npm`, and the final `release` environment require the repository owner's approval, restrict deployments to protected branches, and disable administrator bypass.
The existing single-owner policy permits self-review.
No production publication credential belongs in the candidate, controller, or version-proposal jobs.
Their scoped GitHub tokens supply only the permissions declared for those jobs.

Use Doppler for the eventual Hex key and any temporary npm bootstrap token.
Create a project and separate production configs only when credential issuance is authorized.
Sync `HEXPM_API_KEY` only to the GitHub `release-hex` environment and `NPM_BOOTSTRAP_TOKEN` only to `release-npm`.
Verify the native integration's environment destination and visible secret names without reading values into logs.
No active key, account registration, or registry trust registration is needed for release preparation.
Never store keys in the repository, command arguments, candidate artifacts, or PR text.

Hex currently uses its documented API-key authentication to upload the exact verified tarball.
The first public package requires an authorized owner account and a narrowly scoped, short-lived bootstrap key.
Use a package-scoped key for subsequent publications and revoke bootstrap access after the first verified publication.
The helper sends the key through the transport's standard input and never retries an uncertain write automatically.
Hex's [workload identity](https://hex.pm/docs/workload-identity) requires an existing public package and is not configured as an implicit fallback.

npm uses trusted publishing by default with Node at least 22.14.0 and npm at least 11.5.1.
Configure its [trusted publisher](https://docs.npmjs.com/trusted-publishers/) for this repository, `.github/workflows/release-publish.yml`, and the `release-npm` environment after the package exists.
Complete the registry's required first validation within its registration window; do not register prematurely during preparation.
The first package publication requires the workflow's explicit `bootstrap` choice and a temporary granular token authorized for the package creation.
Switch subsequent runs to `trusted`, remove the bootstrap secret, and revoke the token.
Trusted mode rejects a supplied bootstrap token and inherited npm authentication.
Both modes use isolated npm configuration, disable lifecycle scripts, and attach the retained original candidate provenance rather than attributing old bytes to a newer controller commit.
Prereleases use the `next` npm tag; stable versions use `latest`.

An absent public package lookup does not reserve a name or prove account ownership or publish permission.
Account ownership, first-publication authorization, registry configuration, and live credential exchange require their own later validation.

## Publish only after explicit authorization

Merge the checked version proposal before publication.
Its `.release-please-manifest.json`, `VERSION`, package metadata, CLI version, and changelog must agree.
Do not merge a release proposal merely to rehearse preparation.

The manual `Publish verified release` workflow selects a source commit, version, successful candidate run and completion attempt, and explicit npm authentication mode.
The read-only preflight checks protected-main ancestry, the merged version proposal, the complete successful run and latest job producers, artifact bytes, retained and online attestations, remote tag, draft assets, and registry archives.
It emits a concrete `release-plan.json` before any production approval.
The controller binaries are compiled and tested without publication privileges, attested in a fresh job, and verified before each approved phase executes them.

1. `release-github` creates or reuses the matching tag and GitHub draft, uploads only missing verified files, and reads every asset back.
2. `release-hex` publishes or reuses the identical Hex tarball and verifies the downloaded registry archive.
3. `release-npm` publishes or reuses the identical npm tarball with original provenance and verifies the downloaded registry archive.
4. `release` finalizes the draft only after the tag, complete assets, and both registry archives match.

The final inventory includes the three archives, three SBOMs, four receipts, candidate manifest, two candidate checksum files, two attestation bundles, and `RELEASE-SHA256SUMS` covering the other fifteen files.
GitHub's immutable-release setting and protected version tags prevent later replacement after publication.
No phase rebuilds candidate packages or overwrites a conflicting remote output.

## Recover from interruption

A transport failure leaves publication uncertain, even if a request may have reached the provider.
Inspect remote state before retrying the affected phase.
Matching bytes may be reused; a missing output may be created; conflicting bytes stop the workflow before further writes.
The draft remains unpublished if either registry phase fails.
Do not delete a successful registry version, move a tag, clobber an asset, or automatically roll back a partial publication.
An incompatible immutable output requires a new version and fresh candidate evidence.

Partial GitHub reruns preserve the actual producer attempt of each receipt, assembled candidate, signer, and controller artifact.
Collection selects only eligible artifacts from the same source and run, compares them with the latest successful named job, and rejects a later failed, skipped, or cancelled check.
The publication preflight also requires the latest run completion to match the selected completion attempt.
A previously successful attempt cannot bypass a newer failed run.
An already published release is refused by the mutation path and must be inspected with read-only operations.
