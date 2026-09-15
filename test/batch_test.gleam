// SPDX-FileCopyrightText: 2026 gleam_mutants contributors
// SPDX-License-Identifier: MIT OR Apache-2.0

import gleam/int
import gleam/list
import gleam_mutants/core/path
import gleam_mutants/platform
import simplifile

/// A batch runs its jobs at once, and never more of them than it was asked.
///
/// Both halves are answered by what the children do rather than by how long
/// the batch took. A child announces itself and then waits for a given number
/// of its siblings to announce themselves too, so it can only finish if that
/// many of them were running beside it. A clock would answer neither: two
/// processes racing a third on a loaded machine can take longer than three in
/// a row, and a test about this batch would be failing about the machine.
pub fn process_batch_honours_job_parallelism_test() {
  let meeting = fresh_directory()
  // Four children, two at a time, each waiting for one sibling: every one of
  // them finds it, because two are always running together.
  assert list.all(
    platform.run_process_batch(meeting_requests(meeting, 4, 2), 2),
    finished,
  )

  let crowded = fresh_directory()
  // The same four, still two at a time, now each waiting for three siblings:
  // none of them finds three, because three are never running together.
  assert list.all(
    platform.run_process_batch(meeting_requests(crowded, 4, 4), 2),
    fn(result) { !finished(result) },
  )

  let together = fresh_directory()
  // And four at a time, so that the wait above is a cap being enforced rather
  // than a number nothing could ever reach.
  assert list.all(
    platform.run_process_batch(meeting_requests(together, 4, 4), 4),
    finished,
  )

  list.each([meeting, crowded, together], fn(directory) {
    let _ = platform.delete_tree(directory)
    Nil
  })
}

fn finished(result: platform.TimedProcessResult) -> Bool {
  result.process.status == 0 && !result.process.timed_out
}

fn fresh_directory() -> String {
  let directory =
    path.join(
      platform.temporary_directory(),
      "gleam-mutants-batch-" <> platform.random_nonce(),
    )
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  directory
}

fn meeting_requests(
  directory: String,
  children: Int,
  wanted: Int,
) -> List(platform.ProcessRequest) {
  list.repeat(Nil, children)
  |> list.index_map(fn(_, index) {
    meeting_request(directory, index + 1, wanted)
  })
}

/// A child that says it is here, then waits for `wanted` of them to be here.
///
/// "Here" means running, not "has run": the marker goes when the child does,
/// so what a child counts is how many are beside it rather than how many came
/// before it. The first to reach its number says so where the others can see
/// it, which is what keeps one of them leaving from taking the answer away
/// from the rest.
///
/// The wait is bounded so that a child which is alone ends rather than hangs,
/// and the batch's own timeout is longer than that so the ending is the
/// child's answer rather than the batch giving up on it.
fn meeting_request(
  directory: String,
  index: Int,
  wanted: Int,
) -> platform.ProcessRequest {
  let script =
    "const fs = require('node:fs');"
    <> "const wait = ms => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);"
    <> "const [dir, me, wanted] = process.argv.slice(1);"
    <> "const alive = dir + '/alive-' + me;"
    <> "const met = dir + '/met';"
    <> "fs.writeFileSync(alive, '');"
    <> "const deadline = Date.now() + 3000;"
    <> "let ok = false;"
    <> "while (Date.now() < deadline) {"
    <> "  if (fs.existsSync(met)) { ok = true; break; }"
    <> "  const here = fs.readdirSync(dir).filter(n => n.startsWith('alive-')).length;"
    <> "  if (here >= Number(wanted)) { fs.writeFileSync(met, ''); ok = true; break; }"
    <> "  wait(20);"
    <> "}"
    <> "try { fs.unlinkSync(alive); } catch (_) {}"
    <> "process.exit(ok ? 0 : 1);"
  platform.ProcessRequest(
    "node",
    ["-e", script, directory, int.to_string(index), int.to_string(wanted)],
    platform.current_directory(),
    [],
    20_000,
  )
}
