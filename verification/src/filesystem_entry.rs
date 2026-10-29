// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

pub fn derive(source: &str) -> Result<String, String> {
    let normalized = source
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let body = normalized
        .strip_prefix("import gleam/string pub fn valid(value: String) -> Bool { ")
        .and_then(|body| body.strip_suffix(" }"))
        .ok_or("unsupported filesystem entry module shape")?;
    let clauses = body
        .split(" && ")
        .map(|clause| match clause {
            "value != \"\"" => Ok("value ≠ []"),
            "value != \".\"" => Ok("value ≠ [46]"),
            "value != \"..\"" => Ok("value ≠ [46, 46]"),
            "!string.contains(value, \"/\")" => Ok("value.contains 47 = false"),
            "!string.contains(value, \"\\\\\")" => Ok("value.contains 92 = false"),
            "!string.contains(value, \"\\u{0000}\")" => Ok("value.contains 0 = false"),
            _ => Err(format!("unsupported filesystem entry clause {clause:?}")),
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(format!(
        "namespace Derived\ndef valid (value : List Nat) : Bool := decide ({})\nend Derived\n",
        clauses.join(" ∧ ")
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = include_str!("../../src/gleam_mutants/core/filesystem_entry.gleam");

    #[test]
    fn derives_the_production_string_boundary() {
        let model = derive(SOURCE).expect("supported production source");
        assert!(model.contains("value ≠ [46, 46]"));
        assert!(model.contains("value.contains 92 = false"));
        assert!(model.contains("value.contains 0 = false"));
        assert_eq!(derive(SOURCE), derive(&SOURCE.replace('\n', "\r\n")));
    }

    #[test]
    fn changed_parent_admission_reaches_the_model() {
        let changed = SOURCE.replace("value != \"..\"", "value != \".\"");
        assert_ne!(derive(SOURCE), derive(&changed));
    }

    #[test]
    fn refuses_everything_outside_the_closed_fragment() {
        for source in [
            String::new(),
            format!("{SOURCE}\nimport other"),
            SOURCE.replace("pub fn valid", "pub fn other"),
            SOURCE.replace("&&", "||"),
            SOURCE.replace("value != \"..\"", "other(value)"),
            SOURCE.replace("value != \"..\"", "value != \"...\""),
            SOURCE.replace("!string.contains", "string.contains"),
            SOURCE.replace("value != \"..\"", "value != \"..\" // ignored"),
        ] {
            assert!(derive(&source).is_err(), "accepted unsupported source");
        }
    }
}
