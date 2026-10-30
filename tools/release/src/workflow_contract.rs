// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use gleam_mutants_release_core::{DraftEvidenceSource, PublicationPhase};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
use yaml_rust2::{Yaml, YamlLoader};

const WORKFLOW: &str = include_str!("../../../.github/workflows/release-publish.yml");

fn value(yaml: &Yaml) -> Result<Value, String> {
    match yaml {
        Yaml::String(text) => Ok(Value::String(text.clone())),
        Yaml::Integer(number) => Ok(Value::Number((*number).into())),
        Yaml::Boolean(boolean) => Ok(Value::Bool(*boolean)),
        Yaml::Null => Ok(Value::Null),
        Yaml::Array(items) => items.iter().map(value).collect(),
        Yaml::Hash(entries) => entries
            .iter()
            .map(|(key, item)| {
                let key = key.as_str().ok_or("workflow key must be a string")?;
                Ok((key.to_owned(), value(item)?))
            })
            .collect::<Result<Map<_, _>, String>>()
            .map(Value::Object),
        Yaml::Real(_) | Yaml::Alias(_) | Yaml::BadValue => {
            Err("workflow contains an unsupported scalar or reference".into())
        }
    }
}

fn parse(source: &str) -> Result<Value, String> {
    let documents = YamlLoader::load_from_str(source).map_err(|error| error.to_string())?;
    let [document] = documents.as_slice() else {
        return Err("publication workflow must contain one document".into());
    };
    value(document)
}

fn validate(workflow: &Value) -> Result<(), String> {
    let jobs = workflow["jobs"]
        .as_object()
        .ok_or("publication jobs are missing")?;
    for (name, job) in jobs {
        if !job["if"].is_null()
            || (!job["continue-on-error"].is_null() && job["continue-on-error"] != false)
            || !job["strategy"].is_null()
        {
            return Err(format!(
                "publication job can skip or ignore its prerequisites: {name}"
            ));
        }
    }
    for phase in PublicationPhase::ALL {
        let job = jobs
            .get(phase.job())
            .ok_or("publication phase is missing")?;
        let required = match phase.draft_evidence() {
            DraftEvidenceSource::ReleaseApi => "write",
            DraftEvidenceSource::CompletedPreparation => "read",
        };
        if job["permissions"]["contents"] != required {
            return Err(format!(
                "{} requires Contents {required} for its draft evidence operation",
                phase.job()
            ));
        }
        if job["environment"] != phase.environment() {
            return Err(format!("{} has another protected environment", phase.job()));
        }
        let mut permissions = serde_json::json!({"contents":required,"actions":"read"});
        if phase == PublicationPhase::Npm {
            permissions["id-token"] = Value::String("write".into());
        }
        if job["permissions"] != permissions {
            return Err(format!(
                "{} grants capabilities outside its phase",
                phase.job()
            ));
        }
        let expected_command = format!(
            "./controller/release-publish execute {} build/candidate \"$SOURCE\" \"$VERSION\" \"$RUN\" \"$ATTEMPT\"",
            phase.job()
        );
        require_command(job, &expected_command)?;
    }
    let expected_jobs = BTreeSet::from([
        "preflight",
        "attest-controller",
        "draft",
        "registry-ready",
        "hex",
        "npm",
        "finalize",
    ]);
    if jobs.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected_jobs {
        return Err("publication job inventory omits a required phase or readiness gate".into());
    }
    if workflow["permissions"] != serde_json::json!({}) {
        return Err("publication grants workflow-wide permissions".into());
    }
    for (name, expected) in [
        ("SOURCE", "${{ inputs.source_sha }}"),
        ("VERSION", "${{ inputs.version }}"),
        ("RUN", "${{ inputs.candidate_run }}"),
        ("ATTEMPT", "${{ inputs.candidate_attempt }}"),
    ] {
        if workflow["env"][name] != expected {
            return Err(format!("publication candidate binding changed: {name}"));
        }
    }
    if jobs["draft"]["name"] != crate::publication::DRAFT_JOB {
        return Err("draft job differs from its verified producer identity".into());
    }
    for (name, dependencies) in [
        ("attest-controller", vec!["preflight"]),
        ("draft", vec!["preflight", "attest-controller"]),
        ("registry-ready", vec!["draft", "attest-controller"]),
        ("hex", vec!["registry-ready", "attest-controller"]),
        ("npm", vec!["registry-ready", "attest-controller"]),
        ("finalize", vec!["draft", "hex", "npm", "attest-controller"]),
    ] {
        if needs(&jobs[name])? != dependencies.into_iter().collect() {
            return Err(format!("publication prerequisite changed: {name}"));
        }
    }
    let readiness = &jobs[crate::publication::READINESS_JOB];
    if readiness["permissions"] != serde_json::json!({"contents":"read","actions":"read"})
        || !readiness["environment"].is_null()
    {
        return Err(
            "registry readiness must remain read-only and require no protected approval".into(),
        );
    }
    for phase in [PublicationPhase::Hex, PublicationPhase::Npm] {
        require_command(
            readiness,
            &format!(
                "./controller/release-publish check-registry {} build/candidate \"$SOURCE\" \"$VERSION\" \"$RUN\" \"$ATTEMPT\"",
                phase.job()
            ),
        )?;
    }
    for name in ["preflight", "attest-controller", "registry-ready"] {
        let text = serde_json::to_string(&jobs[name]).map_err(|error| error.to_string())?;
        let normalized: String = text
            .chars()
            .filter(|c| !c.is_ascii_whitespace())
            .flat_map(char::to_lowercase)
            .collect();
        if normalized.contains("secrets.") || normalized.contains("secrets[") {
            return Err(format!(
                "readiness or evidence job references registry secrets: {name}"
            ));
        }
    }
    Ok(())
}

fn needs(job: &Value) -> Result<BTreeSet<&str>, String> {
    match &job["needs"] {
        Value::String(name) => Ok(BTreeSet::from([name.as_str()])),
        Value::Array(names) => {
            let values = names
                .iter()
                .map(|name| name.as_str().ok_or("invalid prerequisite identity".into()))
                .collect::<Result<BTreeSet<_>, String>>()?;
            if values.len() != names.len() {
                return Err("duplicate publication prerequisites".into());
            }
            Ok(values)
        }
        _ => Err("publication prerequisites are missing".into()),
    }
}

fn require_command(job: &Value, expected: &str) -> Result<(), String> {
    let steps = job["steps"]
        .as_array()
        .ok_or("publication steps are missing")?;
    let matching: Vec<_> = steps
        .iter()
        .filter(|step| {
            step["run"]
                .as_str()
                .is_some_and(|command| command.split_whitespace().eq(expected.split_whitespace()))
        })
        .collect();
    let [step] = matching.as_slice() else {
        return Err(format!(
            "publication must execute exactly one bound command: {expected}"
        ));
    };
    if !step["if"].is_null()
        || (!step["continue-on-error"].is_null() && step["continue-on-error"] != false)
        || (!step["shell"].is_null() && step["shell"] != "bash")
    {
        return Err("publication prerequisite can be skipped or its failure ignored".into());
    }
    Ok(())
}

#[test]
fn the_actual_workflow_can_execute_every_phase_with_its_declared_permissions() {
    validate(&parse(WORKFLOW).unwrap()).unwrap();
}

#[test]
fn authority_readiness_and_candidate_binding_drift_are_rejected() {
    let workflow = parse(WORKFLOW).unwrap();
    for (pointer, replacement) in [
        ("/jobs/hex/permissions/contents", serde_json::json!("write")),
        ("/jobs/npm/permissions/contents", serde_json::json!("write")),
        (
            "/jobs/draft/permissions/contents",
            serde_json::json!("read"),
        ),
        (
            "/jobs/finalize/permissions/contents",
            serde_json::json!("read"),
        ),
        (
            "/jobs/hex/needs",
            serde_json::json!(["draft", "attest-controller"]),
        ),
        (
            "/jobs/npm/needs",
            serde_json::json!(["draft", "attest-controller"]),
        ),
        (
            "/jobs/registry-ready/permissions/contents",
            serde_json::json!("write"),
        ),
        ("/jobs/registry-ready/steps", serde_json::json!([])),
        ("/env/SOURCE", serde_json::json!("${{ github.sha }}")),
        ("/jobs/draft/name", serde_json::json!("another producer")),
    ] {
        let mut broken = workflow.clone();
        *broken.pointer_mut(pointer).unwrap() = replacement;
        assert!(validate(&broken).is_err(), "{pointer}");
    }
    for name in ["preflight", "attest-controller", "registry-ready"] {
        let mut broken = workflow.clone();
        broken["jobs"][name]["env"] = serde_json::json!({"EXAMPLE":"${{ secrets.HEXPM_API_KEY }}"});
        assert!(validate(&broken).is_err(), "{name}");
        broken = workflow.clone();
        broken["jobs"][name]["continue-on-error"] = serde_json::json!(true);
        assert!(validate(&broken).is_err());
    }
    for name in ["hex", "npm", "registry-ready"] {
        let mut broken = workflow.clone();
        broken["jobs"][name]["if"] = serde_json::json!("${{ always() }}");
        assert!(validate(&broken).is_err());
    }
    let mut missing = workflow.clone();
    missing["jobs"]
        .as_object_mut()
        .unwrap()
        .remove("registry-ready");
    assert!(validate(&missing).is_err());
    for phase in PublicationPhase::ALL {
        let mut broken = workflow.clone();
        broken["jobs"][phase.job()]["continue-on-error"] = serde_json::json!(true);
        assert!(validate(&broken).is_err());
    }
    for (field, invalid) in [
        ("if", serde_json::json!("${{ false }}")),
        ("continue-on-error", serde_json::json!(true)),
        ("shell", serde_json::json!("bash +e {0}")),
    ] {
        let mut broken = workflow.clone();
        let steps = broken["jobs"]["draft"]["steps"].as_array_mut().unwrap();
        let step = steps
            .iter_mut()
            .find(|step| {
                step["run"]
                    .as_str()
                    .is_some_and(|run| run.contains("execute draft"))
            })
            .unwrap();
        step[field] = invalid;
        assert!(validate(&broken).is_err(), "{field}");
    }
}

#[test]
fn malformed_workflow_and_ambiguous_prerequisites_supply_no_contract() {
    for source in [
        "",
        "---\n{}\n---\n{}",
        "{1: value}",
        "{broken",
        "{value: 1.5}",
    ] {
        assert!(parse(source).is_err());
    }
    assert!(needs(&serde_json::json!({"needs":["draft","draft"]})).is_err());
    assert!(needs(&serde_json::json!({"needs":[null]})).is_err());
}
