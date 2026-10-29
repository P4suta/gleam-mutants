// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::candidate::{self, Artifact, Revision, Version};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

pub const GATES: [&str; 14] = [
    "check",
    "test-integration",
    "test-matrix",
    "test-minimum",
    "test-property",
    "test-faults",
    "benchmark",
    "dogfood",
    "test-ecosystem",
    "package",
    "prove",
    "prove-release",
    "scan-sboms",
    "audit-tools",
];
pub const PLATFORMS: [&str; 3] = ["linux", "macos", "windows"];
pub const RUNTIMES: [&str; 4] = ["erlang", "node", "deno", "bun"];
pub const MANIFEST: &str = "candidate.json";
pub const GATE_RECEIPT: &str = "gates.json";

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum Origin {
    Local,
    GitHub {
        repository: String,
        repository_id: u64,
        owner_id: u64,
        workflow: String,
        run: u64,
        attempt: u32,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Identity {
    pub source: Revision,
    pub version: Version,
    pub origin: Origin,
}

impl Identity {
    pub fn same_source_through(&self, expected: &Self) -> bool {
        if self.source != expected.source || self.version != expected.version {
            return false;
        }
        match (&self.origin, &expected.origin) {
            (Origin::Local, Origin::Local) => true,
            (
                Origin::GitHub {
                    repository: a,
                    repository_id: ai,
                    owner_id: ao,
                    workflow: aw,
                    run: ar,
                    attempt: own_attempt,
                },
                Origin::GitHub {
                    repository: b,
                    repository_id: bi,
                    owner_id: bo,
                    workflow: bw,
                    run: br,
                    attempt: expected_attempt,
                },
            ) => {
                a == b
                    && ai == bi
                    && ao == bo
                    && aw == bw
                    && ar == br
                    && *own_attempt > 0
                    && own_attempt <= expected_attempt
            }
            (Origin::Local, Origin::GitHub { .. }) | (Origin::GitHub { .. }, Origin::Local) => {
                false
            }
        }
    }
    pub fn hosted(&self) -> Result<(), String> {
        match &self.origin {
            Origin::Local => Err("local evidence has no hosted build identity".into()),
            Origin::GitHub {
                repository,
                repository_id,
                owner_id,
                workflow,
                run,
                attempt,
            } if repository == candidate::REPOSITORY
                && *repository_id == candidate::REPOSITORY_ID
                && *owner_id == candidate::OWNER_ID
                && workflow == candidate::CANDIDATE_WORKFLOW
                && *run != 0
                && *attempt != 0 =>
            {
                Ok(())
            }
            Origin::GitHub { .. } => Err("candidate builder identity is invalid".into()),
        }
    }

    pub fn artifact_name(&self) -> Result<String, String> {
        self.hosted()?;
        let Origin::GitHub { run, attempt, .. } = &self.origin else {
            return Err("hosted candidate identity required".into());
        };
        Ok(format!(
            "candidate-{}-{run}-{attempt}",
            self.source.as_str()
        ))
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Verdict {
    Passed,
    Failed,
    Inconclusive,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ResultRecord {
    pub check: String,
    pub verdict: Verdict,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Receipt {
    pub format: u32,
    pub identity: Identity,
    pub platform: String,
    pub results: Vec<ResultRecord>,
}

impl Receipt {
    pub fn validate(
        &self,
        identity: &Identity,
        platform: &str,
        checks: &[String],
    ) -> Result<(), String> {
        if self.format != candidate::FORMAT
            || !self.identity.same_source_through(identity)
            || self.platform != platform
            || self.results.len() != checks.len()
        {
            return Err("verification receipt identity or inventory mismatch".into());
        }
        for (result, check) in self.results.iter().zip(checks) {
            if result.check != *check || result.verdict != Verdict::Passed {
                return Err(format!("verification is incomplete: {check}"));
            }
        }
        Ok(())
    }
}

pub fn runtime_checks() -> Vec<String> {
    let mut checks = vec!["test-integration".into(), "test-matrix".into()];
    checks.extend(
        RUNTIMES
            .into_iter()
            .flat_map(|host| RUNTIMES.map(|target| format!("{host}/{target}")))
            .collect::<Vec<_>>(),
    );
    checks
}

pub fn receipt(directory: &Path, name: &str) -> Result<Receipt, String> {
    serde_json::from_slice(&candidate::read(directory, name)?).map_err(|e| format!("{name}: {e}"))
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Candidate {
    pub format: u32,
    pub identity: Identity,
    pub artifacts: Vec<Artifact>,
    pub evidence: Vec<Artifact>,
}

fn checked_evidence(directory: &Path, identity: &Identity) -> Result<Vec<Artifact>, String> {
    let gates = GATES.map(str::to_owned);
    receipt(directory, GATE_RECEIPT)?.validate(identity, "linux", &gates)?;
    let mut names = vec![GATE_RECEIPT.to_owned()];
    for platform in PLATFORMS {
        let name = format!("runtime-{platform}.json");
        receipt(directory, &name)?.validate(identity, platform, &runtime_checks())?;
        names.push(name);
    }
    names.sort();
    names
        .iter()
        .map(|name| candidate::artifact(directory, name))
        .collect()
}

impl Candidate {
    pub fn assemble(directory: &Path, identity: Identity) -> Result<Self, String> {
        identity.hosted()?;
        Ok(Self {
            format: candidate::FORMAT,
            artifacts: candidate::release_distribution(directory, &identity.version)?,
            evidence: checked_evidence(directory, &identity)?,
            identity,
        })
    }

    pub fn verify(&self, directory: &Path, expected: &Identity) -> Result<(), String> {
        if self.format != candidate::FORMAT || !self.identity.same_source_through(expected) {
            return Err("candidate source, version, or build identity mismatch".into());
        }
        let rebuilt = Self::assemble(directory, self.identity.clone())?;
        if self != &rebuilt {
            return Err("candidate bytes or evidence changed".into());
        }
        if candidate::read(directory, "CANDIDATE-SHA256SUMS")?
            != self.checksums(directory)?.as_bytes()
        {
            return Err("candidate checksum inventory changed".into());
        }
        let mut allowed: Vec<String> = self
            .artifacts
            .iter()
            .chain(&self.evidence)
            .map(|a| a.path.clone())
            .collect();
        allowed.extend(
            [
                MANIFEST,
                "SHA256SUMS",
                "CANDIDATE-SHA256SUMS",
                "github-attestation.sigstore.json",
                "npm-provenance.sigstore.json",
                "RELEASE-SHA256SUMS",
            ]
            .map(str::to_owned),
        );
        for entry in fs::read_dir(directory).map_err(|e| e.to_string())? {
            let entry = entry.map_err(|e| e.to_string())?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| "non-UTF-8 candidate entry")?;
            if !allowed.contains(&name) {
                return Err(format!("unexpected candidate entry: {name}"));
            }
            candidate::read(directory, &name)?;
        }
        Ok(())
    }

    pub fn load(directory: &Path) -> Result<Self, String> {
        serde_json::from_slice(&candidate::read(directory, MANIFEST)?)
            .map_err(|e| format!("candidate manifest: {e}"))
    }

    pub fn seal(directory: &Path, identity: Identity) -> Result<Self, String> {
        let value = Self::assemble(directory, identity)?;
        write_new(&directory.join(MANIFEST), &value)?;
        write_bytes_new(
            &directory.join("CANDIDATE-SHA256SUMS"),
            value.checksums(directory)?.as_bytes(),
        )?;
        Ok(value)
    }

    fn checksums(&self, directory: &Path) -> Result<String, String> {
        let mut sums = String::new();
        for item in self.artifacts.iter().chain(&self.evidence) {
            sums.push_str(&format!("{}  {}\n", item.sha256, item.path));
        }
        sums.push_str(&format!(
            "{}  {MANIFEST}\n",
            candidate::digest(&candidate::read(directory, MANIFEST)?)
        ));
        Ok(sums)
    }

    pub fn npm(&self) -> Result<&Artifact, String> {
        let name = format!("gleam-mutants-{}.tgz", self.identity.version.as_str());
        self.artifacts
            .iter()
            .find(|a| a.path == name)
            .ok_or("npm archive is missing".into())
    }
}

pub fn write_new<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let mut bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    write_bytes_new(path, &bytes)
}

pub fn write_bytes_new(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    file.write_all(bytes).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity() -> Identity {
        Identity {
            source: Revision::try_from("a".repeat(40)).unwrap(),
            version: Version::try_from("0.1.0".to_owned()).unwrap(),
            origin: Origin::GitHub {
                repository: candidate::REPOSITORY.into(),
                repository_id: candidate::REPOSITORY_ID,
                owner_id: candidate::OWNER_ID,
                workflow: candidate::CANDIDATE_WORKFLOW.into(),
                run: 1,
                attempt: 1,
            },
        }
    }

    #[test]
    fn incomplete_wrong_source_and_duplicate_results_supply_no_release_evidence() {
        let identity = identity();
        let checks = runtime_checks();
        let mut receipt = Receipt {
            format: candidate::FORMAT,
            identity: identity.clone(),
            platform: "linux".into(),
            results: checks
                .iter()
                .map(|check| ResultRecord {
                    check: check.clone(),
                    verdict: Verdict::Passed,
                })
                .collect(),
        };
        assert!(receipt.validate(&identity, "linux", &checks).is_ok());
        receipt.results.pop();
        assert!(receipt.validate(&identity, "linux", &checks).is_err());
        receipt.results.push(receipt.results[0].clone());
        assert!(receipt.validate(&identity, "linux", &checks).is_err());
        let mut other = identity.clone();
        other.source = Revision::try_from("b".repeat(40)).unwrap();
        assert!(receipt.validate(&other, "linux", &checks).is_err());
    }

    #[test]
    fn local_unknown_builder_and_unknown_fields_never_supply_hosted_identity() {
        let mut identity = identity();
        identity.origin = Origin::Local;
        assert!(identity.hosted().is_err());
        identity.origin = Origin::GitHub {
            repository: "elsewhere/project".into(),
            repository_id: candidate::REPOSITORY_ID,
            owner_id: candidate::OWNER_ID,
            workflow: candidate::CANDIDATE_WORKFLOW.into(),
            run: 1,
            attempt: 1,
        };
        assert!(identity.hosted().is_err());
        let mut json = serde_json::to_value(&identity).unwrap();
        json["trusted"] = serde_json::json!(true);
        assert!(serde_json::from_value::<Identity>(json).is_err());
    }
}
