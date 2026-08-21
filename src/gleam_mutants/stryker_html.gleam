// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/bit_array
import gleam/crypto
import gleam/result
import gleam/string
import gleam_mutants/core/bytes
import gleam_mutants/mte_asset

const bootstrap = "(()=>{const app=document.querySelector(\"mutation-test-report-app\");const data=document.getElementById(\"mutation-test-report-data\");app.report=JSON.parse(data.textContent);})();"

pub fn render(report_json: String) -> Result(String, String) {
  use bundle <- result.try(
    mte_asset.javascript()
    |> result.map_error(fn(_) { "could not decode vendored MTE bundle" }),
  )
  use _ <- result.try(
    case bytes.sha256(bundle) |> string.lowercase == mte_asset.bundle_sha256 {
      True -> Ok(Nil)
      False -> Error("vendored MTE bundle SHA-256 mismatch")
    },
  )
  let content_security_policy =
    "default-src 'none'; script-src 'sha256-"
    <> sha256_base64(bundle)
    <> "' 'sha256-"
    <> sha256_base64(bootstrap)
    <> "'; style-src 'unsafe-inline'; img-src data:; font-src data:; connect-src 'none'; worker-src 'none'; object-src 'none'; frame-src 'none'; media-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'"
  let notice =
    "Third-party software: Mutation Testing Elements "
    <> mte_asset.version
    <> " by Stryker Mutator contributors; Apache-2.0; npm integrity "
    <> mte_asset.npm_integrity
    <> "; bundle SHA-256 "
    <> mte_asset.bundle_sha256
  Ok(
    "<!doctype html>\n"
    <> "<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n"
    <> "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n"
    <> "<meta http-equiv=\"Content-Security-Policy\" content=\""
    <> content_security_policy
    <> "\">\n<title>Mutation Test Report</title>\n</head>\n<body>\n"
    <> "<!-- "
    <> notice
    <> " -->\n"
    <> "<mutation-test-report-app></mutation-test-report-app>\n"
    <> "<script id=\"mutation-test-report-data\" type=\"application/json\">"
    <> escape_script_data(report_json)
    <> "</script>\n<script>"
    <> bundle
    <> "</script>\n<script>"
    <> bootstrap
    <> "</script>\n</body>\n</html>\n",
  )
}

fn escape_script_data(value: String) -> String {
  value
  |> string.replace("&", "\\u0026")
  |> string.replace("<", "\\u003c")
  |> string.replace(">", "\\u003e")
  |> string.replace("\u{2028}", "\\u2028")
  |> string.replace("\u{2029}", "\\u2029")
}

fn sha256_base64(value: String) -> String {
  crypto.hash(crypto.Sha256, bit_array.from_string(value))
  |> bit_array.base64_encode(True)
}
