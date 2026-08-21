// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/string
import gleam_mutants/stryker_html

pub fn adversarial_json_is_non_executable_and_offline_test() {
  let json =
    "{\"source\":\"</script><script id=\\\"sentinel\\\">globalThis.pwned=true</script><!-- \\\\ \\r\\n 😀     & >\"}"
  let assert Ok(html) = stryker_html.render(json)
  assert string.contains(html, "<mutation-test-report-app>")
  assert string.contains(html, "type=\"application/json\"")
  assert string.contains(html, "mutation-test-report-app\");const data=")
  assert string.contains(html, "app.report=JSON.parse(data.textContent)")
  assert string.contains(html, "\\u003c/script\\u003e")
  assert string.contains(html, "\\u0026")
  assert string.contains(html, "\\u2028")
  assert string.contains(html, "\\u2029")
  assert !string.contains(html, "<script id=\"sentinel\"")
  assert !string.contains(html, "<mutation-test-report-app src=")
  assert !string.contains(html, "<script src=")
  assert string.contains(html, "connect-src 'none'")
  assert string.contains(html, "worker-src 'none'")
  assert string.contains(html, "object-src 'none'")
  assert string.contains(html, "Mutation Testing Elements 3.9.0")
  assert string.contains(
    html,
    "751fb010242b0b44e32d84fe7fe0b9ff1da182823b94f59f5c52b001fcfc163b",
  )
}
