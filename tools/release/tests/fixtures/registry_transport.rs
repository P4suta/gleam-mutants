// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

use std::io::Read;

fn main() {
    let args: Vec<_> = std::env::args().skip(1).collect();
    assert!(args.windows(2).any(|pair| pair == ["--request", "GET"]));
    assert!(
        !args
            .iter()
            .any(|arg| arg == "POST" || arg.contains("fixture-key"))
    );
    let mut headers = String::new();
    std::io::stdin().read_to_string(&mut headers).unwrap();
    let authorization = if args.last().unwrap() == "https://hex.pm/api/users/me" {
        "Authorization: fixture-key"
    } else {
        assert_eq!(args.last().unwrap(), "https://registry.npmjs.org/-/whoami");
        "Authorization: Bearer fixture-key"
    };
    assert!(headers.lines().any(|line| line == authorization));
    print!("{{\"username\":\"release-fixture\"}}\n200");
}
