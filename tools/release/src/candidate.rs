// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256, Sha512};
use std::collections::BTreeMap;
use std::fs;
use std::io::Read;
use std::path::{Component, Path};

pub const REPOSITORY: &str = "P4suta/gleam-mutants";
pub const REPOSITORY_ID: u64 = 1337180332;
pub const OWNER_ID: u64 = 42543015;
pub const CANDIDATE_WORKFLOW: &str = ".github/workflows/release-candidate.yml";
pub const FORMAT: u32 = 1;
const SHA_LENGTH: usize = 40;
const SHA256_LENGTH: usize = 64;
const UNSHARED_LINKS: u64 = 1;
pub(crate) const MAXIMUM_FILE_BYTES: u64 = 256 * 1024 * 1024;
const MTE: &str = "pkg:npm/mutation-testing-elements@3.9.0";
const DISTRIBUTIONS: [&str; 3] = ["hex", "escript", "npm"];

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(try_from = "String", into = "String")]
pub struct Revision(String);

impl TryFrom<String> for Revision {
    type Error = String;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        if value.len() == SHA_LENGTH
            && value
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
        {
            Ok(Self(value))
        } else {
            Err("source must be a full lowercase Git commit hash".into())
        }
    }
}

impl From<Revision> for String {
    fn from(value: Revision) -> Self {
        value.0
    }
}

impl Revision {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(try_from = "String", into = "String")]
pub struct Version(String);

impl TryFrom<String> for Version {
    type Error = String;
    fn try_from(value: String) -> Result<Self, Self::Error> {
        let parsed =
            semver::Version::parse(&value).map_err(|e| format!("invalid package version: {e}"))?;
        if !parsed.build.is_empty() || parsed.to_string() != value {
            return Err("package versions must be canonical and contain no build metadata".into());
        }
        Ok(Self(value))
    }
}

impl From<Version> for String {
    fn from(value: Version) -> Self {
        value.0
    }
}

impl Version {
    pub fn as_str(&self) -> &str {
        &self.0
    }
    pub fn tag(&self) -> String {
        format!("v{}", self.0)
    }
    pub fn npm_tag(&self) -> &'static str {
        if self.0.contains('-') {
            "next"
        } else {
            "latest"
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub sha512: String,
    pub target: ArtifactTarget,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum ArtifactTarget {
    GleamSource,
    ErlangPortable,
    JavaScriptPortable,
    DependencyInventory,
    Evidence,
}

pub fn digest(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

pub fn read(directory: &Path, name: &str) -> Result<Vec<u8>, String> {
    let relative = Path::new(name);
    if relative
        .components()
        .any(|component| !matches!(component, Component::Normal(_)))
        || name.contains('\\')
        || name.contains(':')
        || name.contains('\0')
    {
        return Err(format!("unsafe artifact path: {name}"));
    }
    let mut current = directory.to_path_buf();
    let directory_metadata =
        fs::symlink_metadata(&current).map_err(|e| format!("{}: {e}", current.display()))?;
    if !directory_metadata.is_dir() || directory_metadata.is_symlink() {
        return Err("artifact root must be an ordinary directory".into());
    }
    for component in relative.components() {
        current.push(component.as_os_str());
        let metadata =
            fs::symlink_metadata(&current).map_err(|e| format!("{}: {e}", current.display()))?;
        if metadata.is_symlink() || !(metadata.is_file() || metadata.is_dir()) {
            return Err(format!(
                "artifact path contains a link or special entry: {name}"
            ));
        }
    }
    let before = fs::symlink_metadata(&current).map_err(|e| e.to_string())?;
    if !before.is_file() || before.len() > MAXIMUM_FILE_BYTES {
        return Err(format!("artifact is not a bounded file: {name}"));
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if before.nlink() != UNSHARED_LINKS {
            return Err(format!("artifact has shared file links: {name}"));
        }
    }
    let mut bytes = Vec::new();
    fs::File::open(&current)
        .map_err(|e| e.to_string())?
        .take(MAXIMUM_FILE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| e.to_string())?;
    let after = fs::symlink_metadata(&current).map_err(|e| e.to_string())?;
    if bytes.len() as u64 > MAXIMUM_FILE_BYTES
        || before.len() != after.len()
        || before.modified().map_err(|e| e.to_string())?
            != after.modified().map_err(|e| e.to_string())?
        || after.is_symlink()
    {
        return Err(format!("artifact changed during verification: {name}"));
    }
    Ok(bytes)
}

pub fn artifact(directory: &Path, name: &str) -> Result<Artifact, String> {
    let bytes = read(directory, name)?;
    Ok(Artifact {
        path: name.into(),
        bytes: bytes.len() as u64,
        sha256: digest(&bytes),
        sha512: Sha512::digest(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect(),
        target: if name.ends_with(".tar") {
            ArtifactTarget::GleamSource
        } else if name.ends_with(".escript") {
            ArtifactTarget::ErlangPortable
        } else if name.ends_with(".tgz") {
            ArtifactTarget::JavaScriptPortable
        } else if name.ends_with(".cdx.json") {
            ArtifactTarget::DependencyInventory
        } else {
            ArtifactTarget::Evidence
        },
    })
}

pub fn inventory(version: &Version) -> Vec<String> {
    let v = version.as_str();
    let mut names = vec![
        format!("hex/gleam_mutants-{v}.tar"),
        "escript/gleam-mutants.escript".into(),
        format!("npm/gleam-mutants-{v}.tgz"),
    ];
    names.extend(DISTRIBUTIONS.map(|d| format!("gleam-mutants-{v}-{d}.cdx.json")));
    names.sort();
    names
}

pub fn inspect(directory: &Path, version: &str) -> Result<(), String> {
    let version = Version::try_from(version.to_owned())?;
    distribution(directory, &version).map(|_| ())
}

pub fn distribution(directory: &Path, version: &Version) -> Result<Vec<Artifact>, String> {
    let expected = inventory(version);
    checked_distribution(directory, version, expected)
}

pub fn release_inventory(version: &Version) -> Result<Vec<String>, String> {
    inventory(version)
        .iter()
        .map(|name| basename(name))
        .collect()
}

pub fn basename(name: &str) -> Result<String, String> {
    Path::new(name)
        .file_name()
        .and_then(|name| name.to_str())
        .map(str::to_owned)
        .ok_or_else(|| "artifact filename is invalid".into())
}

pub fn release_distribution(directory: &Path, version: &Version) -> Result<Vec<Artifact>, String> {
    checked_distribution(directory, version, release_inventory(version)?)
}

fn checked_distribution(
    directory: &Path,
    version: &Version,
    expected: Vec<String>,
) -> Result<Vec<Artifact>, String> {
    let rows = String::from_utf8(read(directory, "SHA256SUMS")?).map_err(|e| e.to_string())?;
    let mut expected = expected;
    expected.sort();
    let mut sums = BTreeMap::new();
    for row in rows.lines() {
        let (hash, name) = row.split_once("  ").ok_or("malformed checksum row")?;
        if hash.len() != SHA256_LENGTH
            || !hash
                .bytes()
                .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
            || !expected.iter().any(|path| path == name)
        {
            return Err(format!("unexpected checksum entry: {name}"));
        }
        if sums.insert(name.to_owned(), hash.to_owned()).is_some() {
            return Err("duplicate checksum path".into());
        }
    }
    if sums.keys().ne(expected.iter()) {
        return Err("distribution inventory is incomplete".into());
    }
    let mut artifacts = Vec::new();
    for name in &expected {
        let item = artifact(directory, name)?;
        if sums.get(name) != Some(&item.sha256) {
            return Err(format!("checksum mismatch: {name}"));
        }
        artifacts.push(item);
    }
    for distribution in DISTRIBUTIONS {
        let name = format!("gleam-mutants-{}-{distribution}.cdx.json", version.as_str());
        let sbom: serde_json::Value =
            serde_json::from_slice(&read(directory, &name)?).map_err(|e| e.to_string())?;
        let component = &sbom["metadata"]["component"];
        let reference = component["bom-ref"]
            .as_str()
            .ok_or("SBOM application reference is missing")?;
        if sbom["bomFormat"] != "CycloneDX"
            || component["name"] != "gleam-mutants"
            || component["version"] != version.as_str()
        {
            return Err(format!("SBOM product identity mismatch: {name}"));
        }
        let components = sbom["components"]
            .as_array()
            .ok_or("SBOM components are missing")?;
        let edges = sbom["dependencies"]
            .as_array()
            .ok_or("SBOM dependency edges are missing")?;
        if !components.iter().any(|c| {
            c["bom-ref"] == MTE
                && c["name"] == "mutation-testing-elements"
                && c["version"] == "3.9.0"
        }) || !edges.iter().any(|e| {
            e["ref"] == reference
                && e["dependsOn"]
                    .as_array()
                    .is_some_and(|targets| targets.iter().any(|t| t == MTE))
        }) {
            return Err(format!("SBOM lacks the embedded MTE dependency: {name}"));
        }
    }
    Ok(artifacts)
}

#[cfg(test)]
mod tests {
    use super::inspect;
    use sha2::{Digest, Sha256};
    use std::fs;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    const VERSION: &str = "0.1.0";
    static SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);

    impl Fixture {
        fn new() -> Self {
            let sequence = SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let root = std::env::temp_dir()
                .join(format!("gleam-release-{}-{sequence}", std::process::id()));
            fs::create_dir(&root).unwrap();
            for name in ["hex", "escript", "npm"] {
                fs::create_dir(root.join(name)).unwrap();
            }
            for name in [
                "hex/gleam_mutants-0.1.0.tar",
                "escript/gleam-mutants.escript",
                "npm/gleam-mutants-0.1.0.tgz",
            ] {
                fs::write(root.join(name), b"verified fixture archive").unwrap();
            }
            for distribution in ["hex", "escript", "npm"] {
                let component =
                    format!("pkg:generic/gleam-mutants@0.1.0?distribution={distribution}");
                let sbom = serde_json::json!({
                    "bomFormat": "CycloneDX",
                    "specVersion": "1.6",
                    "metadata": {"component": {"name": "gleam-mutants", "version": VERSION, "bom-ref": component}},
                    "components": [{"bom-ref": "pkg:npm/mutation-testing-elements@3.9.0", "name": "mutation-testing-elements", "version": "3.9.0"}],
                    "dependencies": [{"ref": component, "dependsOn": ["pkg:npm/mutation-testing-elements@3.9.0"]}]
                });
                fs::write(
                    root.join(format!("gleam-mutants-0.1.0-{distribution}.cdx.json")),
                    serde_json::to_vec(&sbom).unwrap(),
                )
                .unwrap();
            }
            let fixture = Self(root);
            fixture.checksums();
            fixture
        }

        fn checksums(&self) {
            let names = [
                "hex/gleam_mutants-0.1.0.tar",
                "escript/gleam-mutants.escript",
                "npm/gleam-mutants-0.1.0.tgz",
                "gleam-mutants-0.1.0-hex.cdx.json",
                "gleam-mutants-0.1.0-escript.cdx.json",
                "gleam-mutants-0.1.0-npm.cdx.json",
            ];
            let rows = names
                .map(|name| {
                    format!(
                        "{}  {name}\n",
                        Sha256::digest(fs::read(self.0.join(name)).unwrap())
                            .iter()
                            .map(|byte| format!("{byte:02x}"))
                            .collect::<String>()
                    )
                })
                .concat();
            fs::write(self.0.join("SHA256SUMS"), rows).unwrap();
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }

    #[test]
    fn accepts_the_complete_distribution_and_refuses_changed_bytes() {
        let fixture = Fixture::new();
        assert_eq!(inspect(&fixture.0, VERSION), Ok(()));
        fs::write(fixture.0.join("npm/gleam-mutants-0.1.0.tgz"), b"changed").unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
    }

    #[test]
    fn refuses_checksum_traversal_duplicates_and_missing_artifacts() {
        let fixture = Fixture::new();
        let file = fixture.0.join("SHA256SUMS");
        let rows = fs::read_to_string(&file).unwrap();
        fs::write(
            &file,
            rows.replace("npm/gleam-mutants-0.1.0.tgz", "../outside"),
        )
        .unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
        fs::write(&file, format!("{rows}{rows}")).unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
        fs::write(&file, &rows).unwrap();
        fs::remove_file(fixture.0.join("escript/gleam-mutants.escript")).unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
    }

    #[test]
    fn refuses_a_rehashed_sbom_for_another_version() {
        let fixture = Fixture::new();
        let path = fixture.0.join("gleam-mutants-0.1.0-npm.cdx.json");
        let data = fs::read_to_string(&path).unwrap().replace("0.1.0", "0.2.0");
        fs::write(path, data).unwrap();
        fixture.checksums();
        assert!(inspect(&fixture.0, VERSION).is_err());
    }

    #[test]
    fn sealed_candidates_require_their_complete_unchanged_evidence() {
        use crate::evidence::{self, Candidate, Receipt, ResultRecord, Verdict};
        let fixture = Fixture::new();
        let root = fixture.0.join("flat");
        fs::create_dir(&root).unwrap();
        let identity = crate::github::expected(
            super::Revision::try_from("a".repeat(40)).unwrap(),
            super::Version::try_from(VERSION.to_owned()).unwrap(),
            1,
            1,
        )
        .unwrap();
        let artifacts = super::distribution(&fixture.0, &identity.version).unwrap();
        let mut sums = String::new();
        for artifact in artifacts {
            let name = std::path::Path::new(&artifact.path)
                .file_name()
                .unwrap()
                .to_str()
                .unwrap();
            fs::copy(fixture.0.join(&artifact.path), root.join(name)).unwrap();
            sums.push_str(&format!("{}  {name}\n", artifact.sha256));
        }
        fs::write(root.join("SHA256SUMS"), sums).unwrap();
        let receipt = |platform: &str, checks: Vec<String>| Receipt {
            format: super::FORMAT,
            identity: identity.clone(),
            platform: platform.into(),
            results: checks
                .into_iter()
                .map(|check| ResultRecord {
                    check,
                    verdict: Verdict::Passed,
                })
                .collect(),
        };
        evidence::write_new(
            &root.join(evidence::GATE_RECEIPT),
            &receipt("linux", evidence::GATES.map(str::to_owned).to_vec()),
        )
        .unwrap();
        for platform in evidence::PLATFORMS {
            evidence::write_new(
                &root.join(format!("runtime-{platform}.json")),
                &receipt(platform, evidence::runtime_checks()),
            )
            .unwrap();
        }
        let candidate = Candidate::seal(&root, identity.clone()).unwrap();
        Candidate::load(&root)
            .unwrap()
            .verify(&root, &identity)
            .unwrap();
        assert!(Candidate::seal(&root, identity.clone()).is_err());
        let mut later = identity.clone();
        if let evidence::Origin::GitHub { attempt, .. } = &mut later.origin {
            *attempt += 1;
        }
        candidate.verify(&root, &later).unwrap();
        assert!(
            Candidate::assemble(&root, later)
                .unwrap()
                .verify(&root, &identity)
                .is_err()
        );
        let checksums = root.join("CANDIDATE-SHA256SUMS");
        let original = fs::read(&checksums).unwrap();
        fs::write(&checksums, b"changed").unwrap();
        assert!(candidate.verify(&root, &identity).is_err());
        fs::write(&checksums, original).unwrap();
        let unexpected = root.join("unexpected");
        fs::write(&unexpected, b"changed").unwrap();
        assert!(candidate.verify(&root, &identity).is_err());
        fs::remove_file(unexpected).unwrap();
        let missing = root.join("runtime-windows.json");
        let original = fs::read(&missing).unwrap();
        fs::remove_file(&missing).unwrap();
        assert!(candidate.verify(&root, &identity).is_err());
        let mut invalid: Receipt = serde_json::from_slice(&original).unwrap();
        invalid.results[0].verdict = Verdict::Inconclusive;
        evidence::write_new(&missing, &invalid).unwrap();
        assert!(candidate.verify(&root, &identity).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn refuses_links_even_when_their_bytes_match() {
        let fixture = Fixture::new();
        let file = fixture.0.join("escript/gleam-mutants.escript");
        let other = fixture.0.join("escript/original");
        fs::rename(&file, &other).unwrap();
        std::os::unix::fs::symlink(&other, &file).unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
        fs::remove_file(&file).unwrap();
        fs::hard_link(&other, &file).unwrap();
        assert!(inspect(&fixture.0, VERSION).is_err());
    }
}
