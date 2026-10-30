// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Artifact, Revision};
use crate::evidence::{self, Candidate, Identity};
use crate::{constants, github, registry, runner};
use gleam_mutants_release_core::{
    Existing, ReleaseId, ReleaseSelection, WritePlan, can_finalize, plan_write,
};
use serde_json::Value;
use std::collections::BTreeMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const WORKFLOW: &str = ".github/workflows/release-publish.yml";
const TAG_CHAIN_BOUND: usize = 8;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Draft,
    Hex,
    Npm,
    Finalize,
}

impl Phase {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "draft" => Ok(Self::Draft),
            "hex" => Ok(Self::Hex),
            "npm" => Ok(Self::Npm),
            "finalize" => Ok(Self::Finalize),
            _ => Err("unknown publication phase".into()),
        }
    }
    pub fn job(self) -> &'static str {
        match self {
            Self::Draft => "draft",
            Self::Hex => "hex",
            Self::Npm => "npm",
            Self::Finalize => "finalize",
        }
    }
    pub fn environment(self) -> &'static str {
        match self {
            Self::Draft => "release-github",
            Self::Hex => "release-hex",
            Self::Npm => "release-npm",
            Self::Finalize => "release",
        }
    }
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
    let source = Revision::try_from(runner::environment("GITHUB_SHA")?)?;
    let run: u64 = runner::environment("GITHUB_RUN_ID")?
        .parse()
        .map_err(|_| "invalid controller run")?;
    let attempt: u32 = runner::environment("GITHUB_RUN_ATTEMPT")?
        .parse()
        .map_err(|_| "invalid controller attempt")?;
    if run == 0 || attempt == 0 {
        return Err("controller identity is empty".into());
    }
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
        let mut store = store(directory, identity, &release)?;
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
    let plan = serde_json::json!({"source":identity.source,"version":identity.version,"build":identity.origin,
        "assets":expected,"phases":["draft","hex","npm","finalize"],"publication_performed":false});
    evidence::write_new(Path::new("release-plan.json"), &plan)?;
    println!(
        "{}",
        serde_json::to_string_pretty(&plan).map_err(|e| e.to_string())?
    );
    Ok(())
}

fn mutate(args: &[&str], body: Option<&Value>) -> Result<(), String> {
    let mut command = Command::new("gh");
    command.args(args);
    if body.is_none() {
        runner::output(&mut command)?;
        return Ok(());
    }
    command
        .args(["--input", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command
        .spawn()
        .map_err(|e| format!("start GitHub mutation: {e}"))?;
    let input =
        serde_json::to_vec(body.ok_or("missing mutation body")?).map_err(|e| e.to_string())?;
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
    Ok(())
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
    if release["draft"] != true || release["tag_name"] != tag {
        return Err("target is published or has another release identity".into());
    }
    Ok(release)
}

fn draft(identity: &Identity) -> Result<Value, String> {
    if tag(identity)? != Existing::Matching {
        return Err("release tag does not identify the verified source".into());
    }
    let release = release(identity)?.ok_or("release draft is missing")?;
    require_draft(release, &identity.version.tag())
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
    identity: &'a Identity,
    release_id: u64,
    inventory: BTreeMap<String, (u64, u64)>,
}

impl AssetStore for GitHubAssets<'_> {
    fn inventory(&mut self) -> Result<Vec<String>, String> {
        let assets = github::list(
            &format!(
                "repos/{}/releases/{}/assets",
                candidate::REPOSITORY,
                self.release_id
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
        runner::output(
            Command::new("gh")
                .args([
                    "release",
                    "upload",
                    &self.identity.version.tag(),
                    "--repo",
                    candidate::REPOSITORY,
                ])
                .arg(self.directory.join(&artifact.path)),
        )?;
        Ok(())
    }
}

fn store<'a>(
    directory: &'a Path,
    identity: &'a Identity,
    release: &Value,
) -> Result<GitHubAssets<'a>, String> {
    let release_id = release["id"]
        .as_u64()
        .filter(|id| *id != 0)
        .ok_or("release has no valid ID")?;
    Ok(GitHubAssets {
        directory,
        identity,
        release_id,
        inventory: BTreeMap::new(),
    })
}

fn registry_artifact<'a>(candidate: &'a Candidate, prefix: &str) -> Result<&'a Artifact, String> {
    candidate
        .artifacts
        .iter()
        .find(|a| a.path.starts_with(prefix) && !a.path.ends_with(".json"))
        .ok_or("registry archive is missing".into())
}

pub fn execute(phase: Phase, directory: &Path, identity: &Identity) -> Result<(), String> {
    approval(phase)?;
    github::repository()?;
    github::verify_source(identity)?;
    let candidate = Candidate::load(directory)?;
    candidate.verify(directory, identity)?;
    github::attestations(directory, identity)?;
    let expected = assets(directory, &candidate)?;
    match phase {
        Phase::Draft => create_draft(directory, identity, &expected),
        Phase::Hex => {
            let release = draft(identity)?;
            reconcile(&mut store(directory, identity, &release)?, &expected, false)?;
            let artifact = registry_artifact(&candidate, "gleam_mutants-")?;
            match plan_write(
                true,
                registry::observe(registry::Registry::Hex, &identity.version, &artifact.sha256)?,
            ) {
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
            let release = draft(identity)?;
            reconcile(&mut store(directory, identity, &release)?, &expected, false)?;
            let artifact = candidate.npm()?;
            match plan_write(
                true,
                registry::observe(registry::Registry::Npm, &identity.version, &artifact.sha256)?,
            ) {
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
            let release = draft(identity)?;
            reconcile(&mut store(directory, identity, &release)?, &expected, false)?;
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
            mutate(
                &[
                    "release",
                    "edit",
                    &identity.version.tag(),
                    "--repo",
                    candidate::REPOSITORY,
                    "--draft=false",
                ],
                None,
            )?;
            let observed = self::release(identity)?.ok_or("published release disappeared")?;
            if observed["draft"] != false || tag(identity)? != Existing::Matching {
                return Err("final publication did not confirm its target".into());
            }
            reconcile(
                &mut store(directory, identity, &observed)?,
                &expected,
                false,
            )?;
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
    if let Some(existing) = release(identity)? {
        require_draft(existing, &identity.version.tag())?;
    }
    version_proposal(identity)?;
    match plan_write(true, tag(identity)?) {
        WritePlan::Reuse => {}
        WritePlan::Refuse => return Err("existing release tag identifies another source".into()),
        WritePlan::Create => mutate(
            &[
                "api",
                "--method",
                "POST",
                &format!("repos/{}/git/refs", candidate::REPOSITORY),
            ],
            Some(
                &serde_json::json!({"ref":format!("refs/tags/{}", identity.version.tag()),"sha":identity.source.as_str()}),
            ),
        )?,
    }
    if tag(identity)? != Existing::Matching {
        return Err("release tag creation did not confirm the source".into());
    }
    if release(identity)?.is_none() {
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
        let path = PathBuf::from(format!("release-notes-{}.md", identity.source.as_str()));
        evidence::write_bytes_new(&path, &notes.stdout)?;
        runner::output(
            Command::new("gh")
                .args([
                    "release",
                    "create",
                    &identity.version.tag(),
                    "--repo",
                    candidate::REPOSITORY,
                    "--draft",
                    "--verify-tag",
                    "--title",
                    &identity.version.tag(),
                    "--notes-file",
                ])
                .arg(&path),
        )?;
    }
    let release = draft(identity)?;
    let mut store = store(directory, identity, &release)?;
    reconcile(&mut store, expected, true)?;
    reconcile(&mut store, expected, false)
}

fn publish_npm(directory: &Path, candidate: &Candidate) -> Result<(), String> {
    for (tool, minimum) in [("node", "22.14.0"), ("npm", "11.5.1")] {
        let observed = runner::output(Command::new(tool).arg("--version"))?;
        minimum_client(&String::from_utf8_lossy(&observed.stdout), minimum)?;
    }
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
mod tests {
    use super::*;

    #[test]
    fn a_draft_is_discovered_when_the_published_tag_endpoint_is_missing() {
        let tag = "v0.1.0";
        let draft = serde_json::json!({"id":1,"tag_name":tag,"draft":true});
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
                "id":u64::MAX,"tag_name":tag,"draft":is_draft,"target_commitish":"main"
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
        for invalid in [
            serde_json::json!({"tag_name":tag,"draft":false}),
            serde_json::json!({"tag_name":tag}),
            serde_json::json!({"tag_name":tag,"draft":"true"}),
            serde_json::json!({"tag_name":"v0.2.0","draft":true}),
        ] {
            assert!(require_draft(invalid, tag).is_err());
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
