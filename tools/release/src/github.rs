// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Revision, Version};
use crate::evidence::{Candidate, Identity, Origin};
use crate::runner;
use serde_json::Value;
use std::path::Path;
use std::process::Command;

const PAGE_SIZE: usize = 100;
const MAXIMUM_PAGES: usize = 1000;
const NOT_FOUND: &str = "404";
const HTTP_NOT_FOUND: u64 = 404;
pub const GENERAL_BUNDLE: &str = "github-attestation.sigstore.json";
pub const NPM_BUNDLE: &str = "npm-provenance.sigstore.json";

const BUILD_JOB: &str = "Verify and build distributions";
const SEAL_JOB: &str = "Bind candidate evidence";
const ATTEST_JOB: &str = "Attest verified candidate";
const VERIFY_JOB: &str = "Verify retained provenance";
pub(crate) const PROPOSAL_BRANCH: &str =
    "release-please--branches--main--components--gleam-mutants";
const ACTIONS_BOT: &str = "github-actions[bot]";

#[derive(Debug, PartialEq, Eq)]
enum ProposalRun {
    Suppressed(u64),
    Present,
}

fn proposal_reference(reference: &Value, source: &Revision) -> Result<(), String> {
    if reference["ref"] != format!("refs/heads/{PROPOSAL_BRANCH}")
        || reference["object"]["type"] != "commit"
        || reference["object"]["sha"] != source.as_str()
    {
        return Err("proposal branch differs from the requested CI source".into());
    }
    Ok(())
}

fn proposal_run(run: &Value, source: &Revision) -> Result<ProposalRun, String> {
    let id = run["id"]
        .as_u64()
        .filter(|id| *id > 0)
        .ok_or("CI run identity is missing")?;
    if run["head_sha"] != source.as_str()
        || run["head_branch"] != PROPOSAL_BRANCH
        || run["path"] != ".github/workflows/ci.yml"
        || run["repository"]["id"] != candidate::REPOSITORY_ID
        || run["head_repository"]["id"] != candidate::REPOSITORY_ID
        || !matches!(
            run["event"].as_str(),
            Some("pull_request" | "workflow_dispatch")
        )
    {
        return Err("proposal CI belongs to another source, workflow, or repository".into());
    }
    match (run["status"].as_str(), run["conclusion"].as_str()) {
        (Some("completed"), Some("action_required")) => {
            if run["event"] != "pull_request"
                || run["actor"]["login"] != ACTIONS_BOT
                || run["actor"]["type"] != "Bot"
                || run["triggering_actor"]["login"] != ACTIONS_BOT
                || run["triggering_actor"]["type"] != "Bot"
            {
                return Err(
                    "CI needs an explicit workflow approval; no dispatch is authorized".into(),
                );
            }
            Ok(ProposalRun::Suppressed(id))
        }
        (Some("queued" | "in_progress" | "requested" | "waiting" | "pending"), None)
            if run["conclusion"].is_null() =>
        {
            Ok(ProposalRun::Present)
        }
        (
            Some("completed"),
            Some(
                "success" | "failure" | "cancelled" | "timed_out" | "skipped" | "neutral" | "stale"
                | "startup_failure",
            ),
        ) => Ok(ProposalRun::Present),
        _ => Err("proposal CI state is missing or unsupported".into()),
    }
}

pub(crate) fn validate_proposal(pull: &Value) -> Result<(), String> {
    if pull["state"] != "open"
        || pull["user"]["login"] != ACTIONS_BOT
        || pull["user"]["type"] != "Bot"
        || pull["head"]["ref"] != PROPOSAL_BRANCH
        || pull["head"]["repo"]["id"] != candidate::REPOSITORY_ID
        || pull["head"]["repo"]["fork"] != false
        || pull["base"]["ref"] != "main"
        || pull["base"]["repo"]["id"] != candidate::REPOSITORY_ID
    {
        return Err("proposal identity is outside the internal bot scope".into());
    }
    Ok(())
}

fn validate_proposal_files(files: &[Value]) -> Result<(), String> {
    const ALLOWED: [&str; 5] = [
        ".release-please-manifest.json",
        "CHANGELOG.md",
        "VERSION",
        "gleam.toml",
        "src/gleam_mutants/version.gleam",
    ];
    if files.is_empty()
        || files.iter().any(|file| {
            !file["filename"]
                .as_str()
                .is_some_and(|name| ALLOWED.contains(&name))
                || !matches!(file["status"].as_str(), Some("added" | "modified"))
        })
    {
        return Err("proposal changes files outside the version-preparation scope".into());
    }
    Ok(())
}

pub fn latest_success(jobs: &[Value], name: &str, identity: &Identity) -> Result<u32, String> {
    let Origin::GitHub { run, attempt, .. } = identity.origin else {
        return Err("hosted job identity required".into());
    };
    let mut selected = std::collections::BTreeMap::new();
    for job in jobs.iter().filter(|job| job["name"] == name) {
        let producer = job["run_attempt"]
            .as_u64()
            .and_then(|n| u32::try_from(n).ok())
            .filter(|n| *n > 0)
            .ok_or("job producer attempt is invalid")?;
        if producer > attempt {
            continue;
        }
        if job["run_id"] != run || job["head_sha"] != identity.source.as_str() {
            return Err("job belongs to another source or run".into());
        }
        if selected.insert(producer, job).is_some() {
            return Err("job producer identity is ambiguous".into());
        }
    }
    let (attempt, job) = selected
        .pop_last()
        .ok_or_else(|| format!("required job is missing: {name}"))?;
    if job["status"] != "completed" || job["conclusion"] != "success" {
        return Err(format!("latest required job did not pass: {name}"));
    }
    Ok(attempt)
}

fn jobs(run: u64) -> Result<Vec<Value>, String> {
    list(
        &format!(
            "repos/{}/actions/runs/{run}/jobs?filter=all",
            candidate::REPOSITORY
        ),
        Some("jobs"),
    )
}

fn producer_matches(identity: &Identity, attempt: u32) -> Result<(), String> {
    if matches!(identity.origin, Origin::GitHub {attempt:actual, ..} if actual == attempt) {
        Ok(())
    } else {
        Err("receipt differs from the latest successful job producer".into())
    }
}

pub struct ProducerArtifact {
    pub name: String,
    pub attempt: u32,
}

pub fn select_artifact(
    artifacts: &[Value],
    prefix: &str,
    identity: &Identity,
) -> Result<ProducerArtifact, String> {
    identity.hosted()?;
    let Origin::GitHub { run, attempt, .. } = identity.origin else {
        return Err("hosted artifact selection required".into());
    };
    let mut selected = std::collections::BTreeMap::new();
    for artifact in artifacts {
        let name = artifact["name"]
            .as_str()
            .ok_or("artifact name is missing")?;
        let Some(suffix) = name.strip_prefix(prefix) else {
            continue;
        };
        if suffix.ends_with("-unsigned") {
            continue;
        }
        let producer: u32 = suffix
            .parse()
            .map_err(|_| "artifact producer attempt is malformed")?;
        if producer == 0 || producer.to_string() != suffix {
            return Err("artifact producer attempt is not canonical".into());
        }
        if producer > attempt || artifact["expired"] == true {
            continue;
        }
        if artifact["expired"] != false
            || artifact["workflow_run"]["id"] != run
            || artifact["workflow_run"]["repository_id"] != candidate::REPOSITORY_ID
            || artifact["workflow_run"]["head_sha"] != identity.source.as_str()
        {
            return Err("artifact source identity is invalid".into());
        }
        if selected.insert(producer, name.to_owned()).is_some() {
            return Err("artifact producer is ambiguous".into());
        }
    }
    selected
        .pop_last()
        .map(|(attempt, name)| ProducerArtifact { name, attempt })
        .ok_or("no complete unexpired artifact producer exists".into())
}

fn download(directory: &Path, run: u64, artifact: &ProducerArtifact) -> Result<(), String> {
    if directory.exists() {
        return Err("artifact download requires a fresh directory".into());
    }
    runner::output(
        Command::new("gh")
            .args([
                "run",
                "download",
                &run.to_string(),
                "--repo",
                candidate::REPOSITORY,
                "--name",
                &artifact.name,
                "--dir",
            ])
            .arg(directory),
    )?;
    Ok(())
}

pub fn collect(directory: &Path) -> Result<(), String> {
    let identity = runner::current_identity(true)?;
    let Origin::GitHub { run, .. } = identity.origin else {
        return Err("hosted collection required".into());
    };
    repository()?;
    let artifacts = list(
        &format!(
            "repos/{}/actions/runs/{run}/artifacts",
            candidate::REPOSITORY
        ),
        Some("artifacts"),
    )?;
    let jobs = jobs(run)?;
    let build = select_artifact(&artifacts, &format!("build-{run}-"), &identity)?;
    if build.attempt != latest_success(&jobs, BUILD_JOB, &identity)? {
        return Err("build artifact is older than its latest job".into());
    }
    download(directory, run, &build)?;
    let gates = crate::evidence::receipt(
        &directory.join("build/release-gates"),
        crate::evidence::GATE_RECEIPT,
    )?;
    gates.validate(
        &identity,
        "linux",
        &crate::evidence::GATES.map(str::to_owned),
    )?;
    if !matches!(gates.identity.origin, Origin::GitHub {attempt, ..} if attempt == build.attempt) {
        return Err("build receipt differs from its artifact producer".into());
    }
    std::fs::create_dir(directory.join("runtimes")).map_err(|e| e.to_string())?;
    std::fs::create_dir(directory.join("runtime-producers")).map_err(|e| e.to_string())?;
    for platform in crate::evidence::PLATFORMS {
        let producer =
            select_artifact(&artifacts, &format!("runtime-{platform}-{run}-"), &identity)?;
        if producer.attempt
            != latest_success(
                &jobs,
                &format!("Runtime compatibility ({platform})"),
                &identity,
            )?
        {
            return Err("runtime artifact is older than its latest job".into());
        }
        let root = directory.join("runtime-producers").join(platform);
        download(&root, run, &producer)?;
        let name = format!("runtime-{platform}.json");
        let receipt = crate::evidence::receipt(&root, &name)?;
        receipt.validate(&identity, platform, &crate::evidence::runtime_checks())?;
        if !matches!(receipt.identity.origin, Origin::GitHub {attempt, ..} if attempt == producer.attempt)
        {
            return Err("runtime receipt differs from its artifact producer".into());
        }
        crate::evidence::write_bytes_new(
            &directory.join("runtimes").join(&name),
            &candidate::read(&root, &name)?,
        )?;
    }
    Ok(())
}

pub fn get(path: &str) -> Result<Option<Value>, String> {
    let output = Command::new("gh")
        .args(["api", "--method", "GET", path])
        .output()
        .map_err(|e| format!("GitHub read: {e}"))?;
    let value: Value = serde_json::from_slice(&output.stdout)
        .map_err(|_| format!("GitHub read returned no JSON: {}", output.status))?;
    if output.status.success() {
        return Ok(Some(value));
    }
    if value["status"].as_str() == Some(NOT_FOUND)
        || value["status"].as_u64() == Some(HTTP_NOT_FOUND)
    {
        return Ok(None);
    }
    Err(format!("GitHub read refused: {}", output.status))
}

pub fn required(path: &str) -> Result<Value, String> {
    get(path)?.ok_or_else(|| format!("GitHub resource is missing: {path}"))
}

pub fn list(path: &str, key: Option<&str>) -> Result<Vec<Value>, String> {
    let mut items = Vec::new();
    for page in 1..=MAXIMUM_PAGES {
        let separator = if path.contains('?') { '&' } else { '?' };
        let response = required(&format!(
            "{path}{separator}per_page={PAGE_SIZE}&page={page}"
        ))?;
        let page = if let Some(key) = key {
            &response[key]
        } else {
            &response
        };
        let page = page
            .as_array()
            .ok_or("GitHub collection has no expected array")?;
        items.extend(page.iter().cloned());
        if page.len() < PAGE_SIZE {
            return Ok(items);
        }
    }
    Err("GitHub collection exceeded the complete pagination bound".into())
}

pub fn repository() -> Result<(), String> {
    let repository = required(&format!("repos/{}", candidate::REPOSITORY))?;
    if repository["id"] != candidate::REPOSITORY_ID
        || repository["owner"]["id"] != candidate::OWNER_ID
        || repository["full_name"] != candidate::REPOSITORY
        || repository["default_branch"] != "main"
        || repository["fork"] != false
        || repository["archived"] != false
    {
        return Err("GitHub repository identity does not match the release contract".into());
    }
    Ok(())
}

pub fn expected(
    source: Revision,
    version: Version,
    run: u64,
    attempt: u32,
) -> Result<Identity, String> {
    let identity = Identity {
        source,
        version,
        origin: Origin::GitHub {
            repository: candidate::REPOSITORY.into(),
            repository_id: candidate::REPOSITORY_ID,
            owner_id: candidate::OWNER_ID,
            workflow: candidate::CANDIDATE_WORKFLOW.into(),
            run,
            attempt,
        },
    };
    identity.hosted()?;
    Ok(identity)
}

pub fn validate_run(run: &Value, identity: &Identity) -> Result<(), String> {
    let Origin::GitHub {
        run: number,
        attempt,
        ..
    } = &identity.origin
    else {
        return Err("hosted candidate required".into());
    };
    identity.hosted()?;
    if run["id"] != *number
        || run["run_attempt"] != *attempt
        || run["head_sha"] != identity.source.as_str()
        || run["head_branch"] != "main"
        || run["event"] != "workflow_dispatch"
        || run["path"] != candidate::CANDIDATE_WORKFLOW
        || run["status"] != "completed"
        || run["conclusion"] != "success"
        || run["repository"]["id"] != candidate::REPOSITORY_ID
        || run["head_repository"]["id"] != candidate::REPOSITORY_ID
    {
        return Err("candidate run is incomplete or belongs to another source, attempt, event, or repository".into());
    }
    Ok(())
}

pub fn verify_source(identity: &Identity) -> Result<(), String> {
    let comparison = required(&format!(
        "repos/{}/compare/{}...main",
        candidate::REPOSITORY,
        identity.source.as_str()
    ))?;
    if !matches!(comparison["status"].as_str(), Some("ahead" | "identical")) {
        return Err("candidate source is outside protected main history".into());
    }
    Ok(())
}

pub fn attestations(directory: &Path, identity: &Identity) -> Result<(), String> {
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    let signer = format!(
        "{}/{}",
        candidate::REPOSITORY,
        candidate::CANDIDATE_WORKFLOW
    );
    let certificate = format!(
        "{}/{signer}@refs/heads/main",
        crate::constants::GITHUB_ORIGIN
    );
    let npm = candidate.npm()?;
    for (name, algorithm, bundle) in [
        ("candidate.json", "sha256", GENERAL_BUNDLE),
        (npm.path.as_str(), "sha512", NPM_BUNDLE),
    ] {
        candidate::read(directory, bundle)?;
        for offline in [false, true] {
            let mut command = Command::new("gh");
            command
                .args(["attestation", "verify"])
                .arg(directory.join(name))
                .args([
                    "--repo",
                    candidate::REPOSITORY,
                    "--signer-workflow",
                    &signer,
                    "--cert-identity",
                    &certificate,
                    "--source-ref",
                    "refs/heads/main",
                    "--source-digest",
                    identity.source.as_str(),
                    "--signer-digest",
                    identity.source.as_str(),
                    "--deny-self-hosted-runners",
                    "--digest-alg",
                    algorithm,
                ]);
            if offline {
                command.arg("--bundle").arg(directory.join(bundle));
            }
            runner::output(&mut command)?;
        }
    }
    Ok(())
}

pub fn fetch(directory: &Path, identity: &Identity) -> Result<Candidate, String> {
    repository()?;
    verify_source(identity)?;
    let Origin::GitHub { run, attempt, .. } = &identity.origin else {
        return Err("hosted candidate required".into());
    };
    let metadata = required(&format!(
        "repos/{}/actions/runs/{run}/attempts/{attempt}",
        candidate::REPOSITORY
    ))?;
    validate_run(&metadata, identity)?;
    validate_run(
        &required(&format!(
            "repos/{}/actions/runs/{run}",
            candidate::REPOSITORY
        ))?,
        identity,
    )?;
    let artifacts = list(
        &format!(
            "repos/{}/actions/runs/{run}/artifacts",
            candidate::REPOSITORY
        ),
        Some("artifacts"),
    )?;
    let artifact = select_artifact(
        &artifacts,
        &format!("candidate-{}-{run}-", identity.source.as_str()),
        identity,
    )?;
    download(directory, *run, &artifact)?;
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    let jobs = jobs(*run)?;
    producer_matches(
        &candidate.identity,
        latest_success(&jobs, SEAL_JOB, identity)?,
    )?;
    producer_matches(
        &crate::evidence::receipt(directory, crate::evidence::GATE_RECEIPT)?.identity,
        latest_success(&jobs, BUILD_JOB, identity)?,
    )?;
    for platform in crate::evidence::PLATFORMS {
        producer_matches(
            &crate::evidence::receipt(directory, &format!("runtime-{platform}.json"))?.identity,
            latest_success(
                &jobs,
                &format!("Runtime compatibility ({platform})"),
                identity,
            )?,
        )?;
    }
    if artifact.attempt != latest_success(&jobs, ATTEST_JOB, identity)? {
        return Err("candidate signature artifact is older than its latest job".into());
    }
    latest_success(&jobs, VERIFY_JOB, identity)?;
    if !matches!(candidate.identity.origin, Origin::GitHub {attempt, ..} if attempt <= artifact.attempt)
    {
        return Err("candidate assembly is newer than its signing producer".into());
    }
    attestations(directory, identity)?;
    Ok(candidate)
}

pub fn proposal_checks() -> Result<(), String> {
    use gleam_mutants_release_core::{CiAction, CiRecord, proposal_ci};
    repository()?;
    let pulls = list(
        &format!("repos/{}/pulls?state=open", candidate::REPOSITORY),
        None,
    )?;
    for pull in pulls {
        let branch = pull["head"]["ref"]
            .as_str()
            .ok_or("proposal head is missing")?;
        if branch != PROPOSAL_BRANCH {
            continue;
        }
        validate_proposal(&pull)?;
        let source = Revision::try_from(
            pull["head"]["sha"]
                .as_str()
                .ok_or("proposal source is missing")?
                .to_owned(),
        )?;
        let number = pull["number"]
            .as_u64()
            .filter(|number| *number > 0)
            .ok_or("proposal number is missing")?;
        let files = list(
            &format!("repos/{}/pulls/{number}/files", candidate::REPOSITORY),
            None,
        )?;
        validate_proposal_files(&files)?;
        let source = crate::proposal::format(number, &source)?;
        let runs = list(
            &format!(
                "repos/{}/actions/workflows/ci.yml/runs?head_sha={}",
                candidate::REPOSITORY,
                source.as_str()
            ),
            Some("workflow_runs"),
        )?;
        let mut record = CiRecord::Missing;
        for run in runs {
            match proposal_run(&run, &source)? {
                ProposalRun::Present => record = CiRecord::Present,
                ProposalRun::Suppressed(id) => {
                    if !jobs(id)?.is_empty() {
                        return Err(
                            "approval-required CI already has jobs; inspect it without redispatch"
                                .into(),
                        );
                    }
                    if record != CiRecord::Present {
                        record = CiRecord::Suppressed;
                    }
                }
            }
        }
        let current = required(&format!("repos/{}/pulls/{number}", candidate::REPOSITORY))?;
        validate_proposal(&current)?;
        let reference = required(&format!(
            "repos/{}/git/ref/heads/{PROPOSAL_BRANCH}",
            candidate::REPOSITORY
        ))?;
        proposal_reference(&reference, &source)?;
        if proposal_ci(record) == CiAction::Dispatch {
            runner::output(Command::new("gh").args([
                "workflow",
                "run",
                "ci.yml",
                "--repo",
                candidate::REPOSITORY,
                "--ref",
                branch,
                "--field",
                &format!("source_sha={}", source.as_str()),
            ]))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proposal_ci_uses_the_exact_branch_reference() {
        let source = Revision::try_from("a".repeat(40)).unwrap();
        let reference = serde_json::json!({"ref":format!("refs/heads/{PROPOSAL_BRANCH}"),
            "object":{"type":"commit","sha":source.as_str()}});
        proposal_reference(&reference, &source).unwrap();
        let mut foreign = reference.clone();
        foreign["ref"] = serde_json::json!("refs/heads/main");
        assert!(proposal_reference(&foreign, &source).is_err());
        let mut tag = reference.clone();
        tag["object"]["type"] = serde_json::json!("tag");
        assert!(proposal_reference(&tag, &source).is_err());
        let mut changed = reference;
        changed["object"]["sha"] = serde_json::json!("b".repeat(40));
        assert!(proposal_reference(&changed, &source).is_err());
        assert!(proposal_reference(&Value::Null, &source).is_err());
    }

    fn proposal_record() -> Value {
        serde_json::json!({"id":1,"head_sha":"a".repeat(40),"head_branch":PROPOSAL_BRANCH,
            "path":".github/workflows/ci.yml","event":"pull_request","status":"completed","conclusion":"action_required",
            "actor":{"login":ACTIONS_BOT,"type":"Bot"},"triggering_actor":{"login":ACTIONS_BOT,"type":"Bot"},
            "repository":{"id":candidate::REPOSITORY_ID},"head_repository":{"id":candidate::REPOSITORY_ID}})
    }

    #[test]
    fn suppressed_internal_bot_records_are_not_executed_ci() {
        let source = Revision::try_from("a".repeat(40)).unwrap();
        let run = proposal_record();
        assert_eq!(proposal_run(&run, &source), Ok(ProposalRun::Suppressed(1)));
        for conclusion in ["success", "failure", "cancelled", "timed_out", "skipped"] {
            let mut actual = run.clone();
            actual["conclusion"] = serde_json::json!(conclusion);
            assert_eq!(proposal_run(&actual, &source), Ok(ProposalRun::Present));
        }
        let mut active = run.clone();
        active["status"] = serde_json::json!("in_progress");
        active["conclusion"] = Value::Null;
        assert_eq!(proposal_run(&active, &source), Ok(ProposalRun::Present));
        for (field, value) in [
            ("head_sha", serde_json::json!("b".repeat(40))),
            ("head_branch", serde_json::json!("another")),
            ("path", serde_json::json!("other.yml")),
        ] {
            let mut invalid = run.clone();
            invalid[field] = value;
            assert!(proposal_run(&invalid, &source).is_err());
        }
        let mut human = run.clone();
        human["actor"]["login"] = serde_json::json!("human");
        assert!(proposal_run(&human, &source).is_err());
        let mut foreign = run;
        foreign["head_repository"]["id"] = serde_json::json!(1);
        assert!(proposal_run(&foreign, &source).is_err());
    }

    #[test]
    fn proposal_file_scope_rejects_empty_removed_and_workflow_changes() {
        let file = serde_json::json!({"filename":"CHANGELOG.md","status":"modified"});
        validate_proposal_files(std::slice::from_ref(&file)).unwrap();
        assert!(validate_proposal_files(&[]).is_err());
        let mut removed = file.clone();
        removed["status"] = serde_json::json!("removed");
        assert!(validate_proposal_files(&[removed]).is_err());
        let mut workflow = file;
        workflow["filename"] = serde_json::json!(".github/workflows/ci.yml");
        assert!(validate_proposal_files(&[workflow]).is_err());
    }

    #[test]
    fn proposal_dispatch_requires_the_internal_bot_and_repository() {
        let pull = serde_json::json!({"state":"open", "user":{"login":ACTIONS_BOT,"type":"Bot"},
            "head":{"ref":PROPOSAL_BRANCH,"repo":{"id":candidate::REPOSITORY_ID,"fork":false}},
            "base":{"ref":"main","repo":{"id":candidate::REPOSITORY_ID}}});
        validate_proposal(&pull).unwrap();
        let mut human = pull.clone();
        human["user"]["login"] = serde_json::json!("human");
        assert!(validate_proposal(&human).is_err());
        let mut fork = pull.clone();
        fork["head"]["repo"]["fork"] = serde_json::json!(true);
        assert!(validate_proposal(&fork).is_err());
        let mut foreign = pull;
        foreign["base"]["repo"]["id"] = serde_json::json!(1);
        assert!(validate_proposal(&foreign).is_err());
    }

    #[test]
    fn artifact_selection_preserves_the_latest_eligible_producer() {
        let identity = expected(
            Revision::try_from("a".repeat(40)).unwrap(),
            Version::try_from("0.1.0".to_owned()).unwrap(),
            1,
            3,
        )
        .unwrap();
        let artifact = |attempt: u32| {
            serde_json::json!({
                "name": format!("build-1-{attempt}"), "expired": false,
                "workflow_run": {"id":1,"repository_id":candidate::REPOSITORY_ID,"head_sha":"a".repeat(40)}
            })
        };
        let mut expired = artifact(3);
        expired["expired"] = serde_json::json!(true);
        let rows = [artifact(1), artifact(2), expired, artifact(4)];
        assert_eq!(
            select_artifact(&rows, "build-1-", &identity)
                .unwrap()
                .attempt,
            2
        );
        assert!(select_artifact(&[artifact(1), artifact(1)], "build-1-", &identity).is_err());
        let mut invalid = artifact(2);
        invalid["workflow_run"]["head_sha"] = serde_json::json!("b".repeat(40));
        assert!(select_artifact(&[artifact(1), invalid], "build-1-", &identity).is_err());
        let mut malformed = artifact(1);
        malformed["name"] = serde_json::json!("build-1-01");
        assert!(select_artifact(&[malformed], "build-1-", &identity).is_err());
    }

    #[test]
    fn a_later_failed_or_skipped_job_invalidates_an_earlier_pass() {
        let identity = expected(
            Revision::try_from("a".repeat(40)).unwrap(),
            Version::try_from("0.1.0".to_owned()).unwrap(),
            1,
            3,
        )
        .unwrap();
        let passed = serde_json::json!({"name":"build","run_id":1,"run_attempt":1,"head_sha":"a".repeat(40),"status":"completed","conclusion":"success"});
        assert_eq!(
            latest_success(std::slice::from_ref(&passed), "build", &identity),
            Ok(1)
        );
        for conclusion in ["failure", "skipped", "cancelled"] {
            let mut later = passed.clone();
            later["run_attempt"] = serde_json::json!(2);
            later["conclusion"] = serde_json::json!(conclusion);
            assert!(latest_success(&[passed.clone(), later], "build", &identity).is_err());
        }
    }

    #[test]
    fn completed_runs_cannot_change_source_attempt_or_builder() {
        let identity = expected(
            Revision::try_from("a".repeat(40)).unwrap(),
            Version::try_from("0.1.0".to_owned()).unwrap(),
            1,
            1,
        )
        .unwrap();
        let valid = serde_json::json!({"id":1,"run_attempt":1,"head_sha":"a".repeat(40),"head_branch":"main","event":"workflow_dispatch",
            "path":candidate::CANDIDATE_WORKFLOW,"status":"completed","conclusion":"success",
            "repository":{"id":candidate::REPOSITORY_ID},"head_repository":{"id":candidate::REPOSITORY_ID}});
        assert!(validate_run(&valid, &identity).is_ok());
        for (field, value) in [
            ("head_sha", serde_json::json!("b".repeat(40))),
            ("run_attempt", serde_json::json!(2)),
            ("head_branch", serde_json::json!("feature")),
            ("event", serde_json::json!("pull_request")),
            ("conclusion", serde_json::json!("failure")),
            ("path", serde_json::json!("other.yml")),
        ] {
            let mut invalid = valid.clone();
            invalid[field] = value;
            assert!(validate_run(&invalid, &identity).is_err(), "{field}");
        }
    }
}
