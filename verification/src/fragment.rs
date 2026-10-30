// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::collections::BTreeMap;

const MAXIMUM_SOURCE_BYTES: usize = 1024 * 1024;
const MAXIMUM_TOKENS: usize = 32_768;

pub fn tokens(source: &str) -> Result<Vec<String>, String> {
    if source.len() > MAXIMUM_SOURCE_BYTES {
        return Err("source exceeds the closed-fragment byte bound".into());
    }
    let mut chars = source.chars().peekable();
    let mut result = Vec::new();
    while let Some(character) = chars.next() {
        if character.is_whitespace() {
            continue;
        }
        if character == '/' && chars.peek() == Some(&'/') {
            for next in chars.by_ref() {
                if next == '\n' {
                    break;
                }
            }
            continue;
        }
        let mut token = character.to_string();
        if character == '"' {
            let mut closed = false;
            while let Some(next) = chars.next() {
                token.push(next);
                if next == '\\' {
                    token.push(chars.next().ok_or("unterminated string escape")?);
                } else if next == '"' {
                    closed = true;
                    break;
                }
            }
            if !closed {
                return Err("unterminated string literal".into());
            }
        } else if character.is_ascii_alphanumeric() || character == '_' {
            while chars
                .peek()
                .is_some_and(|next| next.is_ascii_alphanumeric() || *next == '_')
            {
                token.push(chars.next().ok_or("missing identifier character")?);
            }
        } else if chars.peek().is_some_and(|next| {
            matches!(
                (character, *next),
                ('<', '=')
                    | ('>', '=')
                    | ('=', '=')
                    | ('!', '=')
                    | ('&', '&')
                    | ('|', '|')
                    | ('-', '>')
                    | ('|', '>')
                    | ('<', '>')
                    | ('.', '.')
                    | ('<', '.')
                    | ('>', '.')
                    | ('/', '.')
                    | ('*', '.')
            )
        }) {
            token.push(chars.next().ok_or("missing operator character")?);
        }
        result.push(token);
        if result.len() > MAXIMUM_TOKENS {
            return Err("source exceeds the closed-fragment token bound".into());
        }
    }
    Ok(result)
}

pub fn bind(source: &str, template: &str) -> Result<BTreeMap<String, String>, String> {
    let source = tokens(source)?;
    let template = tokens(template)?;
    if source.len() != template.len() {
        return Err("source differs from the admitted declaration inventory".into());
    }
    let mut values = BTreeMap::new();
    for (actual, expected) in source.into_iter().zip(template) {
        if expected.starts_with("__") {
            if let Some(previous) = values.insert(expected.clone(), actual.clone())
                && previous != actual
            {
                return Err(format!("inconsistent binding {expected}"));
            }
        } else if actual != expected {
            return Err(format!(
                "unsupported syntax: expected {expected:?}, got {actual:?}"
            ));
        }
    }
    Ok(values)
}

pub fn choice<'a>(
    values: &'a BTreeMap<String, String>,
    name: &str,
    choices: &[&str],
) -> Result<&'a str, String> {
    let value = values
        .get(name)
        .ok_or_else(|| format!("missing binding {name}"))?;
    if choices.contains(&value.as_str()) {
        Ok(value)
    } else {
        Err(format!("unsupported {name}: {value:?}"))
    }
}

pub fn boolean(values: &BTreeMap<String, String>, name: &str) -> Result<&'static str, String> {
    match choice(values, name, &["True", "False"])? {
        "True" => Ok("true"),
        "False" => Ok("false"),
        _ => unreachable!("choice checks the complete Boolean domain"),
    }
}

pub fn scalar_literal(values: &BTreeMap<String, String>, name: &str) -> Result<String, String> {
    let token = values
        .get(name)
        .ok_or_else(|| format!("missing binding {name}"))?;
    let literal = token
        .strip_prefix('"')
        .and_then(|text| text.strip_suffix('"'))
        .ok_or("expected a quoted scalar literal")?;
    if literal
        .chars()
        .any(|character| character == '\\' || character == '"' || character.is_control())
    {
        return Err("escaped or control-character literals are outside this fragment".into());
    }
    Ok(format!(
        "[{}]",
        literal
            .chars()
            .map(|character| u32::from(character).to_string())
            .collect::<Vec<_>>()
            .join(", ")
    ))
}

pub fn declaration(source: &str, name: &str) -> Result<String, String> {
    let header = ["pub", "type", name, "{"];
    let tokens = tokens(source)?;
    let starts: Vec<_> = tokens
        .windows(header.len())
        .enumerate()
        .filter(|(_, part)| part.iter().map(String::as_str).eq(header))
        .map(|(index, _)| index)
        .collect();
    let [start] = starts.as_slice() else {
        return Err(format!("missing or duplicated type {name}"));
    };
    let mut depth = 0_usize;
    for (offset, token) in tokens[*start..].iter().enumerate() {
        if token == "{" {
            depth += 1;
        }
        if token == "}" {
            depth = depth.checked_sub(1).ok_or("unbalanced type declaration")?;
            if depth == 0 {
                return Ok(tokens[*start..=*start + offset].join(" "));
            }
        }
    }
    Err(format!("unterminated type {name}"))
}

pub fn validate_types(source: &str) -> Result<(), String> {
    for (name, shape) in [
        (
            "Outcome",
            "pub type Outcome { Killed Survived TimedOut TestError(message: String) }",
        ),
        ("Runtime", "pub type Runtime { Erlang Node Deno Bun }"),
        (
            "RuntimeOutcome",
            "pub type RuntimeOutcome { RuntimeOutcome(runtime: Runtime, outcome: Outcome, duration_ms: Int, output: String, cached: Bool,) }",
        ),
        (
            "Score",
            "pub type Score { Score(total: Int, killed: Int, timed_out: Int, survived: Int, errors: Int, percent: Float,) }",
        ),
        (
            "Operator",
            "pub type Operator { BooleanLiteral BooleanNegation BooleanConnective Equality ComparisonBoundary IntegerArithmetic FloatArithmetic IntegerNeutral FloatNeutral StringNeutral ListNeutral OptionNeutral PipelineStageDeletion ConcatenationOperand IntegerNegation }",
        ),
    ] {
        bind(&declaration(source, name)?, shape)?;
    }
    Ok(())
}

pub fn natural(values: &BTreeMap<String, String>, name: &str) -> Result<String, String> {
    const MAXIMUM_EXACT_INTEGER: u64 = 9_007_199_254_740_991;
    let value = values
        .get(name)
        .ok_or_else(|| format!("missing binding {name}"))?;
    if !value.starts_with(|character: char| character.is_ascii_digit())
        || !value
            .chars()
            .all(|character| character.is_ascii_digit() || character == '_')
    {
        return Err(format!("invalid natural literal {value:?}"));
    }
    let number: u64 = value
        .replace('_', "")
        .parse()
        .map_err(|_| "natural literal overflow")?;
    if number > MAXIMUM_EXACT_INTEGER {
        return Err("natural literal exceeds the shared representation".into());
    }
    Ok(number.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binds_whole_declarations_without_changing_strings_or_comments() {
        let template = "fn a() { __value }";
        let source = "// ignored\nfn a() { \"not // a comment \\\"\" }";
        let bindings = bind(source, template).unwrap();
        assert_eq!(tokens(source), tokens(&tokens(source).unwrap().join(" ")));
        assert_eq!(bindings["__value"], "\"not // a comment \\\"\"");
        assert!(bind("fn a() { False } fn b() { True }", template).is_err());
        assert!(bind("fn a() {", template).is_err());
        assert!(bind("__a __a", "__x __x").is_ok());
        assert!(bind("True False", "__x __x").is_err());
        assert!(tokens("\"unterminated").is_err());
        assert!(tokens("\"escape\\").is_err());
    }

    #[test]
    fn refuses_changed_public_domains_and_extracts_exact_type_boundaries() {
        const TYPES: &str = include_str!("../../src/gleam_mutants/types.gleam");
        validate_types(TYPES).unwrap();
        assert!(validate_types(&TYPES.replace("  TimedOut\n", "  TimedOut\n  Unknown\n")).is_err());
        assert!(validate_types(&TYPES.replace("message: String", "message: Int")).is_err());
        assert!(declaration("pub type Outcome {", "Outcome").is_err());
        assert!(declaration("pub type Outcome {} pub type Outcome {}", "Outcome").is_err());
    }
}
