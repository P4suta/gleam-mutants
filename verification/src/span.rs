// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::collections::{BTreeMap, BTreeSet};

const MAXIMUM_SOURCE_BYTES: usize = 1024 * 1024;
const MAXIMUM_TOKENS: usize = 8192;
const MAXIMUM_DEPTH: usize = 64;
const MAXIMUM_CASE_CONDITIONS: usize = 8;
const MAXIMUM_EXACT_INTEGER: i64 = 9_007_199_254_740_991;
const LOWEST_PRECEDENCE: u8 = 0;
const BOOLEAN_OR_PRECEDENCE: u8 = 1;
const BOOLEAN_AND_PRECEDENCE: u8 = 2;
const COMPARISON_PRECEDENCE: u8 = 3;
const ADDITIVE_PRECEDENCE: u8 = 4;
const PREFIX_PRECEDENCE: u8 = 5;
const HEADER: &str = "import gleam/order.{type Order, Eq, Gt, Lt}
pub opaque type Span { Span(start: Int, end: Int) }
pub type SpanError { NegativeStart EndBeforeStart }";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Sort {
    Integer,
    Boolean,
    Span,
    Error,
    Order,
    ResultSpan,
}

impl Sort {
    fn lean(self) -> &'static str {
        match self {
            Self::Integer => "Int",
            Self::Boolean => "Bool",
            Self::Span => "Span",
            Self::Error => "SpanError",
            Self::Order => "Ordering",
            Self::ResultSpan => "Except SpanError Span",
        }
    }
}

struct Specification {
    name: &'static str,
    signature: &'static str,
    variables: &'static [(&'static str, Sort)],
    result: Sort,
}

static FUNCTIONS: &[Specification] = &[
    Specification {
        name: "new",
        signature: "(start: Int, end: Int) -> Result(Span, SpanError)",
        variables: &[("start", Sort::Integer), ("end", Sort::Integer)],
        result: Sort::ResultSpan,
    },
    Specification {
        name: "unsafe_new",
        signature: "(start: Int, end: Int) -> Span",
        variables: &[("start", Sort::Integer), ("end", Sort::Integer)],
        result: Sort::Span,
    },
    Specification {
        name: "start",
        signature: "(span: Span) -> Int",
        variables: &[("span", Sort::Span)],
        result: Sort::Integer,
    },
    Specification {
        name: "end",
        signature: "(span: Span) -> Int",
        variables: &[("span", Sort::Span)],
        result: Sort::Integer,
    },
    Specification {
        name: "length",
        signature: "(span: Span) -> Int",
        variables: &[("span", Sort::Span)],
        result: Sort::Integer,
    },
    Specification {
        name: "equal",
        signature: "(a: Span, b: Span) -> Bool",
        variables: &[("a", Sort::Span), ("b", Sort::Span)],
        result: Sort::Boolean,
    },
    Specification {
        name: "contains",
        signature: "(outer: Span, inner: Span) -> Bool",
        variables: &[("outer", Sort::Span), ("inner", Sort::Span)],
        result: Sort::Boolean,
    },
    Specification {
        name: "strictly_contains",
        signature: "(outer: Span, inner: Span) -> Bool",
        variables: &[("outer", Sort::Span), ("inner", Sort::Span)],
        result: Sort::Boolean,
    },
    Specification {
        name: "overlaps",
        signature: "(a: Span, b: Span) -> Bool",
        variables: &[("a", Sort::Span), ("b", Sort::Span)],
        result: Sort::Boolean,
    },
    Specification {
        name: "partially_overlaps",
        signature: "(a: Span, b: Span) -> Bool",
        variables: &[("a", Sort::Span), ("b", Sort::Span)],
        result: Sort::Boolean,
    },
    Specification {
        name: "compare",
        signature: "(a: Span, b: Span) -> Order",
        variables: &[("a", Sort::Span), ("b", Sort::Span)],
        result: Sort::Order,
    },
];

fn identifier(name: &str) -> String {
    if name == "end" {
        "«end»".into()
    } else {
        name.into()
    }
}

fn tokens(source: &str) -> Result<Vec<String>, String> {
    if source.len() > MAXIMUM_SOURCE_BYTES {
        return Err("span module exceeds its source bound".into());
    }
    let source = source
        .lines()
        .map(|line| line.split_once("//").map_or(line, |pair| pair.0))
        .collect::<Vec<_>>()
        .join("\n");
    let mut chars = source.chars().peekable();
    let mut tokens = Vec::new();
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
            )
        }) {
            token.push(chars.next().ok_or("missing operator character")?);
        }
        if !token.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            && ![
                "/", ".", "{", "}", "(", ")", ",", ":", "=", "->", "!", "+", "-", "<", ">", "<=",
                ">=", "==", "!=", "&&", "||",
            ]
            .contains(&token.as_str())
        {
            return Err(format!("unsupported span token {token:?}"));
        }
        tokens.push(token);
        if tokens.len() > MAXIMUM_TOKENS {
            return Err("span module exceeds its token bound".into());
        }
    }
    Ok(tokens)
}

struct Term {
    code: String,
    sort: Sort,
    depth: usize,
    calls: BTreeSet<&'static str>,
}

impl Term {
    fn new(
        code: String,
        sort: Sort,
        children: &[&Self],
        call: Option<&'static str>,
    ) -> Result<Self, String> {
        let depth = children.iter().map(|child| child.depth).max().unwrap_or(0) + 1;
        if depth > MAXIMUM_DEPTH {
            return Err("span expression exceeds its depth bound".into());
        }
        let mut calls: BTreeSet<_> = children
            .iter()
            .flat_map(|child| child.calls.iter().copied())
            .collect();
        calls.extend(call);
        Ok(Self {
            code,
            sort,
            depth,
            calls,
        })
    }
}

struct Parser {
    tokens: Vec<String>,
    cursor: usize,
    variables: &'static [(&'static str, Sort)],
}

impl Parser {
    fn peek(&self) -> Option<&str> {
        self.tokens.get(self.cursor).map(String::as_str)
    }
    fn take(&mut self) -> Result<String, String> {
        let token = self
            .tokens
            .get(self.cursor)
            .cloned()
            .ok_or("unexpected end of span source")?;
        self.cursor += 1;
        Ok(token)
    }
    fn eat(&mut self, token: &str) -> bool {
        if self.peek() == Some(token) {
            self.cursor += 1;
            true
        } else {
            false
        }
    }
    fn expect(&mut self, token: &str) -> Result<(), String> {
        let found = self.take()?;
        if found == token {
            Ok(())
        } else {
            Err(format!("expected span token {token:?}, got {found:?}"))
        }
    }
    fn sequence(&mut self, source: &str) -> Result<(), String> {
        for token in tokens(source)? {
            self.expect(&token)?;
        }
        Ok(())
    }
    fn expression(&mut self, precedence: u8, depth: usize) -> Result<Term, String> {
        if depth > MAXIMUM_DEPTH {
            return Err("span syntax exceeds its depth bound".into());
        }
        let mut left = self.primary(depth)?;
        loop {
            let priority = match self.peek() {
                Some("||") => BOOLEAN_OR_PRECEDENCE,
                Some("&&") => BOOLEAN_AND_PRECEDENCE,
                Some("==" | "!=" | "<" | ">" | "<=" | ">=") => COMPARISON_PRECEDENCE,
                Some("+" | "-") => ADDITIVE_PRECEDENCE,
                _ => break,
            };
            if priority < precedence {
                break;
            }
            let operator = self.take()?;
            let right = self.expression(priority + 1, depth + 1)?;
            let (code, sort) = match operator.as_str() {
                "+" | "-" if left.sort == Sort::Integer && right.sort == Sort::Integer => (
                    format!("({} {operator} {})", left.code, right.code),
                    Sort::Integer,
                ),
                "&&" | "||" if left.sort == Sort::Boolean && right.sort == Sort::Boolean => (
                    format!("({} {operator} {})", left.code, right.code),
                    Sort::Boolean,
                ),
                "==" | "!=" if left.sort == right.sort => {
                    let relation = if operator == "==" { "=" } else { "≠" };
                    (
                        format!("(decide ({} {relation} {}))", left.code, right.code),
                        Sort::Boolean,
                    )
                }
                "<" | ">" | "<=" | ">="
                    if left.sort == Sort::Integer && right.sort == Sort::Integer =>
                {
                    (
                        format!("(decide ({} {operator} {}))", left.code, right.code),
                        Sort::Boolean,
                    )
                }
                _ => return Err("span operator has incompatible operand types".into()),
            };
            left = Term::new(code, sort, &[&left, &right], None)?;
        }
        Ok(left)
    }
    fn primary(&mut self, depth: usize) -> Result<Term, String> {
        if self.eat("!") {
            let value = self.expression(PREFIX_PRECEDENCE, depth + 1)?;
            if value.sort != Sort::Boolean {
                return Err("span negation requires a Boolean".into());
            }
            return Term::new(format!("(!{})", value.code), Sort::Boolean, &[&value], None);
        }
        if self.eat("-") {
            let value = self.expression(PREFIX_PRECEDENCE, depth + 1)?;
            if value.sort != Sort::Integer {
                return Err("span negation requires an integer".into());
            }
            return Term::new(format!("(-{})", value.code), Sort::Integer, &[&value], None);
        }
        let mut value = if self.eat("case") {
            self.case(depth + 1)?
        } else if self.eat("(") {
            let value = self.expression(LOWEST_PRECEDENCE, depth + 1)?;
            self.expect(")")?;
            value
        } else {
            let name = self.take()?;
            if self.eat("(") {
                let mut arguments = Vec::new();
                if !self.eat(")") {
                    loop {
                        arguments.push(self.expression(LOWEST_PRECEDENCE, depth + 1)?);
                        if self.eat(")") {
                            break;
                        }
                        self.expect(",")?;
                    }
                }
                self.call(&name, &arguments)?
            } else {
                let literal = match name.as_str() {
                    "True" => Some(("true", Sort::Boolean)),
                    "False" => Some(("false", Sort::Boolean)),
                    "NegativeStart" => Some(("SpanError.negativeStart", Sort::Error)),
                    "EndBeforeStart" => Some(("SpanError.endBeforeStart", Sort::Error)),
                    "Lt" => Some(("Ordering.lt", Sort::Order)),
                    "Eq" => Some(("Ordering.eq", Sort::Order)),
                    "Gt" => Some(("Ordering.gt", Sort::Order)),
                    _ => None,
                };
                if let Some((code, sort)) = literal {
                    Term::new(code.into(), sort, &[], None)?
                } else if let Some((_, sort)) = self
                    .variables
                    .iter()
                    .find(|(variable, _)| *variable == name)
                {
                    Term::new(identifier(&name), *sort, &[], None)?
                } else {
                    let number: i64 = name
                        .replace('_', "")
                        .parse()
                        .map_err(|_| format!("unknown span value {name:?}"))?;
                    if !(0..=MAXIMUM_EXACT_INTEGER).contains(&number) {
                        return Err(
                            "span literal is outside the shared integer representation".into()
                        );
                    }
                    Term::new(number.to_string(), Sort::Integer, &[], None)?
                }
            }
        };
        while self.eat(".") {
            let field = self.take()?;
            if value.sort != Sort::Span || !["start", "end"].contains(&field.as_str()) {
                return Err("unsupported span projection".into());
            }
            value = Term::new(
                format!("({}).{}", value.code, identifier(&field)),
                Sort::Integer,
                &[&value],
                None,
            )?;
        }
        Ok(value)
    }
    fn call(&self, name: &str, arguments: &[Term]) -> Result<Term, String> {
        let (function, expected, result, dependency): (
            &str,
            Vec<Sort>,
            Sort,
            Option<&'static str>,
        ) = match name {
            "Span" => (
                "Span.mk",
                vec![Sort::Integer, Sort::Integer],
                Sort::Span,
                None,
            ),
            "Ok" => ("Except.ok", vec![Sort::Span], Sort::ResultSpan, None),
            "Error" => ("Except.error", vec![Sort::Error], Sort::ResultSpan, None),
            "unsafe_new" => {
                return Err(
                    "partial span construction is unsupported inside another expression".into(),
                );
            }
            _ => {
                let specification = FUNCTIONS
                    .iter()
                    .find(|function| function.name == name)
                    .ok_or("unknown span function")?;
                (
                    specification.name,
                    specification
                        .variables
                        .iter()
                        .map(|(_, sort)| *sort)
                        .collect(),
                    specification.result,
                    Some(specification.name),
                )
            }
        };
        if arguments
            .iter()
            .map(|argument| argument.sort)
            .collect::<Vec<_>>()
            != expected
        {
            return Err("span call has incompatible argument types".into());
        }
        let code = format!(
            "({} {})",
            identifier(function),
            arguments
                .iter()
                .map(|argument| format!("({})", argument.code))
                .collect::<Vec<_>>()
                .join(" ")
        );
        Term::new(
            code,
            result,
            &arguments.iter().collect::<Vec<_>>(),
            dependency,
        )
    }
    fn case(&mut self, depth: usize) -> Result<Term, String> {
        let mut conditions = vec![self.expression(LOWEST_PRECEDENCE, depth + 1)?];
        while self.eat(",") {
            conditions.push(self.expression(LOWEST_PRECEDENCE, depth + 1)?);
        }
        if conditions.len() > MAXIMUM_CASE_CONDITIONS
            || conditions
                .iter()
                .any(|condition| condition.sort != Sort::Boolean)
        {
            return Err("span cases require bounded Boolean conditions".into());
        }
        self.expect("{")?;
        let mut arms: Vec<(Vec<Option<bool>>, Term)> = Vec::new();
        while !self.eat("}") {
            let mut patterns = Vec::new();
            loop {
                patterns.push(match self.take()?.as_str() {
                    "True" => Some(true),
                    "False" => Some(false),
                    "_" => None,
                    _ => return Err("unsupported span pattern".into()),
                });
                if !self.eat(",") {
                    break;
                }
            }
            if patterns.len() != conditions.len() {
                return Err("span case arity mismatch".into());
            }
            self.expect("->")?;
            arms.push((patterns, self.expression(LOWEST_PRECEDENCE, depth + 1)?));
        }
        let result = arms.first().ok_or("empty span case")?.1.sort;
        if arms.iter().any(|(_, arm)| arm.sort != result) {
            return Err("span case has incompatible result types".into());
        }
        for mask in 0..(1_usize << conditions.len()) {
            if !arms.iter().any(|(patterns, _)| {
                patterns.iter().enumerate().all(|(index, value)| {
                    value.is_none_or(|value| value == (mask & (1 << index) != 0))
                })
            }) {
                return Err("span case is not exhaustive".into());
            }
        }
        let tuple = |parts: Vec<String>| {
            if parts.len() == 1 {
                parts[0].clone()
            } else {
                format!("({})", parts.join(", "))
            }
        };
        let scrutinee = tuple(
            conditions
                .iter()
                .map(|condition| condition.code.clone())
                .collect(),
        );
        let clauses = arms
            .iter()
            .map(|(patterns, arm)| {
                let pattern = tuple(
                    patterns
                        .iter()
                        .map(|value| {
                            match value {
                                None => "_",
                                Some(true) => "true",
                                Some(false) => "false",
                            }
                            .into()
                        })
                        .collect(),
                );
                format!("\n    | {pattern} => {}", arm.code)
            })
            .collect::<String>();
        let children: Vec<_> = conditions
            .iter()
            .chain(arms.iter().map(|(_, arm)| arm))
            .collect();
        Term::new(
            format!("(match {scrutinee} with{clauses})"),
            result,
            &children,
            None,
        )
    }
}

struct Definition {
    specification: &'static Specification,
    body: Term,
    assertion: bool,
}

fn definitions(source: &str) -> Result<BTreeMap<&'static str, Definition>, String> {
    let mut parser = Parser {
        tokens: tokens(source)?,
        cursor: 0,
        variables: &[],
    };
    parser.sequence(HEADER)?;
    let mut definitions = BTreeMap::new();
    while parser.peek().is_some() {
        parser.sequence("pub fn")?;
        let name = parser.take()?;
        let specification = FUNCTIONS
            .iter()
            .find(|function| function.name == name)
            .ok_or("span function inventory changed")?;
        parser.sequence(specification.signature)?;
        parser.expect("{")?;
        parser.variables = specification.variables;
        let assertion = specification.name == "unsafe_new";
        if assertion {
            parser.sequence("let assert Ok(span) =")?;
        }
        let body = parser.expression(LOWEST_PRECEDENCE, 0)?;
        if assertion {
            parser.expect("span")?;
        }
        let expected = if assertion {
            Sort::ResultSpan
        } else {
            specification.result
        };
        if body.sort != expected {
            return Err("span body differs from its declared return type".into());
        }
        parser.expect("}")?;
        if definitions
            .insert(
                specification.name,
                Definition {
                    specification,
                    body,
                    assertion,
                },
            )
            .is_some()
        {
            return Err("duplicate span function".into());
        }
    }
    if definitions.len() != FUNCTIONS.len() {
        return Err("span function inventory is incomplete".into());
    }
    Ok(definitions)
}

fn emit(
    name: &'static str,
    definitions: &BTreeMap<&'static str, Definition>,
    visiting: &mut BTreeSet<&'static str>,
    emitted: &mut BTreeSet<&'static str>,
    output: &mut String,
) -> Result<(), String> {
    if emitted.contains(name) {
        return Ok(());
    }
    if !visiting.insert(name) {
        return Err("recursive span functions are outside the admitted fragment".into());
    }
    let definition = definitions.get(name).ok_or("missing span dependency")?;
    for dependency in &definition.body.calls {
        emit(dependency, definitions, visiting, emitted, output)?;
    }
    visiting.remove(name);
    emitted.insert(name);
    let parameters = definition
        .specification
        .variables
        .iter()
        .map(|(name, sort)| format!("({} : {})", identifier(name), sort.lean()))
        .collect::<Vec<_>>()
        .join(" ");
    let (result, body) = if definition.assertion {
        (
            "Evaluation Span",
            format!(
                "(match {} with\n    | Except.ok span => Evaluation.returned span\n    | Except.error _ => Evaluation.assertionFailed)",
                definition.body.code
            ),
        )
    } else {
        (
            definition.specification.result.lean(),
            definition.body.code.clone(),
        )
    };
    output.push_str(&format!(
        "def {} {parameters} : {result} :=\n  {body}\n",
        identifier(name)
    ));
    Ok(())
}

pub fn derive(source: &str) -> Result<String, String> {
    let definitions = definitions(source)?;
    let mut output = "namespace SpanDerived\nstructure Span where\n  start : Int\n  «end» : Int\n  deriving DecidableEq\ninductive SpanError where\n  | negativeStart\n  | endBeforeStart\n  deriving DecidableEq\ninductive Ordering where\n  | lt\n  | eq\n  | gt\n  deriving DecidableEq\ninductive Evaluation (α : Type) where\n  | returned (value : α)\n  | assertionFailed\n  deriving DecidableEq\n".to_owned();
    let mut emitted = BTreeSet::new();
    for name in definitions.keys() {
        emit(
            name,
            &definitions,
            &mut BTreeSet::new(),
            &mut emitted,
            &mut output,
        )?;
    }
    output.push_str("end SpanDerived\n");
    Ok(output)
}

pub fn canonical_source(source: &str) -> Result<String, String> {
    derive(source)?;
    Ok(tokens(source)?.join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &str = include_str!("../../src/gleam_mutants/core/span.gleam");

    #[test]
    fn derives_the_complete_production_span_module() {
        let model = derive(SOURCE).expect("supported production span module");
        for name in [
            "new",
            "unsafe_new",
            "start",
            "end",
            "length",
            "equal",
            "contains",
            "strictly_contains",
            "overlaps",
            "partially_overlaps",
            "compare",
        ] {
            assert!(
                model.contains(&format!("def {} ", identifier(name))),
                "{name}"
            );
        }
    }

    #[test]
    fn changed_conditions_and_branch_order_reach_the_span_model() {
        let original = derive(SOURCE).unwrap();
        for changed in [
            SOURCE.replace("start < 0", "start <= 0"),
            SOURCE.replace("end < start", "end <= start"),
            SOURCE.replace("span.end - span.start", "span.start - span.end"),
            SOURCE.replace("a.start < b.end", "a.start <= b.end"),
            SOURCE.replace("True, _, _, _ -> Lt", "True, _, _, _ -> Gt"),
        ] {
            assert_ne!(derive(&changed).unwrap(), original);
        }
    }

    #[test]
    fn source_round_trip_and_declared_bounds_preserve_the_model() {
        let source = canonical_source(SOURCE).unwrap();
        assert_eq!(derive(SOURCE), derive(&source));
        assert_eq!(derive(SOURCE), derive(&SOURCE.replace('\n', "\r\n")));
        for source in [
            String::new(),
            format!("{SOURCE}\nimport other"),
            SOURCE.replace("pub fn new", "pub fn other"),
            SOURCE.replace("span.end - span.start", "span.end / span.start"),
            SOURCE.replace("span.end - span.start", "unknown(span)"),
            SOURCE.replace("span.end - span.start", "span.unknown"),
            SOURCE.replace("span.end - span.start", "length(span)"),
            SOURCE.replace(
                "span.end - span.start",
                &format!(
                    "{}0{}",
                    "(".repeat(MAXIMUM_DEPTH + 1),
                    ")".repeat(MAXIMUM_DEPTH + 1)
                ),
            ),
            SOURCE.replace("a.start == b.start", "a.start && b.start"),
        ] {
            assert!(derive(&source).is_err());
        }
    }
}
