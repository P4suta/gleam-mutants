// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Artifact, Revision};
use crate::evidence::{self, Candidate, Identity};
use crate::{constants, github, registry, runner};
pub use gleam_mutants_release_core::{ControllerIdentity, PublicationPhase as Phase};
use gleam_mutants_release_core::{
    Existing, ReleaseId, ReleaseSelection, WritePlan, acquire_release, can_finalize, plan_write,
    with_draft_evidence,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const WORKFLOW: &str = ".github/workflows/release-publish.yml";
const TAG_CHAIN_BOUND: usize = 8;
pub(crate) const DRAFT_JOB: &str = "Prepare immutable tag and complete draft";
pub(crate) const READINESS_JOB: &str = "registry-ready";

struct ControllerRun {
    source: Revision,
    run: u64,
    attempt: u32,
}

impl ControllerRun {
    fn from_environment() -> Result<Self, String> {
        let source = Revision::try_from(runner::environment("GITHUB_SHA")?)?;
        let identity = ControllerIdentity::parse(
            &runner::environment("GITHUB_RUN_ID")?,
            &runner::environment("GITHUB_RUN_ATTEMPT")?,
        )
        .map_err(|error| error.message())?;
        Ok(Self {
            source,
            run: identity.run(),
            attempt: identity.attempt(),
        })
    }

    fn validate(&self, run: &Value) -> Result<(), String> {
        for (pointer, expected) in [
            ("/id", serde_json::json!(self.run)),
            ("/run_attempt", serde_json::json!(self.attempt)),
            ("/head_sha", serde_json::json!(self.source.as_str())),
            ("/head_branch", serde_json::json!("main")),
            ("/path", serde_json::json!(WORKFLOW)),
            ("/event", serde_json::json!("workflow_dispatch")),
            (
                "/repository/id",
                serde_json::json!(candidate::REPOSITORY_ID),
            ),
            (
                "/repository/owner/id",
                serde_json::json!(candidate::OWNER_ID),
            ),
            (
                "/head_repository/id",
                serde_json::json!(candidate::REPOSITORY_ID),
            ),
            ("/status", serde_json::json!("in_progress")),
            ("/conclusion", Value::Null),
        ] {
            if run.pointer(pointer) != Some(&expected) {
                return Err(format!(
                    "draft preparation controller binding differs: {pointer}"
                ));
            }
        }
        Ok(())
    }
}

struct PreparedDraft {
    producer_attempt: u32,
}

fn prepared_draft_from(
    controller: &ControllerRun,
    read: impl FnOnce(&str) -> Result<Value, String>,
    jobs: impl FnOnce(&str) -> Result<Vec<Value>, String>,
) -> Result<PreparedDraft, String> {
    let root = format!(
        "repos/{}/actions/runs/{}",
        candidate::REPOSITORY,
        controller.run
    );
    controller.validate(&read(&root)?)?;
    let jobs = jobs(&format!("{root}/jobs?filter=all"))?;
    let producer_attempt = github::latest_success_for(
        &jobs,
        DRAFT_JOB,
        &controller.source,
        controller.run,
        controller.attempt,
    )?;
    Ok(PreparedDraft { producer_attempt })
}

fn completed_preparation() -> Result<PreparedDraft, String> {
    let controller = ControllerRun::from_environment()?;
    let proof = prepared_draft_from(&controller, github::required, |path| {
        github::list(path, Some("jobs"))
    })?;
    println!(
        "Verified draft preparation in controller {} at producer attempt {}",
        controller.run, proof.producer_attempt
    );
    Ok(proof)
}

#[derive(Clone)]
pub struct ExecutionContext {
    pub actions: String,
    pub repository: String,
    pub workflow: String,
    pub reference: String,
    pub protected: String,
    pub job: String,
    pub environment: String,
}

pub fn approved_context(phase: Phase, context: &ExecutionContext) -> Result<(), String> {
    if context.actions != "true"
        || context.repository != candidate::REPOSITORY
        || context.reference != "refs/heads/main"
        || context.protected != "true"
        || context.workflow != format!("{}/{WORKFLOW}@refs/heads/main", candidate::REPOSITORY)
        || context.job != phase.job()
        || context.environment != phase.environment()
    {
        return Err(
            "publication requires its protected main controller, phase, and approved environment"
                .into(),
        );
    }
    Ok(())
}

fn approval(phase: Phase) -> Result<(), String> {
    approved_context(
        phase,
        &ExecutionContext {
            actions: runner::environment("GITHUB_ACTIONS")?,
            repository: runner::environment("GITHUB_REPOSITORY")?,
            workflow: runner::environment("GITHUB_WORKFLOW_REF")?,
            reference: runner::environment("GITHUB_REF")?,
            protected: runner::environment("GITHUB_REF_PROTECTED")?,
            job: runner::environment("GITHUB_JOB")?,
            environment: runner::environment("RELEASE_ENVIRONMENT")?,
        },
    )
}

pub fn controller_context() -> Result<(), String> {
    if runner::environment("GITHUB_ACTIONS")? != "true"
        || runner::environment("GITHUB_REPOSITORY")? != candidate::REPOSITORY
        || runner::environment("GITHUB_REF")? != "refs/heads/main"
        || runner::environment("GITHUB_REF_PROTECTED")? != "true"
        || runner::environment("GITHUB_WORKFLOW_REF")?
            != format!("{}/{WORKFLOW}@refs/heads/main", candidate::REPOSITORY)
    {
        return Err("release controller must run from protected main".into());
    }
    Ok(())
}

pub fn controller_outputs() -> Result<(), String> {
    controller_context()?;
    let ControllerRun {
        source,
        run,
        attempt,
    } = ControllerRun::from_environment()?;
    let mut output = fs::OpenOptions::new()
        .append(true)
        .open(runner::environment("GITHUB_OUTPUT")?)
        .map_err(|e| e.to_string())?;
    writeln!(
        output,
        "artifact=release-controller-{}-{run}-{attempt}",
        source.as_str()
    )
    .map_err(|e| e.to_string())
}

pub fn plan(directory: &Path, identity: &Identity) -> Result<(), String> {
    controller_context()?;
    github::repository()?;
    github::verify_source(identity)?;
    version_proposal(identity)?;
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    github::attestations(directory, identity)?;
    let expected = assets(directory, &candidate)?;
    let tag = tag(identity)?;
    if tag == Existing::Conflicting {
        return Err("release tag belongs to another source".into());
    }
    if let Some(release) = release(identity)? {
        let release = require_draft(release, &identity.version.tag())?;
        let mut store = store(directory, &release)?;
        let inventory = store.inventory()?;
        for name in inventory {
            let asset = expected
                .iter()
                .find(|a| a.path == name)
                .ok_or("draft has unexpected assets")?;
            if candidate::digest(&store.bytes(&name)?) != asset.sha256 {
                return Err("draft has conflicting asset bytes".into());
            }
        }
    }
    let hex = registry_artifact(&candidate, "gleam_mutants-")?;
    if registry::observe(registry::Registry::Hex, &identity.version, &hex.sha256)?
        == Existing::Conflicting
        || registry::observe(
            registry::Registry::Npm,
            &identity.version,
            &candidate.npm()?.sha256,
        )? == Existing::Conflicting
    {
        return Err("a registry version belongs to another archive".into());
    }
    let requested = requested_draft(&runner::environment("DRAFT_RELEASE_ID")?)?;
    let plan = serde_json::json!({"source":identity.source,"version":identity.version,"build":identity.origin,
        "assets":expected,"phases":["draft","hex","npm","finalize"],
        "requested_draft_id":requested.map(ReleaseId::get),
        "draft_assets":"checked_in_approved_draft_phase","publication_performed":false});
    evidence::write_new(Path::new("release-plan.json"), &plan)?;
    println!(
        "{}",
        serde_json::to_string_pretty(&plan).map_err(|e| e.to_string())?
    );
    Ok(())
}

fn mutate(args: &[&str], body: &Value) -> Result<Value, String> {
    let mut command = Command::new("gh");
    command.args(args);
    mutate_command(&mut command, body)
        .map_err(|error| format!("GitHub {}: {error}", args.join(" ")))
}

fn mutate_command(command: &mut Command, body: &Value) -> Result<Value, String> {
    let input = serde_json::to_vec(body).map_err(|e| e.to_string())?;
    command
        .args([
            "--input",
            "-",
            "--header",
            "Content-Type: application/json",
            "--header",
            &format!("Content-Length: {}", input.len()),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| format!("start GitHub mutation: {e}"))?;
    let written = match child.stdin.take() {
        Some(mut stdin) => stdin.write_all(&input),
        None => Err(std::io::Error::other("missing GitHub input")),
    };
    if let Err(error) = written {
        let killed = child.kill();
        let reaped = child.wait();
        return Err(format!(
            "GitHub input failed: {error}; cleanup kill={killed:?}, wait={reaped:?}"
        ));
    }
    let output = child
        .wait_with_output()
        .map_err(|e| format!("GitHub mutation completion is uncertain: {e}"))?;
    if !output.status.success() {
        return Err(format!(
            "GitHub mutation did not confirm success: {}; inspect remote state before retry",
            output.status
        ));
    }
    serde_json::from_slice(&output.stdout).map_err(|error| {
        format!("GitHub mutation returned invalid JSON; inspect remote state before retry: {error}")
    })
}

fn tag(identity: &Identity) -> Result<Existing, String> {
    let path = format!(
        "repos/{}/git/ref/tags/{}",
        candidate::REPOSITORY,
        identity.version.tag()
    );
    let Some(mut value) = github::get(&path)? else {
        return Ok(Existing::Missing);
    };
    for _ in 0..TAG_CHAIN_BOUND {
        let object = &value["object"];
        let source = Revision::try_from(
            object["sha"]
                .as_str()
                .ok_or("release tag has no source")?
                .to_owned(),
        )?;
        match object["type"].as_str() {
            Some("commit") => {
                return Ok(if source == identity.source {
                    Existing::Matching
                } else {
                    Existing::Conflicting
                });
            }
            Some("tag") => {
                value = github::required(&format!(
                    "repos/{}/git/tags/{}",
                    candidate::REPOSITORY,
                    source.as_str()
                ))?
            }
            _ => return Err("release ref is not a commit or annotated tag".into()),
        }
    }
    Err("release tag exceeded the complete dereference bound".into())
}

fn release(identity: &Identity) -> Result<Option<Value>, String> {
    release_from(&identity.version.tag(), |path| github::list(path, None))
}

fn release_from(
    tag: &str,
    read: impl FnOnce(&str) -> Result<Vec<Value>, String>,
) -> Result<Option<Value>, String> {
    let mut selection = ReleaseSelection::Missing;
    let mut found = None;
    for release in read(&format!("repos/{}/releases", candidate::REPOSITORY))? {
        let observed_tag = release["tag_name"]
            .as_str()
            .ok_or("release catalogue entry has no valid tag")?;
        if observed_tag != tag {
            continue;
        }
        let id = release["id"]
            .as_u64()
            .and_then(ReleaseId::new)
            .ok_or("matching release has no valid ID")?;
        selection = selection.include(id);
        match selection {
            ReleaseSelection::Unique(_) => found = Some(release),
            ReleaseSelection::Ambiguous => {
                return Err("release catalogue has duplicate matching tags".into());
            }
            ReleaseSelection::Missing => {
                return Err("release selection lost a matching identity".into());
            }
        }
    }
    Ok(found)
}

fn require_draft(release: Value, tag: &str) -> Result<Value, String> {
    release_id(&release)?;
    if release["draft"] != true
        || release["tag_name"] != tag
        || release["immutable"] != false
        || release.get("published_at") != Some(&Value::Null)
    {
        return Err("target is published or has another release identity".into());
    }
    Ok(release)
}

fn release_id(release: &Value) -> Result<ReleaseId, String> {
    release["id"]
        .as_u64()
        .and_then(ReleaseId::new)
        .ok_or("release has no valid ID".into())
}

fn requested_draft(text: &str) -> Result<Option<ReleaseId>, String> {
    if text.is_empty() {
        return Ok(None);
    }
    ReleaseId::parse(text)
        .map(Some)
        .ok_or("requested draft release ID must be a positive integer".into())
}

fn acquire_draft_from(
    tag: &str,
    discover: impl FnOnce() -> Result<Option<Value>, String>,
    create: impl FnOnce() -> Result<Value, String>,
) -> Result<Value, String> {
    acquire_release(
        || {
            discover()?
                .map(|value| require_draft(value, tag))
                .transpose()
        },
        || require_draft(create()?, tag),
    )
}

fn draft(identity: &Identity) -> Result<Value, String> {
    if tag(identity)? != Existing::Matching {
        return Err("release tag does not identify the verified source".into());
    }
    let id = ReleaseId::parse(&runner::environment("RELEASE_ID")?)
        .ok_or("finalization requires the verified nonzero draft ID")?;
    let release = release_by_id(id)?;
    require_draft(release, &identity.version.tag())
}

fn release_by_id(id: ReleaseId) -> Result<Value, String> {
    release_by_id_from(id, github::required)
}

fn release_by_id_from(
    id: ReleaseId,
    read: impl FnOnce(&str) -> Result<Value, String>,
) -> Result<Value, String> {
    let release = read(&format!(
        "repos/{}/releases/{}",
        candidate::REPOSITORY,
        id.get()
    ))?;
    if release_id(&release)? != id {
        return Err("GitHub release read returned another ID".into());
    }
    Ok(release)
}

fn require_published(release: &Value, id: ReleaseId, tag: &str) -> Result<(), String> {
    if release_id(release)? != id
        || release["tag_name"] != tag
        || release["draft"] != false
        || release["immutable"] != true
        || release["published_at"].as_str().is_none_or(str::is_empty)
    {
        return Err("publication did not confirm the selected immutable release; inspect remote state before retry".into());
    }
    Ok(())
}

fn assets(directory: &Path, candidate: &Candidate) -> Result<Vec<Artifact>, String> {
    let mut names: Vec<_> = candidate
        .artifacts
        .iter()
        .chain(&candidate.evidence)
        .map(|a| a.path.clone())
        .collect();
    names.extend(
        [
            evidence::MANIFEST,
            "SHA256SUMS",
            "CANDIDATE-SHA256SUMS",
            github::GENERAL_BUNDLE,
            github::NPM_BUNDLE,
        ]
        .map(str::to_owned),
    );
    names.sort();
    let mut items: Vec<_> = names
        .iter()
        .map(|name| candidate::artifact(directory, name))
        .collect::<Result<_, _>>()?;
    let sums: String = items
        .iter()
        .map(|a| format!("{}  {}\n", a.sha256, a.path))
        .collect();
    let path = directory.join("RELEASE-SHA256SUMS");
    if path.exists() {
        if candidate::read(directory, "RELEASE-SHA256SUMS")? != sums.as_bytes() {
            return Err("final release checksums changed".into());
        }
    } else {
        evidence::write_bytes_new(&path, sums.as_bytes())?;
    }
    items.push(candidate::artifact(directory, "RELEASE-SHA256SUMS")?);
    Ok(items)
}

pub trait AssetStore {
    fn inventory(&mut self) -> Result<Vec<String>, String>;
    fn bytes(&mut self, name: &str) -> Result<Vec<u8>, String>;
    fn upload(&mut self, artifact: &Artifact) -> Result<(), String>;
}

pub fn reconcile(
    store: &mut impl AssetStore,
    expected: &[Artifact],
    write: bool,
) -> Result<(), String> {
    let inventory = store.inventory()?;
    let mut names = BTreeMap::new();
    for name in inventory {
        if !expected.iter().any(|a| a.path == name) || names.insert(name, ()).is_some() {
            return Err("release draft contains duplicate or unexpected assets".into());
        }
    }
    let mut pending = Vec::new();
    for artifact in expected {
        let observed = if names.contains_key(&artifact.path) {
            if candidate::digest(&store.bytes(&artifact.path)?) == artifact.sha256 {
                Existing::Matching
            } else {
                Existing::Conflicting
            }
        } else {
            Existing::Missing
        };
        match plan_write(true, observed) {
            WritePlan::Reuse => {}
            WritePlan::Refuse => {
                return Err(format!(
                    "release asset conflicts with verified bytes: {}",
                    artifact.path
                ));
            }
            WritePlan::Create if write => pending.push(artifact),
            WritePlan::Create => {
                return Err(format!("release asset is missing: {}", artifact.path));
            }
        }
    }
    for artifact in pending {
        store.upload(artifact)?;
    }
    Ok(())
}

struct GitHubAssets<'a> {
    directory: &'a Path,
    release_id: ReleaseId,
    inventory: BTreeMap<String, (u64, u64)>,
}

impl AssetStore for GitHubAssets<'_> {
    fn inventory(&mut self) -> Result<Vec<String>, String> {
        let assets = github::list(
            &format!(
                "repos/{}/releases/{}/assets",
                candidate::REPOSITORY,
                self.release_id.get()
            ),
            None,
        )?;
        self.inventory.clear();
        for asset in assets {
            let name = asset["name"]
                .as_str()
                .ok_or("release asset name is missing")?
                .to_owned();
            let id = asset["id"]
                .as_u64()
                .filter(|id| *id != 0)
                .ok_or("invalid release asset ID")?;
            let size = asset["size"]
                .as_u64()
                .filter(|size| *size <= candidate::MAXIMUM_FILE_BYTES)
                .ok_or("release asset exceeds its admitted size")?;
            if self.inventory.insert(name, (id, size)).is_some() {
                return Err("release asset identity is duplicated".into());
            }
        }
        Ok(self.inventory.keys().cloned().collect())
    }
    fn bytes(&mut self, name: &str) -> Result<Vec<u8>, String> {
        let (id, size) = self
            .inventory
            .get(name)
            .ok_or("release asset was not inventoried")?;
        let result = runner::output(Command::new("gh").args([
            "api",
            "--method",
            "GET",
            "--allow-escape-sequences",
            "--header",
            "Accept: application/octet-stream",
            &format!("repos/{}/releases/assets/{id}", candidate::REPOSITORY),
        ]))?;
        if result.stdout.len() as u64 != *size {
            return Err("release asset read differs from its inventoried size".into());
        }
        Ok(result.stdout)
    }
    fn upload(&mut self, artifact: &Artifact) -> Result<(), String> {
        if candidate::artifact(self.directory, &artifact.path)? != *artifact {
            return Err("local asset changed before upload".into());
        }
        let result = runner::output(&mut upload_command(
            self.directory,
            self.release_id,
            artifact,
        ))?;
        let uploaded: Value = serde_json::from_slice(&result.stdout).map_err(|error| {
            format!(
                "asset upload returned invalid JSON; inspect remote state before retry: {error}"
            )
        })?;
        require_uploaded(&uploaded, artifact)
    }
}

fn require_uploaded(uploaded: &Value, artifact: &Artifact) -> Result<(), String> {
    if uploaded["name"] != artifact.path
        || uploaded["size"] != artifact.bytes
        || uploaded["state"] != "uploaded"
        || uploaded["id"].as_u64().filter(|id| *id != 0).is_none()
    {
        return Err(
            "asset upload did not confirm the expected identity; inspect remote state before retry"
                .into(),
        );
    }
    Ok(())
}

fn store<'a>(directory: &'a Path, release: &Value) -> Result<GitHubAssets<'a>, String> {
    let release_id = release_id(release)?;
    Ok(GitHubAssets {
        directory,
        release_id,
        inventory: BTreeMap::new(),
    })
}

fn upload_command(directory: &Path, release: ReleaseId, artifact: &Artifact) -> Command {
    let mut command = Command::new("gh");
    command
        .args([
            "api",
            "--method",
            "POST",
            "--header",
            "Content-Type: application/octet-stream",
            "--header",
            &format!("Content-Length: {}", artifact.bytes),
            &format!(
                "{}/repos/{}/releases/{}/assets",
                constants::GITHUB_UPLOADS_ORIGIN,
                candidate::REPOSITORY,
                release.get()
            ),
            "--raw-field",
            &format!("name={}", artifact.path),
            "--input",
        ])
        .arg(directory.join(&artifact.path));
    command
}

fn registry_artifact<'a>(candidate: &'a Candidate, prefix: &str) -> Result<&'a Artifact, String> {
    candidate
        .artifacts
        .iter()
        .find(|a| a.path.starts_with(prefix) && !a.path.ends_with(".json"))
        .ok_or("registry archive is missing".into())
}

enum DraftEvidence {
    Live(Value),
    Completed,
}

impl DraftEvidence {
    fn live(self) -> Result<Value, String> {
        match self {
            Self::Live(release) => Ok(release),
            Self::Completed => Err("GitHub publication requires current draft inspection".into()),
        }
    }
}

fn draft_evidence(phase: Phase, identity: &Identity) -> Result<DraftEvidence, String> {
    with_draft_evidence(
        phase,
        || draft(identity).map(DraftEvidence::Live),
        || completed_preparation().map(|_| DraftEvidence::Completed),
    )
}

fn registry_plan(
    phase: Phase,
    identity: &Identity,
    candidate: &Candidate,
) -> Result<WritePlan, String> {
    let (registry, artifact) = match phase {
        Phase::Hex => (
            registry::Registry::Hex,
            registry_artifact(candidate, "gleam_mutants-")?,
        ),
        Phase::Npm => {
            npm_client()?;
            match runner::environment("NPM_PUBLISH_AUTH")?.as_str() {
                "trusted" | "bootstrap" => {}
                _ => return Err("npm authentication must be trusted or bootstrap".into()),
            }
            (registry::Registry::Npm, candidate.npm()?)
        }
        Phase::Draft | Phase::Finalize => {
            return Err("registry preparation requires hex or npm".into());
        }
    };
    if tag(identity)? != Existing::Matching {
        return Err("registry preparation requires the matching version tag".into());
    }
    match draft_evidence(phase, identity)? {
        DraftEvidence::Completed => {}
        DraftEvidence::Live(_) => {
            return Err("registry phase requires completed draft preparation".into());
        }
    }
    let plan = plan_write(
        true,
        registry::observe(registry, &identity.version, &artifact.sha256)?,
    );
    match plan {
        WritePlan::Create | WritePlan::Reuse => Ok(plan),
        WritePlan::Refuse => {
            Err("registry version contains different verified archive bytes".into())
        }
    }
}

pub fn registry_ready(phase: Phase, directory: &Path, identity: &Identity) -> Result<(), String> {
    controller_context()?;
    if runner::environment("GITHUB_JOB")? != READINESS_JOB {
        return Err("registry readiness requires its read-only hosted job".into());
    }
    github::repository()?;
    github::verify_source(identity)?;
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    github::attestations(directory, identity)?;
    let plan = registry_plan(phase, identity, &candidate)?;
    println!(
        "Registry {} prerequisites verified without publication: {plan:?}",
        phase.job()
    );
    Ok(())
}

pub fn execute(phase: Phase, directory: &Path, identity: &Identity) -> Result<(), String> {
    approval(phase)?;
    github::repository()?;
    github::verify_source(identity)?;
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    github::attestations(directory, identity)?;
    match phase {
        Phase::Draft => create_draft(directory, identity, &assets(directory, &candidate)?),
        Phase::Hex => {
            let artifact = registry_artifact(&candidate, "gleam_mutants-")?;
            match registry_plan(phase, identity, &candidate)? {
                WritePlan::Reuse => Ok(()),
                WritePlan::Refuse => Err("Hex version contains different bytes".into()),
                WritePlan::Create => {
                    registry::publish_hex(
                        &directory.join(&artifact.path),
                        &runner::environment("HEXPM_API_KEY")?,
                    )?;
                    if registry::observe(
                        registry::Registry::Hex,
                        &identity.version,
                        &artifact.sha256,
                    )? != Existing::Matching
                    {
                        return Err("Hex readback does not match the verified archive".into());
                    }
                    Ok(())
                }
            }
        }
        Phase::Npm => {
            let artifact = candidate.npm()?;
            match registry_plan(phase, identity, &candidate)? {
                WritePlan::Reuse => Ok(()),
                WritePlan::Refuse => Err("npm version contains different bytes".into()),
                WritePlan::Create => {
                    publish_npm(directory, &candidate)?;
                    if registry::observe(
                        registry::Registry::Npm,
                        &identity.version,
                        &artifact.sha256,
                    )? != Existing::Matching
                    {
                        return Err("npm readback does not match the verified archive".into());
                    }
                    Ok(())
                }
            }
        }
        Phase::Finalize => {
            let expected = assets(directory, &candidate)?;
            let release = draft_evidence(phase, identity)?.live()?;
            reconcile(&mut store(directory, &release)?, &expected, false)?;
            let hex = registry_artifact(&candidate, "gleam_mutants-")?;
            let npm = candidate.npm()?;
            let allowed = can_finalize(
                tag(identity)? == Existing::Matching,
                true,
                registry::observe(registry::Registry::Hex, &identity.version, &hex.sha256)?
                    == Existing::Matching,
                registry::observe(registry::Registry::Npm, &identity.version, &npm.sha256)?
                    == Existing::Matching,
                release["draft"] == true,
            );
            if !allowed {
                return Err(
                    "final publication lacks a matching tag, assets, or registry output".into(),
                );
            }
            let id = release_id(&release)?;
            let response = mutate(
                &[
                    "api",
                    "--method",
                    "PATCH",
                    &format!("repos/{}/releases/{}", candidate::REPOSITORY, id.get()),
                ],
                &serde_json::json!({"draft":false}),
            )?;
            require_published(&response, id, &identity.version.tag())?;
            let observed = release_by_id(id)?;
            require_published(&observed, id, &identity.version.tag())?;
            if tag(identity)? != Existing::Matching {
                return Err("final publication did not confirm its target".into());
            }
            reconcile(&mut store(directory, &observed)?, &expected, false)?;
            Ok(())
        }
    }
}

fn version_proposal(identity: &Identity) -> Result<(), String> {
    let manifest = runner::output(Command::new("gh").args([
        "api",
        "--method",
        "GET",
        "--header",
        "Accept: application/vnd.github.raw+json",
        &format!(
            "repos/{}/contents/.release-please-manifest.json?ref={}",
            candidate::REPOSITORY,
            identity.source.as_str()
        ),
    ]))?;
    let manifest: Value = serde_json::from_slice(&manifest.stdout).map_err(|e| e.to_string())?;
    if manifest["."] != identity.version.as_str() {
        return Err("the version proposal must merge before tagging".into());
    }
    Ok(())
}

fn create_draft(
    directory: &Path,
    identity: &Identity,
    expected: &[Artifact],
) -> Result<(), String> {
    let selected = match requested_draft(&runner::environment("DRAFT_RELEASE_ID")?)? {
        Some(id) => Some(release_by_id(id)?),
        None => release(identity)?,
    };
    let existing = selected
        .map(|release| require_draft(release, &identity.version.tag()))
        .transpose()?;
    version_proposal(identity)?;
    match plan_write(true, tag(identity)?) {
        WritePlan::Reuse => {}
        WritePlan::Refuse => return Err("existing release tag identifies another source".into()),
        WritePlan::Create => {
            mutate(
                &[
                    "api",
                    "--method",
                    "POST",
                    &format!("repos/{}/git/refs", candidate::REPOSITORY),
                ],
                &serde_json::json!({"ref":format!("refs/tags/{}", identity.version.tag()),"sha":identity.source.as_str()}),
            )?;
        }
    }
    if tag(identity)? != Existing::Matching {
        return Err("release tag creation did not confirm the source".into());
    }
    let release = acquire_draft_from(
        &identity.version.tag(),
        || Ok(existing),
        || {
            let notes = runner::output(Command::new("gh").args([
                "api",
                "--method",
                "GET",
                "--header",
                "Accept: application/vnd.github.raw+json",
                &format!(
                    "repos/{}/contents/CHANGELOG.md?ref={}",
                    candidate::REPOSITORY,
                    identity.source.as_str()
                ),
            ]))?;
            let notes = String::from_utf8(notes.stdout)
                .map_err(|error| format!("release notes are not UTF-8: {error}"))?;
            mutate(
                &[
                    "api",
                    "--method",
                    "POST",
                    &format!("repos/{}/releases", candidate::REPOSITORY),
                ],
                &serde_json::json!({"tag_name":identity.version.tag(),"target_commitish":identity.source.as_str(),
                "name":identity.version.tag(),"body":notes,"draft":true}),
            )
        },
    )?;
    if tag(identity)? != Existing::Matching {
        return Err("release tag does not identify the verified source".into());
    }
    let mut store = store(directory, &release)?;
    reconcile(&mut store, expected, true)?;
    reconcile(&mut store, expected, false)?;
    let id = release_id(&release)?;
    let mut output = fs::OpenOptions::new()
        .append(true)
        .open(runner::environment("GITHUB_OUTPUT")?)
        .map_err(|error| format!("open draft output: {error}"))?;
    writeln!(output, "release_id={}", id.get())
        .map_err(|error| format!("record verified draft ID: {error}"))
}

fn npm_client() -> Result<(), String> {
    for (tool, minimum) in [("node", "22.14.0"), ("npm", "11.5.1")] {
        let observed = runner::output(Command::new(tool).arg("--version"))?;
        minimum_client(&String::from_utf8_lossy(&observed.stdout), minimum)?;
    }
    Ok(())
}

fn publish_npm(directory: &Path, candidate: &Candidate) -> Result<(), String> {
    npm_client()?;
    let mode = runner::environment("NPM_PUBLISH_AUTH")?;
    let bootstrap = match mode.as_str() {
        "trusted" => None,
        "bootstrap" => Some(runner::environment("NPM_BOOTSTRAP_TOKEN")?),
        _ => return Err("npm authentication must be trusted or bootstrap".into()),
    };
    if mode == "trusted" && std::env::var("NPM_BOOTSTRAP_TOKEN").is_ok_and(|v| !v.is_empty()) {
        return Err("trusted npm publication rejects an inherited bootstrap token".into());
    }
    if let Some(key) = &bootstrap {
        registry::validate_key(key)?;
    }
    for name in [
        "NODE_AUTH_TOKEN",
        "NPM_TOKEN",
        "NPM_CONFIG__AUTH",
        "NPM_CONFIG__AUTHTOKEN",
    ] {
        if std::env::var(name).is_ok_and(|v| !v.is_empty()) {
            return Err(format!(
                "npm publication rejects inherited authentication: {name}"
            ));
        }
    }
    let root = PathBuf::from(format!("npm-publication-{}", std::process::id()));
    fs::create_dir(&root).map_err(|e| e.to_string())?;
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let userconfig = root.join("userconfig");
    let globalconfig = root.join("globalconfig");
    let config = if bootstrap.is_some() {
        constants::NPM_BOOTSTRAP_CONFIG
    } else {
        ""
    };
    evidence::write_bytes_new(&userconfig, config.as_bytes())?;
    evidence::write_bytes_new(&globalconfig, b"")?;
    let npm = candidate.npm()?;
    let mut command = Command::new("npm");
    command.env_clear();
    for name in [
        "PATH",
        "HOME",
        "CI",
        "GITHUB_ACTIONS",
        "GITHUB_SERVER_URL",
        "GITHUB_REPOSITORY",
        "GITHUB_REPOSITORY_ID",
        "GITHUB_REPOSITORY_OWNER_ID",
        "GITHUB_WORKFLOW_REF",
        "GITHUB_SHA",
        "GITHUB_REF",
        "GITHUB_RUN_ID",
        "GITHUB_RUN_ATTEMPT",
        "GITHUB_EVENT_NAME",
        "RUNNER_ENVIRONMENT",
        "ACTIONS_ID_TOKEN_REQUEST_URL",
        "ACTIONS_ID_TOKEN_REQUEST_TOKEN",
    ] {
        if let Ok(value) = std::env::var(name) {
            command.env(name, value);
        }
    }
    if let Some(key) = bootstrap {
        command.env("NPM_BOOTSTRAP_TOKEN", key);
    }
    command
        .args(["publish"])
        .arg(directory.join(&npm.path))
        .args([
            "--ignore-scripts",
            "--access",
            "public",
            "--registry",
            constants::NPM_REGISTRY,
            "--tag",
            candidate.identity.version.npm_tag(),
            "--provenance=false",
            "--provenance-file",
        ])
        .arg(directory.join(github::NPM_BUNDLE))
        .arg("--userconfig")
        .arg(userconfig)
        .arg("--globalconfig")
        .arg(globalconfig)
        .arg("--cache")
        .arg(root.join("cache"));
    let published = runner::output(&mut command).map(|_| ());
    let cleanup = fs::remove_dir_all(&root).map_err(|e| format!("npm configuration cleanup: {e}"));
    match (published, cleanup) {
        (Ok(()), Ok(())) => Ok(()),
        (Err(error), Ok(())) | (Ok(()), Err(error)) => Err(error),
        (Err(primary), Err(cleanup)) => Err(format!("{primary}; {cleanup}")),
    }
}

fn minimum_client(observed: &str, minimum: &str) -> Result<(), String> {
    let observed = observed.trim().strip_prefix('v').unwrap_or(observed.trim());
    let version =
        semver::Version::parse(observed).map_err(|_| "invalid publication client version")?;
    let minimum = semver::Version::parse(minimum).map_err(|_| "invalid minimum client version")?;
    if version < minimum || !version.pre.is_empty() {
        return Err(format!(
            "publication client {version} must be stable and at least {minimum}"
        ));
    }
    Ok(())
}

#[cfg(test)]
#[path = "publication_transport_tests.rs"]
mod transport_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn confirmed_creation_survives_an_unavailable_collection_entry() {
        const RELEASE_ID: u64 = 42;
        let tag = "v0.1.0";
        let created = serde_json::json!({"id":RELEASE_ID,"tag_name":tag,"draft":true,"immutable":false,"published_at":null});
        let mut discoveries = 0;
        let mut creations = 0;
        let observed = acquire_draft_from(
            tag,
            || {
                discoveries += 1;
                Ok(None)
            },
            || {
                creations += 1;
                Ok(created.clone())
            },
        );
        assert_eq!(observed, Ok(created));
        assert_eq!((discoveries, creations), (1, 1));
    }

    #[test]
    fn draft_acquisition_preserves_existing_identity_and_never_retries_errors() {
        const RELEASE_ID: u64 = 42;
        let tag = "v0.1.0";
        let existing = serde_json::json!({"id":RELEASE_ID,"tag_name":tag,"draft":true,"immutable":false,"published_at":null});
        assert_eq!(
            acquire_draft_from(
                tag,
                || Ok(Some(existing.clone())),
                || panic!("an existing draft must not be created again")
            )
            .unwrap(),
            existing
        );
        assert_eq!(
            acquire_draft_from(
                tag,
                || Err("discovery failed".into()),
                || panic!("a failed discovery cannot authorize creation")
            ),
            Err("discovery failed".into())
        );
        let mut creations = 0;
        let result = acquire_draft_from(
            tag,
            || Ok(None),
            || {
                creations += 1;
                Err("uncertain creation".into())
            },
        );
        assert_eq!(result, Err("uncertain creation".into()));
        assert_eq!(creations, 1);
        let mut published = existing.clone();
        published["draft"] = serde_json::json!(false);
        assert!(
            acquire_draft_from(
                tag,
                || Ok(Some(published)),
                || panic!("a published target must never be replaced")
            )
            .is_err()
        );
        for invalid in [
            serde_json::json!({}),
            serde_json::json!({"id":0,"draft":true,"tag_name":tag}),
            serde_json::json!({"id":RELEASE_ID,"draft":false,"tag_name":tag}),
            serde_json::json!({"id":RELEASE_ID,"draft":true,"tag_name":"v0.2.0"}),
        ] {
            assert!(acquire_draft_from(tag, || Ok(None), || Ok(invalid)).is_err());
        }
    }

    #[test]
    fn explicit_draft_ids_are_validated_and_reads_cannot_change_the_identity() {
        const RELEASE_ID: u64 = 42;
        let id = ReleaseId::new(RELEASE_ID).unwrap();
        assert_eq!(requested_draft(""), Ok(None));
        assert_eq!(requested_draft(&RELEASE_ID.to_string()), Ok(Some(id)));
        assert_eq!(
            requested_draft(&u64::MAX.to_string()),
            Ok(ReleaseId::new(u64::MAX))
        );
        for invalid in [
            "0",
            "-1",
            "1.5",
            " ",
            "1\n",
            "18446744073709551616",
            "../releases/1",
        ] {
            assert!(requested_draft(invalid).is_err(), "{invalid}");
        }
        let release = serde_json::json!({"id":RELEASE_ID,"tag_name":"v0.1.0","draft":true});
        assert_eq!(
            release_by_id_from(id, |path| {
                assert_eq!(
                    path,
                    format!("repos/P4suta/gleam-mutants/releases/{RELEASE_ID}")
                );
                Ok(release.clone())
            })
            .unwrap(),
            release
        );
        for invalid in [
            serde_json::json!({"id":1}),
            serde_json::json!({"id":0}),
            serde_json::json!({"id":"42"}),
        ] {
            assert!(release_by_id_from(id, |_| Ok(invalid)).is_err());
        }
        assert_eq!(
            release_by_id_from(id, |_| Err("read failed".into())),
            Err("read failed".into())
        );
    }

    #[test]
    fn publication_confirmation_requires_the_same_immutable_published_identity() {
        const RELEASE_ID: u64 = 42;
        let id = ReleaseId::new(RELEASE_ID).unwrap();
        let tag = "v0.1.0";
        let published = serde_json::json!({"id":RELEASE_ID,"tag_name":tag,"draft":false,"immutable":true,"published_at":"2026-10-30T00:00:00Z"});
        assert!(require_published(&published, id, tag).is_ok());
        for (field, value) in [
            ("id", serde_json::json!(1)),
            ("id", serde_json::json!(0)),
            ("tag_name", serde_json::json!("v0.2.0")),
            ("draft", serde_json::json!(true)),
            ("draft", serde_json::json!("false")),
            ("immutable", serde_json::json!(false)),
            ("immutable", Value::Null),
            ("published_at", Value::Null),
            ("published_at", serde_json::json!("")),
        ] {
            let mut invalid = published.clone();
            invalid[field] = value;
            assert!(require_published(&invalid, id, tag).is_err(), "{field}");
        }
    }

    #[test]
    fn upload_confirmation_requires_the_expected_complete_asset() {
        const ASSET_ID: u64 = 42;
        let expected = asset("package.tgz");
        let uploaded = serde_json::json!({"id":ASSET_ID,"name":expected.path,"size":expected.bytes,"state":"uploaded"});
        assert!(require_uploaded(&uploaded, &expected).is_ok());
        for (field, value) in [
            ("id", serde_json::json!(0)),
            ("id", serde_json::json!("42")),
            ("name", serde_json::json!("another.tgz")),
            ("size", serde_json::json!(0)),
            ("state", serde_json::json!("starter")),
        ] {
            let mut invalid = uploaded.clone();
            invalid[field] = value;
            assert!(require_uploaded(&invalid, &expected).is_err(), "{field}");
        }
    }

    fn controller_fixture() -> (ControllerRun, Value, Value) {
        let controller = ControllerRun {
            source: Revision::try_from("a".repeat(40)).unwrap(),
            run: 1,
            attempt: 2,
        };
        let metadata = serde_json::json!({
            "id":controller.run,"run_attempt":controller.attempt,"head_sha":controller.source.as_str(),
            "head_branch":"main","path":WORKFLOW,"event":"workflow_dispatch",
            "repository":{"id":candidate::REPOSITORY_ID,"owner":{"id":candidate::OWNER_ID}},
            "head_repository":{"id":candidate::REPOSITORY_ID},"status":"in_progress","conclusion":null
        });
        let job = serde_json::json!({
            "name":DRAFT_JOB,"run_attempt":1,"run_id":controller.run,"head_sha":controller.source.as_str(),
            "status":"completed","conclusion":"success"
        });
        (controller, metadata, job)
    }

    #[test]
    fn draft_handoff_uses_only_the_bound_controller_and_actions_job_reads() {
        let (controller, metadata, job) = controller_fixture();
        let proof = prepared_draft_from(
            &controller,
            |path| {
                assert_eq!(path, "repos/P4suta/gleam-mutants/actions/runs/1");
                Ok(metadata)
            },
            |path| {
                assert_eq!(
                    path,
                    "repos/P4suta/gleam-mutants/actions/runs/1/jobs?filter=all"
                );
                Ok(vec![job])
            },
        )
        .unwrap();
        assert_eq!(proof.producer_attempt, 1);
        for phase in [Phase::Hex, Phase::Npm] {
            let evidence = with_draft_evidence(
                phase,
                || Err("draft lookup is unavailable to a read-only token"),
                || Ok(proof.producer_attempt),
            );
            assert_eq!(evidence, Ok(1));
        }
    }

    #[test]
    fn draft_handoff_rejects_every_foreign_controller_binding() {
        let (controller, metadata, _) = controller_fixture();
        for (pointer, invalid) in [
            ("/id", serde_json::json!(2)),
            ("/run_attempt", serde_json::json!(1)),
            ("/head_sha", serde_json::json!("b".repeat(40))),
            ("/head_branch", serde_json::json!("feature")),
            ("/path", serde_json::json!(candidate::CANDIDATE_WORKFLOW)),
            ("/event", serde_json::json!("pull_request")),
            ("/repository/id", serde_json::json!(0)),
            ("/repository/owner/id", serde_json::json!(0)),
            ("/head_repository/id", serde_json::json!(0)),
            ("/status", serde_json::json!("completed")),
            ("/conclusion", serde_json::json!("success")),
        ] {
            let mut foreign = metadata.clone();
            *foreign.pointer_mut(pointer).unwrap() = invalid;
            assert!(
                prepared_draft_from(
                    &controller,
                    |_| Ok(foreign),
                    |_| { panic!("jobs must not be read for an invalid controller") }
                )
                .is_err(),
                "{pointer}"
            );
        }
        let mut missing = metadata.clone();
        missing.as_object_mut().unwrap().remove("conclusion");
        assert!(controller.validate(&missing).is_err());
        assert!(
            prepared_draft_from(
                &controller,
                |_| Err("fixture transport failure".into()),
                |_| { panic!("jobs must not be read after a transport failure") }
            )
            .is_err()
        );
    }

    #[test]
    fn missing_ambiguous_failed_or_newer_failed_draft_producers_supply_no_handoff() {
        let (controller, metadata, job) = controller_fixture();
        let mut failed = job.clone();
        failed["run_attempt"] = serde_json::json!(2);
        for conclusion in ["failure", "skipped", "cancelled", "timed_out"] {
            failed["conclusion"] = serde_json::json!(conclusion);
            assert!(
                prepared_draft_from(
                    &controller,
                    |_| Ok(metadata.clone()),
                    |_| Ok(vec![job.clone(), failed.clone()])
                )
                .is_err()
            );
        }
        for jobs in [vec![], vec![job.clone(), job.clone()]] {
            assert!(
                prepared_draft_from(&controller, |_| Ok(metadata.clone()), |_| Ok(jobs)).is_err()
            );
        }
        for (field, invalid) in [
            ("run_id", serde_json::json!(2)),
            ("head_sha", serde_json::json!("b".repeat(40))),
            ("run_attempt", serde_json::json!(0)),
            ("run_attempt", serde_json::json!("1")),
            ("status", serde_json::json!("in_progress")),
            ("conclusion", Value::Null),
            ("name", serde_json::json!("another job")),
        ] {
            let mut foreign = job.clone();
            foreign[field] = invalid;
            assert!(
                prepared_draft_from(&controller, |_| Ok(metadata.clone()), |_| Ok(vec![foreign]))
                    .is_err(),
                "{field}"
            );
        }
        assert!(
            prepared_draft_from(
                &controller,
                |_| Ok(metadata),
                |_| Err("fixture transport failure".into())
            )
            .is_err()
        );
    }

    #[test]
    fn a_draft_is_discovered_when_the_published_tag_endpoint_is_missing() {
        let tag = "v0.1.0";
        let draft = serde_json::json!({"id":1,"tag_name":tag,"draft":true,"immutable":false,"published_at":null});
        let observed = release_from(tag, |path| {
            if path == format!("repos/{}/releases", candidate::REPOSITORY) {
                Ok(vec![draft.clone()])
            } else if path == format!("repos/{}/releases/tags/{tag}", candidate::REPOSITORY) {
                Ok(Vec::new())
            } else {
                Err("unexpected GitHub release route".into())
            }
        })
        .unwrap();
        assert_eq!(observed, Some(draft));
    }

    #[test]
    fn release_discovery_preserves_exact_targets_after_unrelated_records() {
        let tag = "v0.1.0";
        let unrelated = serde_json::json!({"id":1,"tag_name":"v0.2.0","draft":true});
        for is_draft in [false, true] {
            let target = serde_json::json!({
                "id":u64::MAX,"tag_name":tag,"draft":is_draft,"target_commitish":"main","immutable":false,"published_at":null
            });
            let records = vec![unrelated.clone(), target.clone()];
            let found = release_from(tag, |_| Ok(records)).unwrap().unwrap();
            assert_eq!(found, target);
            assert_eq!(require_draft(found, tag).is_ok(), is_draft);
        }
        assert_eq!(release_from(tag, |_| Ok(vec![unrelated])).unwrap(), None);
        assert_eq!(release_from(tag, |_| Ok(Vec::new())).unwrap(), None);
    }

    #[test]
    fn release_discovery_rejects_duplicates_malformed_identity_and_transport_errors() {
        const FRACTIONAL_RELEASE_ID: f64 = 1.5;
        let tag = "v0.1.0";
        let target = serde_json::json!({"id":1,"tag_name":tag,"draft":true});
        for other_id in [1, 2] {
            let duplicate = serde_json::json!({"id":other_id,"tag_name":tag,"draft":false});
            let error = release_from(tag, |_| Ok(vec![target.clone(), duplicate])).unwrap_err();
            assert_eq!(error, "release catalogue has duplicate matching tags");
        }
        for invalid in [
            serde_json::json!({}),
            serde_json::json!({"tag_name":null}),
            serde_json::json!({"tag_name":tag}),
            serde_json::json!({"tag_name":tag,"id":0}),
            serde_json::json!({"tag_name":tag,"id":-1}),
            serde_json::json!({"tag_name":tag,"id":"1"}),
            serde_json::json!({"tag_name":tag,"id":FRACTIONAL_RELEASE_ID}),
        ] {
            assert!(release_from(tag, |_| Ok(vec![invalid])).is_err());
        }
        let error = release_from(tag, |_| Err("fixture transport failure".into())).unwrap_err();
        assert_eq!(error, "fixture transport failure");
    }

    #[test]
    fn draft_admission_rejects_published_malformed_and_foreign_releases() {
        let tag = "v0.1.0";
        let valid = serde_json::json!({"id":1,"tag_name":tag,"draft":true,"immutable":false,"published_at":null});
        assert!(require_draft(valid.clone(), tag).is_ok());
        for (field, value) in [
            ("draft", serde_json::json!(false)),
            ("draft", serde_json::json!("true")),
            ("tag_name", serde_json::json!("v0.2.0")),
            ("immutable", serde_json::json!(true)),
            ("immutable", serde_json::json!("false")),
            ("immutable", Value::Null),
            ("published_at", serde_json::json!("2026-10-30T00:00:00Z")),
        ] {
            let mut invalid = valid.clone();
            invalid[field] = value;
            assert!(require_draft(invalid, tag).is_err(), "{field}");
        }
        for field in ["id", "tag_name", "draft", "immutable", "published_at"] {
            let mut missing = valid.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(require_draft(missing, tag).is_err(), "missing {field}");
        }
    }

    #[derive(Default)]
    struct Store {
        data: BTreeMap<String, Vec<u8>>,
        uploads: Vec<String>,
        fail: bool,
        fail_after: Option<usize>,
    }
    impl AssetStore for Store {
        fn inventory(&mut self) -> Result<Vec<String>, String> {
            Ok(self.data.keys().cloned().collect())
        }
        fn bytes(&mut self, name: &str) -> Result<Vec<u8>, String> {
            self.data.get(name).cloned().ok_or("missing fixture".into())
        }
        fn upload(&mut self, artifact: &Artifact) -> Result<(), String> {
            if self.fail || self.fail_after == Some(self.uploads.len()) {
                return Err("fixture transport failure".into());
            }
            self.uploads.push(artifact.path.clone());
            self.data
                .insert(artifact.path.clone(), b"verified".to_vec());
            Ok(())
        }
    }
    fn asset(name: &str) -> Artifact {
        Artifact {
            path: name.into(),
            bytes: 8,
            sha256: candidate::digest(b"verified"),
            sha512: String::new(),
            target: candidate::ArtifactTarget::Evidence,
        }
    }

    #[test]
    fn verifies_all_conflicts_before_upload_and_resumes_only_missing_bytes() {
        let expected = [asset("a"), asset("b")];
        let mut store = Store::default();
        store.data.insert("b".into(), b"conflict".to_vec());
        assert!(reconcile(&mut store, &expected, true).is_err());
        assert!(store.uploads.is_empty());
        store.data.insert("b".into(), b"verified".to_vec());
        assert!(reconcile(&mut store, &expected, false).is_err());
        assert!(reconcile(&mut store, &expected, true).is_ok());
        assert_eq!(store.uploads, ["a"]);
        assert!(reconcile(&mut store, &expected, false).is_ok());
        assert!(reconcile(&mut store, &expected, true).is_ok());
        assert_eq!(store.uploads, ["a"]);
    }
    #[test]
    fn unexpected_assets_and_transport_errors_supply_no_completion() {
        let mut store = Store::default();
        store.data.insert("unexpected".into(), b"verified".to_vec());
        assert!(reconcile(&mut store, &[asset("a")], true).is_err());
        let mut store = Store {
            fail: true,
            ..Store::default()
        };
        assert!(reconcile(&mut store, &[asset("a")], true).is_err());
        assert!(store.uploads.is_empty());
    }
    #[test]
    fn a_partial_upload_retries_only_the_remaining_verified_bytes() {
        let mut store = Store {
            fail_after: Some(1),
            ..Store::default()
        };
        let expected = [asset("a"), asset("b")];
        assert!(reconcile(&mut store, &expected, true).is_err());
        assert_eq!(store.uploads, ["a"]);
        store.fail_after = None;
        reconcile(&mut store, &expected, true).unwrap();
        assert_eq!(store.uploads, ["a", "b"]);
        reconcile(&mut store, &expected, false).unwrap();
    }
    #[test]
    fn publishing_clients_reject_old_malformed_and_prerelease_versions() {
        assert!(minimum_client("v22.14.0\n", "22.14.0").is_ok());
        assert!(minimum_client("11.5.1\n", "11.5.1").is_ok());
        for invalid in ["22.13.9", "22.14.0-beta.1", "unexpected", "22.14.0\nother"] {
            assert!(minimum_client(invalid, "22.14.0").is_err());
        }
    }
    #[test]
    fn publication_approval_is_bound_to_the_exact_controller_phase_and_environment() {
        let context = ExecutionContext {
            actions: "true".into(),
            repository: candidate::REPOSITORY.into(),
            workflow: format!("{}/{WORKFLOW}@refs/heads/main", candidate::REPOSITORY),
            reference: "refs/heads/main".into(),
            protected: "true".into(),
            job: "hex".into(),
            environment: "release-hex".into(),
        };
        assert!(approved_context(Phase::Hex, &context).is_ok());
        assert!(
            approved_context(
                Phase::Hex,
                &ExecutionContext {
                    actions: "false".into(),
                    ..context.clone()
                }
            )
            .is_err()
        );
        assert!(
            approved_context(
                Phase::Hex,
                &ExecutionContext {
                    reference: "refs/heads/feature".into(),
                    ..context.clone()
                }
            )
            .is_err()
        );
        assert!(
            approved_context(
                Phase::Hex,
                &ExecutionContext {
                    job: "npm".into(),
                    environment: "release-npm".into(),
                    ..context
                }
            )
            .is_err()
        );
    }
}
