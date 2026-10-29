// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::collections::BTreeMap;

const MAXIMUM_EXACT_JAVASCRIPT_INTEGER: i64 = 9_007_199_254_740_991;

enum Expression {
    Compare(String, i64),
    And(Box<Self>, Box<Self>),
    Or(Box<Self>, Box<Self>),
}

impl Expression {
    fn lean(&self) -> String {
        match self {
            Self::Compare(operator, value) => format!("(value {operator} {value})"),
            Self::And(left, right) => format!("({} ∧ {})", left.lean(), right.lean()),
            Self::Or(left, right) => format!("({} ∨ {})", left.lean(), right.lean()),
        }
    }
}

struct Parser {
    tokens: Vec<String>,
    cursor: usize,
    constants: BTreeMap<String, i64>,
}

fn tokens(source: &str) -> Result<Vec<String>, String> {
    let source = source
        .lines()
        .map(|line| line.split_once("//").map_or(line, |pair| pair.0))
        .collect::<Vec<_>>()
        .join("\n");
    let mut result = Vec::new();
    let mut chars = source.chars().peekable();
    while let Some(character) = chars.next() {
        if character.is_whitespace() {
            continue;
        }
        let mut token = character.to_string();
        if character.is_ascii_alphanumeric() || character == '_' {
            while chars
                .peek()
                .is_some_and(|next| next.is_ascii_alphanumeric() || *next == '_')
            {
                token.push(chars.next().expect("peeked character"));
            }
        } else if let Some(next) = chars.peek()
            && matches!(
                (character, *next),
                ('>', '=') | ('<', '=') | ('=', '=') | ('&', '&') | ('|', '|') | ('-', '>')
            )
        {
            token.push(chars.next().expect("peeked character"));
        }
        if !token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && ![
                "(", ")", ":", "{", "}", "=", ">=", "<=", "==", "&&", "||", "->",
            ]
            .contains(&token.as_str())
        {
            return Err(format!("unsupported token {token:?}"));
        }
        result.push(token);
    }
    Ok(result)
}

impl Parser {
    fn take(&mut self) -> Result<String, String> {
        let token = self
            .tokens
            .get(self.cursor)
            .cloned()
            .ok_or("unexpected end of source")?;
        self.cursor += 1;
        Ok(token)
    }

    fn expect(&mut self, expected: &str) -> Result<(), String> {
        let actual = self.take()?;
        if actual != expected {
            return Err(format!("expected {expected:?}, got {actual:?}"));
        }
        Ok(())
    }

    fn matches(&mut self, expected: &str) -> bool {
        if self
            .tokens
            .get(self.cursor)
            .is_some_and(|token| token == expected)
        {
            self.cursor += 1;
            true
        } else {
            false
        }
    }

    fn comparison(&mut self) -> Result<Expression, String> {
        self.expect("value")?;
        let operator = match self.take()?.as_str() {
            ">=" => ">=",
            "<=" => "<=",
            "==" => "=",
            other => return Err(format!("unsupported comparison {other}")),
        };
        let constant = self.take()?;
        let value = *self
            .constants
            .get(&constant)
            .ok_or_else(|| format!("unknown constant {constant}"))?;
        Ok(Expression::Compare(operator.to_owned(), value))
    }

    fn and(&mut self) -> Result<Expression, String> {
        let mut left = self.comparison()?;
        while self.matches("&&") {
            left = Expression::And(Box::new(left), Box::new(self.comparison()?));
        }
        Ok(left)
    }

    fn expression(&mut self) -> Result<Expression, String> {
        let mut left = self.and()?;
        while self.matches("||") {
            left = Expression::Or(Box::new(left), Box::new(self.and()?));
        }
        Ok(left)
    }
}

pub fn derive(source: &str) -> Result<String, String> {
    let mut parser = Parser {
        tokens: tokens(source)?,
        cursor: 0,
        constants: BTreeMap::new(),
    };
    let mut functions = BTreeMap::new();
    while parser.cursor < parser.tokens.len() {
        parser.expect("pub")?;
        match parser.take()?.as_str() {
            "const" => {
                let name = parser.take()?;
                parser.expect("=")?;
                let literal = parser.take()?;
                let value: i64 = literal
                    .replace('_', "")
                    .parse()
                    .map_err(|_| "unsupported integer literal")?;
                if value > MAXIMUM_EXACT_JAVASCRIPT_INTEGER
                    || parser.constants.insert(name, value).is_some()
                {
                    return Err("duplicate or nonrepresentable constant".into());
                }
            }
            "fn" => {
                let name = parser.take()?;
                for token in ["(", "value", ":", "Int", ")", "->", "Bool", "{"] {
                    parser.expect(token)?;
                }
                let expression = parser.expression()?;
                parser.expect("}")?;
                if functions.insert(name, expression).is_some() {
                    return Err("duplicate function".into());
                }
            }
            other => return Err(format!("unsupported declaration {other}")),
        }
    }
    let constants: Vec<_> = parser.constants.keys().map(String::as_str).collect();
    if constants
        != [
            "interrupt_exit_code",
            "maximum_jobs",
            "maximum_timeout_ms",
            "minimum_jobs",
            "minimum_timeout_ms",
            "terminate_exit_code",
        ]
    {
        return Err("source constant inventory changed".into());
    }
    let names: Vec<_> = functions.keys().map(String::as_str).collect();
    if names != ["interrupted", "valid_jobs", "valid_timeout"] {
        return Err("source predicate inventory changed".into());
    }
    let mut model = "namespace Derived\n".to_owned();
    for (name, expression) in functions {
        model.push_str(&format!(
            "def {name} (value : Int) : Bool := decide {}\n",
            expression.lean()
        ));
    }
    model.push_str("end Derived\n");
    Ok(model)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = include_str!("../../src/gleam_mutants/core/limits.gleam");

    #[test]
    fn derives_all_production_predicates() {
        let model = derive(SOURCE).expect("supported production source");
        for name in ["valid_jobs", "valid_timeout", "interrupted"] {
            assert!(model.contains(&format!("def {name} ")));
        }
        assert!(model.contains("86400000"));
    }

    #[test]
    fn changed_bound_reaches_the_model() {
        let original = derive(SOURCE).expect("original source");
        let changed = derive(&SOURCE.replace("maximum_jobs = 32", "maximum_jobs = 33"))
            .expect("mutated source");
        assert_ne!(original, changed);
        assert!(changed.contains("value <= 33"));
    }

    #[test]
    fn refuses_unsupported_or_missing_source() {
        for source in [
            String::new(),
            format!("{SOURCE}\nimport other"),
            SOURCE.replace("value >= minimum_jobs", "other(value)"),
            SOURCE.replace("value >= minimum_jobs", "value + 1 >= minimum_jobs"),
            SOURCE.replace("maximum_jobs = 32", "maximum_jobs = 32.0"),
            SOURCE.replace("pub fn interrupted", "pub fn unknown"),
            SOURCE.replace("maximum_jobs = 32", "minimum_jobs = 32"),
        ] {
            assert!(
                derive(&source).is_err(),
                "accepted unsupported source: {source}"
            );
        }
    }

    #[test]
    fn whitespace_comments_and_boolean_precedence_are_semantic() {
        assert_eq!(derive(SOURCE), derive(&SOURCE.replace('\n', "\r\n")));
        let changed = SOURCE.replace(
            "value >= minimum_jobs && value <= maximum_jobs",
            "value == minimum_jobs || value >= minimum_jobs && value <= maximum_jobs",
        );
        let model = derive(&changed).expect("supported boolean expression");
        assert!(model.contains("((value = 1) ∨ ((value >= 1) ∧ (value <= 32)))"));
    }
}
