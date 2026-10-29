// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use crate::{
    candidate,
    registry::{self, Registry},
    runner,
};

const WORKFLOW: &str = ".github/workflows/release-credentials.yml";

pub fn verify(registry: Registry, username: &str) -> Result<(), String> {
    let (job, environment, variable) = match registry {
        Registry::Hex => ("hex", "release-hex", "HEXPM_API_KEY"),
        Registry::Npm => ("npm", "release-npm", "NPM_BOOTSTRAP_TOKEN"),
    };
    if runner::environment("GITHUB_ACTIONS")? != "true"
        || runner::environment("GITHUB_REPOSITORY")? != candidate::REPOSITORY
        || runner::environment("GITHUB_REPOSITORY_ID")? != candidate::REPOSITORY_ID.to_string()
        || runner::environment("GITHUB_REPOSITORY_OWNER_ID")? != candidate::OWNER_ID.to_string()
        || runner::environment("GITHUB_EVENT_NAME")? != "workflow_dispatch"
        || runner::environment("GITHUB_REF")? != "refs/heads/main"
        || runner::environment("GITHUB_REF_PROTECTED")? != "true"
        || runner::environment("GITHUB_WORKFLOW_REF")?
            != format!("{}/{WORKFLOW}@refs/heads/main", candidate::REPOSITORY)
        || runner::environment("GITHUB_JOB")? != job
        || runner::environment("RELEASE_ENVIRONMENT")? != environment
    {
        return Err("credential verification requires its dedicated protected-main workflow and environment".into());
    }
    registry::verify_identity(registry, username, &runner::environment(variable)?)
}
