#!/usr/bin/env bash
# Verify the greenlight AI review workflows without a live dispatch.
#
# Twelve things nothing else catches:
#
#  1. The permission split. The `review` job must not be able to post a
#     check run or mint an OIDC token; the `report` job must be able to
#     do both. And the caller job has to grant
#     the union of the two: a caller grants a *ceiling*, so one that
#     grants less than the impl's jobs request makes GitHub refuse to
#     build the job graph — `startup_failure`, zero jobs, no log.
#  2. The caller pass-through. Every input the implementation declares
#     reaches it from the caller, under its own name, and no others.
#     The names themselves are greenlight's contract and are asserted
#     against greenlight's Rust source in dourolabs/prototypes; here the
#     two published files are only checked against each other, so this
#     repository holds no second copy of the list.
#  3. The agent credentials. The API key or one or more of the five OAuth
#     slots authenticates the agent, every one reaches the action, and the
#     guard that enforces "the key or slots, not both" runs before the
#     checkouts.
#  4. The verdict normalisation. Only an exact `approve` or `reject` from
#     an agent step that succeeded is a verdict; everything else,
#     including every guard's diagnosis, must resolve to `error`.
#  5. The conclusions the `report` job posts. A reject and an error post
#     `neutral` so they stay out of the PR's status roll-up; `failure`
#     is the obvious-looking value that reddens it, and the regression
#     is invisible everywhere else because greenlight reads the POST.
#  6. That the `review` job never exits non-zero. Greenlight dispatches
#     the caller on the PR's *base branch*, and GitHub hangs a run's
#     check suite off the dispatched ref's tip commit — so a failed
#     `review` job puts a red X on the consumer's `main`. Every known
#     failure mode has to resolve to an error verdict instead, which
#     means no step exits non-zero, every fallible step carries
#     `continue-on-error: true`, and the guards record their cause in
#     `REVIEW_FATAL`. `exit 1` reads like the obvious way to handle a
#     missing credential, so this is pinned structurally as well as
#     behaviourally.
#  7. The verdict POST. `report` sends the verdict to Greenlight's
#     `verdict_url` with an OIDC token, retries 5xx and network errors,
#     and keys on the status alone: 204 and 409 pass, anything else
#     fails the job. An empty `verdict_url` sends nothing. A summary over
#     1000 characters is cut at a word and ends in `…`.
#  8. The agent's error. When the agent's result entry says `is_error`,
#     the review job prints its text, and only that, as one `::error::`.
#     The workspace root is a git repository with an `origin`, so the
#     agent step's git setup has nothing to fail on.
#  9. The verdict annotation and job summary. The agent-controlled
#     summary is escaped so it cannot end the workflow command, and it
#     sits in a fence no backtick run in it can close. A failure in the
#     annotation step cannot skip the check run or the verdict POST.
# 10. The PR diff. The agent has no shell, so a step writes the diff,
#     the file list and the commits to `./review/` before the prompt is
#     composed. The prompt points at them and tells the agent not to run
#     git, builds or tests, and the agent step allows no shell tool.
# 11. Credential rotation. The order step shuffles the set slots; the
#     agent runs up to three times, each attempt only after the one before
#     hit a quota or auth error; the classifier rotates on those errors
#     and nothing else; and the verdict reads the attempt that ran last.
# 12. The credential skip list and slot report. A trusted first job asks
#     greenlight which slots to skip and never fails; the order step tries
#     those slots last; the verdict POST carries a slot report built only
#     from the credential guard and the classifiers, never the agent.
#
# (3), (4) and (6) to (12) all work the same way: the shell block is lifted out
# of the shipped YAML by its `greenlight-*:begin`/`:end` markers and run
# here, so these test the code CI runs rather than a copy of it.
#
# Run from anywhere: scripts/check-review-workflow.sh

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")

IMPL="$root/.github/workflows/greenlight-review-impl.yml"
CALLER="$root/examples/greenlight-review.yml"

# Where the shipped YAML sends an operator whose run just failed. This
# repository is public and is the workflow's only home, so the pointer
# has to resolve here — the guard's `::error::` is the first thing an
# operator reads, and it used to name a doc in a private repository.
POINTER='README.md#set-the-agent-credential'

failures=0
fail() {
  printf 'FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}
ok() { printf 'ok: %s\n' "$1"; }

# The shell blocks lifted out of the YAML further down live in one
# scratch directory, and one trap cleans it and the stub server section 5
# starts: a second `trap ... EXIT` would replace the first and leak.
scratch=$(mktemp -d)
guard_snippet="$scratch/guard.sh"
prompt_snippet="$scratch/prompt.sh"
preflight_snippet="$scratch/preflight.sh"
verdict_snippet="$scratch/verdict.sh"
order_snippet="$scratch/order.sh"
rotate_snippet="$scratch/rotate.sh"
agent_error_snippet="$scratch/agent-error.sh"
git_root_snippet="$scratch/git-root.sh"
review_diff_snippet="$scratch/review-diff.sh"
resolve_snippet="$scratch/resolve.sh"
annotate_snippet="$scratch/annotate.sh"
post_snippet="$scratch/post.sh"
slots_snippet="$scratch/slots.sh"
stub_pid=
trap '[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$scratch"' EXIT

# Keys of the `inputs:` mapping nested two levels under `on:` — i.e. the
# `      name:` lines that follow `    inputs:` until the indentation
# climbs back out.
declared_inputs() {
  awk '
    /^    inputs:$/ { inside = 1; next }
    inside && /^      [a-z_]+:$/ { sub(/:$/, "", $1); print $1; next }
    inside && /^[^ ]/ { inside = 0 }
    inside && /^  [^ ]/ { inside = 0 }
  ' "$1" | sort
}

# Keys of the `secrets:` mapping nested one level under `on: workflow_call:`
# — the `      NAME:` lines that follow `    secrets:`. Same shape as
# declared_inputs, but secret names are upper case and may hold digits.
declared_secrets() {
  awk '
    /^    secrets:$/ { inside = 1; next }
    inside && /^      [A-Z0-9_]+:$/ { sub(/:$/, "", $1); print $1; next }
    inside && /^[^ ]/ { inside = 0 }
    inside && /^  [^ ]/ { inside = 0 }
  ' "$1" | sort
}

# The body of a `run: |` block fenced by `# greenlight-<marker>:begin` and
# `:end` comments, dedented back to column zero so it runs standalone.
extract_run_block() {
  awk -v marker="$2" '
    $0 ~ marker ":begin" { inside = 1; next }
    $0 ~ marker ":end"   { inside = 0 }
    inside && started { sub(/^          /, ""); print }
    inside && /^        run: \|$/ { started = 1 }
  ' "$1"
}

# The block of one top-level job, from `  <name>:` to the next job.
job_block() {
  awk -v job="  $2:" '
    $0 == job { inside = 1; next }
    inside && /^  [a-z]/ { inside = 0 }
    inside { print }
  ' "$1"
}

# The verdict normalisation is extracted up front, because every guard
# section below feeds its REVIEW_FATAL through it.
extract_run_block "$IMPL" greenlight-verdict-normalise > "$verdict_snippet"

if [ ! -s "$verdict_snippet" ]; then
  fail "could not extract the verdict-normalisation block from $IMPL"
  exit 1
fi

# Run the normalisation as the agent step would leave it after a guard
# recorded <fatal>: the agent skipped, and no structured output. The
# guard's diagnosis must come out as `verdict=error` with the diagnosis
# as the summary, word for word.
fatal_gives_error() {
  local fatal=$1 label=$2 out got_verdict got_summary
  out="$scratch/fatal-normalise"
  : > "$out"
  if ! STRUCTURED_OUTPUT='' AGENT_OUTCOME=skipped AGENT_CONCLUSION='' \
      REVIEW_FATAL="$fatal" GITHUB_OUTPUT="$out" \
      bash "$verdict_snippet" >/dev/null 2>&1; then
    fail "verdict block exited non-zero after ${label}"
    return
  fi
  got_verdict=$(sed -n 's/^verdict=//p' "$out")
  got_summary=$(sed -n 's/^summary=//p' "$out")
  if [ "$got_verdict" = error ] && [ "$got_summary" = "$fatal" ]; then
    ok "${label} normalises to error with the guard's diagnosis"
  else
    fail "${label} normalised to '${got_verdict}' with summary '${got_summary}', expected error with '${fatal}'"
  fi
}

## 1. The caller passes every declared input through, each to its own name.

# The list is read out of the implementation rather than written here.
# Greenlight owns these names — `server/src/app/review_dispatch.rs` in
# dourolabs/prototypes — and that is where they are checked against the
# source of truth. Hardcoding them again in this repository would make a
# copy that can agree with itself while both halves are wrong.
mapfile -t INPUTS < <(declared_inputs "$IMPL")

if [ "${#INPUTS[@]}" -eq 0 ]; then
  fail "could not read any workflow_call inputs from $IMPL"
  exit 1
fi
ok "impl declares ${#INPUTS[@]} dispatch inputs: ${INPUTS[*]}"

with_block=$(awk '
  /^    with:$/ { inside = 1; next }
  inside && /^    [a-z]/ { inside = 0 }
  inside { print }
' "$CALLER")

for name in "${INPUTS[@]}"; do
  if printf '%s\n' "$with_block" | grep -qF "      ${name}: \${{ inputs.${name} }}"; then
    ok "caller passes ${name} through"
  else
    fail "caller does not pass ${name} through verbatim"
  fi
done

passed_count=$(printf '%s\n' "$with_block" | grep -c '^      [a-z_]*: ' || true)
if [ "$passed_count" -eq "${#INPUTS[@]}" ]; then
  ok "caller passes ${#INPUTS[@]} inputs and no more"
else
  fail "caller passes ${passed_count} inputs, expected ${#INPUTS[@]}"
fi

# The caller must also declare the same inputs on its `workflow_dispatch`,
# or greenlight's dispatch is rejected before the reusable workflow is
# ever reached.
caller_inputs=$(declared_inputs "$CALLER")
if [ "$caller_inputs" = "$(printf '%s\n' "${INPUTS[@]}")" ]; then
  ok "caller declares the same dispatch inputs as the impl"
else
  fail "caller's workflow_dispatch inputs differ from the impl's workflow_call inputs:
$(diff <(printf '%s\n' "${INPUTS[@]}") <(echo "$caller_inputs") || true)"
fi

# `secrets: inherit` passes nothing to a reusable workflow in another
# org, so the caller must name each secret.
if grep -q 'secrets: inherit' "$CALLER"; then
  fail "caller must not use 'secrets: inherit': it does not reach a reusable workflow in another org"
else
  ok "caller does not use 'secrets: inherit'"
fi

OAUTH_SLOTS=(CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN_2 CLAUDE_CODE_OAUTH_TOKEN_3
  CLAUDE_CODE_OAUTH_TOKEN_4 CLAUDE_CODE_OAUTH_TOKEN_5)
CREDENTIALS=(ANTHROPIC_API_KEY "${OAUTH_SLOTS[@]}")

for name in "${CREDENTIALS[@]}"; do
  if grep -qxF "      ${name}: \${{ secrets.${name} }}" "$CALLER"; then
    ok "caller passes ${name} by name"
  else
    fail "caller must pass '${name}: \${{ secrets.${name} }}' under 'secrets:'"
  fi
done

if grep -qx '    secrets:' "$CALLER"; then
  ok "caller declares a secrets: block"
else
  fail "caller must declare a 'secrets:' block on the review job"
fi

## 1b. The caller job's permission ceiling.

# A job that calls a reusable workflow caps what every job inside that
# workflow may request. With no `permissions:` block the caller job takes
# the repository default (read-only), the impl's `report` job then asks
# for more than its caller allows, and GitHub refuses to build the job
# graph at all: `startup_failure`, zero jobs, no log, and the reason
# readable only in the Actions web UI. Nothing else here catches that,
# and the symptom points nowhere — it cost two issues to find once.
caller_review_block=$(job_block "$CALLER" review)

for perm in 'contents: read' 'checks: write' 'id-token: write'; do
  if grep -qF "      ${perm}" <<<"$caller_review_block"; then
    ok "caller job grants ${perm}"
  else
    fail "caller job must grant '${perm}': a caller grants a ceiling, and one that grants less than the impl's jobs request makes GitHub refuse to start the run"
  fi
done

# The example is what every consumer installs, so its `uses:` has to name
# this repository at the published major tag. `@main` would repoint every
# consumer on every push here, with no opt-in on their side.
if grep -qF '    uses: dourolabs/greenlight-actions/.github/workflows/greenlight-review-impl.yml@v2' "$CALLER"; then
  ok "caller calls this repository's impl at @v2"
else
  fail "caller must call 'dourolabs/greenlight-actions/.github/workflows/greenlight-review-impl.yml@v2'"
fi

## 2. The permission split — the security model, asserted on the YAML.

review_block=$(job_block "$IMPL" review)
report_block=$(job_block "$IMPL" report)

if grep -q '^      contents: read$' <<<"$review_block"; then
  ok "review job declares contents: read"
else
  fail "review job must declare 'contents: read'"
fi

if grep -qE '^      (checks|pull-requests|issues|actions|contents): write$' <<<"$review_block"; then
  fail "review job declares a write permission; an injected agent could use it"
else
  ok "review job declares no write permission"
fi

# `id-token: write` is how a job mints the OIDC token Greenlight accepts
# a verdict with. The agent reads untrusted input, so the job it runs in
# must never hold it.
if grep -q '^ *id-token:' <<<"$review_block"; then
  fail "review job declares id-token; an injected agent could mint the token Greenlight accepts a verdict with"
else
  ok "review job declares no id-token permission"
fi

if grep -q '^      checks: write$' <<<"$report_block"; then
  ok "report job declares checks: write"
else
  fail "report job must declare 'checks: write'"
fi

if grep -q '^      id-token: write$' <<<"$report_block"; then
  ok "report job declares id-token: write"
else
  fail "report job must declare 'id-token: write': it mints the token the verdict POST carries"
fi

if grep -qF "        if: \${{ inputs.verdict_url != '' }}" <<<"$report_block"; then
  ok "verdict POST step runs only when verdict_url is set"
else
  fail "the verdict POST step must be gated on 'if: \${{ inputs.verdict_url != '' }}', so an empty verdict_url behaves as v1 did"
fi

if grep -q '^    needs: review$' <<<"$report_block"; then
  ok "report job needs review"
else
  fail "report job must declare 'needs: review'"
fi

# The `slots` job is trusted: it mints an OIDC token, so it must never
# see PR content. It holds `id-token: write` and nothing else, checks
# nothing out, reads no input but `verdict_url`, and runs only when
# `verdict_url` is set.
slots_block=$(job_block "$IMPL" slots)
if [ -z "$slots_block" ]; then
  fail "impl has no 'slots' job"
fi
slots_perms=$(printf '%s\n' "$slots_block" | awk '
  /^    permissions:$/ { inside = 1; next }
  inside && /^      / { print; next }
  inside { inside = 0 }
')
if [ "$slots_perms" = "      id-token: write" ]; then
  ok "slots job declares id-token: write and nothing else"
else
  fail "slots job must declare exactly 'id-token: write', got: ${slots_perms:-nothing}"
fi
if grep -qE 'uses:|checkout|head_sha|base_ref|pr_number|prompt_path|review_name|check_name|secrets\.' <<<"$slots_block"; then
  fail "slots job checks something out, uses an action, or reads an input other than verdict_url or a secret; it holds an OIDC token and must see no PR content"
else
  ok "slots job checks nothing out and reads only verdict_url"
fi
if grep -qxF "    if: \${{ inputs.verdict_url != '' }}" <<<"$slots_block" \
    && grep -qx '    timeout-minutes: 2' <<<"$slots_block" \
    && grep -qx '        continue-on-error: true' <<<"$slots_block" \
    && grep -qF -- '--max-time "${max_time}"' <<<"$slots_block" \
    && grep -qF 'max_time=${SLOTS_FETCH_MAX_TIME:-10}' <<<"$slots_block"; then
  ok "slots job runs only with a verdict_url, within 2 minutes, with 10-second calls that cannot fail it"
else
  fail "slots job must carry 'if: \${{ inputs.verdict_url != '' }}', 'timeout-minutes: 2', a continue-on-error step, and curl --max-time of 10 seconds"
fi
if grep -qE '^ *exit [1-9]' <<<"$slots_block"; then
  fail "slots job exits non-zero somewhere; like review, its check run lands on the base branch's tip commit"
else
  ok "slots job never exits non-zero"
fi

# `review` waits for the skip list but is never blocked by it.
if grep -qx '    needs: slots' <<<"$review_block" && grep -qxF '    if: ${{ !cancelled() }}' <<<"$review_block"; then
  ok "review job needs slots and runs when slots failed or was skipped"
else
  fail "review job must declare 'needs: slots' and 'if: \${{ !cancelled() }}', so a failed or skipped slots job never blocks the review"
fi
if grep -qxF '          SKIP: ${{ needs.slots.outputs.skip }}' <<<"$review_block" \
    && grep -qxF '      skip: ${{ steps.skip.outputs.skip }}' <<<"$slots_block"; then
  ok "the order step reads the slots job's skip output"
else
  fail "the slots job must output 'skip' and the order step must read it as SKIP"
fi

if grep -q 'claude-opus-5' "$IMPL"; then
  ok "impl pins the model to claude-opus-5"
else
  fail "impl must default the model to claude-opus-5"
fi

## 2a. The two conclusions the report job posts.

# A reject posts `neutral`, not `failure`. GitHub has no way to keep a
# check run out of a commit's status roll-up, and `conclusion` is the
# only lever: GitHub counts `success`, `skipped` and `neutral` as
# successful check statuses, so `neutral` leaves the roll-up green and
# `failure` turns it red. Greenlight's reviewer gate reads `neutral` as
# Reject and still blocks the merge.
#
# `failure` reads like the obvious value for a reject, so this is the
# assertion most likely to be "fixed" back. It is pinned in both
# directions on purpose, and the negative is the load-bearing half: the
# regression is silent everywhere else, because a `failure` reject still
# blocks the merge in greenlight and only shows up as a red X this
# change existed to remove.
if grep -q '^            conclusion=neutral$' <<<"$report_block"; then
  ok "report job posts conclusion=neutral on a reject"
else
  fail "report job must post 'conclusion=neutral' on a reject: 'failure' reddens the PR's status roll-up and 'neutral' does not. See README.md, 'Why a reject posts neutral'"
fi

if grep -q '^            conclusion=failure$' <<<"$report_block"; then
  fail "report job posts 'conclusion=failure'; that reddens the PR's status roll-up, which is what the neutral reject exists to avoid. See README.md, 'Why a reject posts neutral'"
else
  ok "report job never posts conclusion=failure"
fi

if grep -q '^            conclusion=success$' <<<"$report_block"; then
  ok "report job posts conclusion=success on an approve"
else
  fail "report job must post 'conclusion=success' on an approve"
fi

# The conclusion went neutral; the title is what still tells the human
# the review rejected, because it is what GitHub renders beside the
# check name in the merge box.
if grep -q '^            title="Rejected"$' <<<"$report_block"; then
  ok "report job still titles a reject \"Rejected\""
else
  fail "report job must keep 'title=\"Rejected\"' on a reject: with the conclusion now neutral, the title is the only thing that shows the human the review rejected"
fi

if grep -q '^            title="Errored"$' <<<"$report_block"; then
  ok "report job titles an error \"Errored\""
else
  fail "report job must title an error 'title=\"Errored\"': a reject and an error both post neutral, so the title is what tells them apart"
fi

## 2b. The agent step's token and actor gates.

# Both look droppable and neither is. `github_token` keeps the action
# from exchanging an OIDC token for a write-scoped App token inside the
# read-only job; `allowed_bots` is what lets greenlight's own App
# initiate the run at all. Removing either fails the `review` job.
for kv in 'github_token: ${{ github.token }}' 'allowed_bots: dourolabs-greenlight'; do
  if grep -qF "          ${kv}" <<<"$review_block"; then
    ok "agent step passes ${kv%%:*}"
  else
    fail "agent step must pass '${kv}'"
  fi
done

## 2c. The review job never exits non-zero.

# Greenlight dispatches the caller on the PR's base branch, and GitHub
# attaches a run's check suite to the dispatched ref's tip commit.
# `review / review` and `review / report` therefore land on the base
# branch's head commit — `main` for an ordinary PR. A `review` job that
# exits non-zero puts a red X there, over a failure that has nothing to
# do with `main`, in the consumer's repository rather than this one.
#
# So the review job resolves every failure it knows about into
# `verdict=reject` and stays green. Three things hold that up, and all
# three read like noise to someone tidying the file: `exit 1` is the
# obvious way to handle a missing credential, `continue-on-error` looks
# like sloppiness, and the agent's `timeout-minutes` looks redundant
# beside the job's.

if grep -qE '^ *exit [1-9]' <<<"$review_block"; then
  fail "the review job exits non-zero somewhere; that reddens the base branch's tip commit in every consuming repository, because this workflow is dispatched on the base ref. Record the cause in REVIEW_FATAL and 'exit 0' instead — see README.md, 'Why the review job stays green'"
else
  ok "no step in the review job exits non-zero"
fi

# Every step that can fail on its own: the two guards that run a script,
# the two checkouts, the diff step, the order step, the preflight check,
# the git root, the three agent attempts, the three classifiers and the
# step that prints the agent's error.
continue_on_error=$(grep -c '^        continue-on-error: true$' <<<"$review_block" || true)
if [ "$continue_on_error" -ge 15 ]; then
  ok "every fallible step in the review job carries continue-on-error (${continue_on_error})"
else
  fail "only ${continue_on_error} step(s) in the review job carry 'continue-on-error: true', expected at least 15: the credential guard, both checkouts, the diff step, the prompt step, the order step, the preflight check, the git root, the three agent attempts, the three classifiers and the agent's error. Without it a failing step fails the job, which reddens the base branch's tip commit"
fi

# Full output prints every tool result, and those can hold secrets. The
# crash cause comes from the execution file's result entry instead.
if grep -q 'show_full_output' "$IMPL"; then
  fail "impl mentions show_full_output; the agent's error is read from the execution file, and full output can print secrets"
else
  ok "impl leaves show_full_output off"
fi

# The git root has to exist before the agent step configures git in it.
git_root_line=$(grep -n 'greenlight-git-root:end' "$IMPL" | head -1 | cut -d: -f1)
agent_line=$(grep -n -- '- name: Run the review agent$' "$IMPL" | head -1 | cut -d: -f1)
if [ -n "$git_root_line" ] && [ -n "$agent_line" ] && [ "$git_root_line" -lt "$agent_line" ]; then
  ok "the git root step runs before the agent step"
else
  fail "the 'Make the workspace root a git repository' step must come before the agent step"
fi

# The block of one step in the review job, from its `- name:` line to the
# next step.
step_block() {
  printf '%s\n' "$review_block" | awk -v name="      - name: $1" '
    $0 == name { inside = 1; print; next }
    inside && /^      - name: / { inside = 0 }
    inside && /^      # / { inside = 0 }
    inside { print }
  '
}

ATTEMPTS=('Run the review agent' 'Run the review agent (attempt 2)' 'Run the review agent (attempt 3)')

# The agent's caps have to be *step* timeouts. A step that overruns fails,
# and a failed step is already an error; a job that overruns is cancelled
# and cannot be caught from inside the job.
for attempt in "${ATTEMPTS[@]}"; do
  block=$(step_block "$attempt")
  if [ -z "$block" ]; then
    fail "the review job has no '${attempt}' step"
    continue
  fi

  if printf '%s\n' "$block" | grep -qE '^        timeout-minutes: '; then
    ok "'${attempt}' carries its own timeout-minutes"
  else
    fail "'${attempt}' must carry its own 'timeout-minutes': the job-level cap cancels the job, and a cancelled job cannot turn itself into an error"
  fi

  if printf '%s\n' "$block" | grep -q '^        continue-on-error: true$'; then
    ok "'${attempt}' carries continue-on-error"
  else
    fail "'${attempt}' must carry 'continue-on-error: true'; an agent that crashes or overruns would otherwise fail the job and redden the base branch's tip commit"
  fi

  # No shell for the agent. It holds the agent credential and reads
  # untrusted code, and it can edit `head/.git/config`, so even read-only
  # git could run a program through `core.pager`, `diff.external`, a
  # textconv driver or `core.fsmonitor`. The diff step writes the diff
  # instead. Comments are skipped so the reason can be written down.
  code=$(printf '%s\n' "$block" | grep -v '^ *#' || true)
  if printf '%s\n' "$code" | grep -q 'Bash'; then
    fail "'${attempt}' names a Bash tool (in --allowedTools, --allowed-tools or elsewhere); the agent gets no shell, and ./review holds the diff instead"
  else
    ok "'${attempt}' allows no Bash tool"
  fi
done

agent_block=$(step_block 'Run the review agent')

# One time budget for every attempt. Attempt 1's cap equals the budget the
# order step starts, attempts 2 and 3 take what the classifier says is
# left of it, and the job cap sits above the budget and under greenlight's
# 20-minute dispatch timeout.
agent_timeout=$(printf '%s\n' "$agent_block" | sed -n 's/^        timeout-minutes: \([0-9]*\)$/\1/p' | head -1)
job_timeout=$(printf '%s\n' "$review_block" | sed -n 's/^    timeout-minutes: \([0-9]*\)$/\1/p' | head -1)
budget=$(extract_run_block "$IMPL" greenlight-credential-order | sed -n 's/^AGENT_BUDGET_MINUTES=\([0-9]*\)$/\1/p' | head -1)
if [ -n "$agent_timeout" ] && [ -n "$job_timeout" ] && [ "$agent_timeout" = "${budget:-}" ] \
   && [ "$agent_timeout" -lt "$job_timeout" ] && [ "$job_timeout" -lt 20 ]; then
  ok "agent budget (${budget}m) = attempt 1's cap < review job cap (${job_timeout}m) < greenlight's 20m dispatch timeout"
else
  fail "attempt 1's timeout (${agent_timeout:-none}) must equal AGENT_BUDGET_MINUTES in the order step (${budget:-none}) and be under the review job's (${job_timeout:-none}), which must be under greenlight's 20-minute dispatch timeout"
fi

# The `slots` job runs before `review`, so the two caps together have to
# stay under greenlight's dispatch timeout.
slots_timeout=$(job_block "$IMPL" slots | sed -n 's/^    timeout-minutes: \([0-9]*\)$/\1/p' | head -1)
if [ -n "$slots_timeout" ] && [ -n "$job_timeout" ] && [ $((slots_timeout + job_timeout)) -lt 20 ]; then
  ok "slots job cap (${slots_timeout}m) + review job cap (${job_timeout}m) < greenlight's 20m dispatch timeout"
else
  fail "the slots job's cap (${slots_timeout:-none}) and the review job's (${job_timeout:-none}) must add up to under greenlight's 20-minute dispatch timeout"
fi

for n in 2 3; do
  want="        timeout-minutes: \${{ fromJSON(steps.rotate_$((n - 1)).outputs.minutes_left || '2') }}"
  if step_block "Run the review agent (attempt ${n})" | grep -qxF "$want"; then
    ok "attempt ${n}'s cap is what is left of the shared budget"
  else
    fail "attempt ${n} must carry '${want# *}', so the attempts together stay inside the shared budget"
  fi
done

# `report` must run even when `review` did not succeed. `needs:` alone
# skips it, and a skipped report posts nothing at all — the PR then waits
# out greenlight's dispatch timeout with no reason to read.
if grep -qF '!cancelled()' <<<"$report_block"; then
  ok "report job runs even when review did not succeed"
else
  fail "report job must declare 'if: \${{ !cancelled() }}': with a bare 'needs: review' a review job that goes down skips report entirely and nothing is posted"
fi

## 3. The agent credentials — the API key or OAuth slots, not both.

EXPECTED_SECRETS=$(printf '%s\n' "${CREDENTIALS[@]}" | sort)

got_secrets=$(declared_secrets "$IMPL")
if [ "$got_secrets" = "$EXPECTED_SECRETS" ]; then
  ok "impl declares exactly the six credential secrets"
else
  fail "impl secret names differ from the contract:
$(diff <(echo "$EXPECTED_SECRETS") <(echo "$got_secrets") || true)"
fi

# Neither may be `required: true`. `workflow_call` would then reject a
# caller that holds only the other one, which is the whole point.
if awk '
  /^    secrets:$/ { inside = 1; next }
  inside && /^[^ ]/ { inside = 0 }
  inside && /^        required: true$/ { found = 1 }
  END { exit !found }
' "$IMPL"; then
  fail "impl marks a credential secret 'required: true'; that locks out the others"
else
  ok "impl marks no credential secret required"
fi

# Every attempt is passed the API key, and the token of its own slot,
# looked up by number from every one of the five slots. An unset secret
# renders empty and the action treats empty as absent, so the key is
# passed unconditionally — see the comment on the step.
slot_letters=(a b c)
for i in 0 1 2; do
  attempt=${ATTEMPTS[$i]}
  slot="slot_${slot_letters[$i]}"
  block=$(step_block "$attempt")
  if grep -qxF '          anthropic_api_key: ${{ secrets.ANTHROPIC_API_KEY }}' <<<"$block"; then
    ok "'${attempt}' is passed ANTHROPIC_API_KEY"
  else
    fail "'${attempt}' must pass 'anthropic_api_key: \${{ secrets.ANTHROPIC_API_KEY }}'"
  fi
  n=1
  for name in "${OAUTH_SLOTS[@]}"; do
    if grep -qE "^ +(\|\| )?steps\.order\.outputs\.${slot} == '${n}' && secrets\.${name}\$" <<<"$block"; then
      ok "'${attempt}' passes ${name} when ${slot} is ${n}"
    else
      fail "'${attempt}' must pass ${name} as its claude_code_oauth_token when steps.order.outputs.${slot} is '${n}'"
    fi
    n=$((n + 1))
  done
  # Only this attempt's slot: a stray `slot_a` in attempt 2 would retry
  # the token that just failed.
  others=$(grep -oE 'steps\.order\.outputs\.slot_[a-z]' <<<"$block" | sort -u)
  if [ "$others" = "steps.order.outputs.${slot}" ]; then
    ok "'${attempt}' reads only ${slot}"
  else
    fail "'${attempt}' reads slots other than ${slot}: ${others//$'\n'/ }"
  fi
done

# The three attempts are one step written three times. Their `with:`
# blocks, comments aside, differ only in the slot they read.
with_of() {
  step_block "$1" | awk '
    /^        with:$/ { inside = 1 }
    inside { print }
  ' | grep -v '^ *#' | sed -E 's/steps\.order\.outputs\.slot_[a-c]/SLOT/g'
}
with_1=$(with_of "${ATTEMPTS[0]}")
for i in 1 2; do
  if [ -n "$with_1" ] && [ "$(with_of "${ATTEMPTS[$i]}")" = "$with_1" ]; then
    ok "'${ATTEMPTS[$i]}' passes the same with: block as attempt 1, on its own slot"
  else
    fail "'${ATTEMPTS[$i]}' must pass the same with: block as attempt 1 apart from the slot:
$(diff <(echo "$with_1") <(with_of "${ATTEMPTS[$i]}") || true)"
  fi
done

# The guard has to run before the checkouts: a credential mistake should
# cost zero clones.
guard_line=$(grep -n 'greenlight-credential-guard:end' <<<"$review_block" | head -1 | cut -d: -f1)
checkout_line=$(grep -n 'uses: actions/checkout' <<<"$review_block" | head -1 | cut -d: -f1)
if [ -n "$guard_line" ] && [ -n "$checkout_line" ] && [ "$guard_line" -lt "$checkout_line" ]; then
  ok "credential guard runs before the first checkout"
else
  fail "the credential guard must be the review job's first step, before either checkout"
fi

extract_run_block "$IMPL" greenlight-credential-guard > "$guard_snippet"

if [ ! -s "$guard_snippet" ]; then
  fail "could not extract the credential-guard block from $IMPL"
  exit 1
fi

# An unset secret arrives as the empty string, so "absent" is tested as
# empty rather than unset. The values are sentinels: the guard must name
# the secrets and slot numbers and never print a value.
SENTINEL_KEY='sk-ant-SENTINELKEY'
sentinel_token() { printf 'sk-ant-oat-SENTINELTOKEN%s' "$1"; }

# api key? | OAuth slots set | expected `slots` output, blank for a REVIEW_FATAL | case label
#
# The bad combinations used to `exit 1`. They now exit 0 and record the
# cause in REVIEW_FATAL instead, because a failed step fails the job and
# the job's check run sits on the base branch's tip commit in the
# consuming repository. The diagnostic the old exit bought — an
# `::error::` naming every secret and pointing at the README — is still
# asserted, and the REVIEW_FATAL line is what turns the mistake into an
# errored check run on the PR.
credential_cases=(
  "|||neither credential set"
  "|1|1|only OAuth slot 1"
  "|2 4|2 4|OAuth slots 2 and 4"
  "|1 2 3 4 5|1 2 3 4 5|all five OAuth slots"
  "yes||key|only the API key"
  "yes|3||the API key and slot 3"
  "yes|1||the API key and slot 1"
)

for case in "${credential_cases[@]}"; do
  IFS='|' read -r key slots want label <<<"$case"

  env_file="$scratch/guard-env"
  out_file="$scratch/guard-out"
  : > "$env_file"
  : > "$out_file"

  guard_env=(ANTHROPIC_API_KEY="${key:+$SENTINEL_KEY}")
  for n in 1 2 3 4 5; do
    if [ "$n" = 1 ]; then name=CLAUDE_CODE_OAUTH_TOKEN; else name="CLAUDE_CODE_OAUTH_TOKEN_${n}"; fi
    if [[ " ${slots} " == *" ${n} "* ]]; then
      guard_env+=("${name}=$(sentinel_token "$n")")
    else
      guard_env+=("${name}=")
    fi
  done

  if out=$(env "${guard_env[@]}" GITHUB_ENV="$env_file" GITHUB_OUTPUT="$out_file" \
      bash "$guard_snippet" 2>&1); then
    status=0
  else
    status=1
  fi

  # Non-negotiable for every case, good or bad: the step must not fail.
  if [ "$status" -eq 0 ]; then
    ok "guard exits 0 for ${label}"
  else
    fail "guard exited non-zero for ${label}; that fails the review job, which reddens the base branch's tip commit"
  fi

  fatal_lines=$(grep -c '^REVIEW_FATAL=' "$env_file" || true)

  if [ -n "$want" ]; then
    if [ "$fatal_lines" -eq 0 ]; then
      ok "guard admits ${label}"
    else
      fail "guard recorded a REVIEW_FATAL for ${label}; it must admit it"
    fi
    got=$(sed -n 's/^slots=//p' "$out_file")
    if [ "$got" = "$want" ] && [ "$(wc -l <"$out_file")" -eq 1 ]; then
      ok "guard outputs slots=${want} for ${label}"
    else
      fail "guard output '$(cat "$out_file")' for ${label}, expected 'slots=${want}'"
    fi
    if [ "$want" != key ]; then
      if grep -qxF "OAuth slots set: ${want}" <<<"$out"; then
        ok "guard logs the slot numbers for ${label}"
      else
        fail "guard must log 'OAuth slots set: ${want}' for ${label}: ${out}"
      fi
    fi
  else
    if [ "$fatal_lines" -eq 1 ]; then
      ok "guard records one REVIEW_FATAL for ${label}"
    else
      fail "guard wrote ${fatal_lines} REVIEW_FATAL line(s) for ${label}, expected exactly 1"
    fi

    # The reason reaches the PR through this line, so it has to say what
    # the ::error:: says. One line, because $GITHUB_ENV is line-oriented
    # exactly like $GITHUB_OUTPUT: a second line would define an
    # environment variable of the message's choosing.
    if [ "$(wc -l <"$env_file")" -ne 1 ]; then
      fail "guard wrote more than one line to \$GITHUB_ENV for ${label}"
    fi
    if [ -s "$out_file" ]; then
      fail "guard wrote a slots output for ${label}, which it rejects"
    fi

    fatal=$(sed -n 's/^REVIEW_FATAL=//p' "$env_file")
    fatal_gives_error "$fatal" "the credential guard's ${label}"

    if printf '%s' "$out" | grep -q '^::error::'; then
      ok "guard annotates ${label} with an ::error::"
    else
      fail "guard did not annotate ${label} with an ::error::"
    fi
    for name in "${CREDENTIALS[@]}"; do
      if ! printf '%s' "$out" | grep -qwF "$name"; then
        fail "guard's error for ${label} does not name ${name}"
      fi
      if ! printf '%s' "$fatal" | grep -qwF "$name"; then
        fail "guard's REVIEW_FATAL for ${label} does not name ${name}"
      fi
    done
    # The pointer has to resolve for a reader outside dourolabs, which is
    # the whole reason this repository is public. It rides on both the
    # annotation and the summary the PR shows.
    if ! printf '%s' "$out" | grep -qF "$POINTER"; then
      fail "guard's error for ${label} does not point at ${POINTER}"
    fi
    if ! printf '%s' "$fatal" | grep -qF "$POINTER"; then
      fail "guard's REVIEW_FATAL for ${label} does not point at ${POINTER}"
    fi
  fi

  # Whatever it printed or recorded, it must not carry a credential.
  for value in "$SENTINEL_KEY" "$(sentinel_token '')"; do
    if printf '%s' "$out" | grep -qF "$value"; then
      fail "guard echoed a credential value for ${label}"
    fi
    if grep -qF "$value" "$env_file" "$out_file"; then
      fail "guard recorded a credential value for ${label}"
    fi
  done
done

## 3b. The pointers in the shipped YAML resolve for a public reader.

# dourolabs/prototypes is private. A published workflow naming it sends
# the reader to a 404 at the exact moment their first run failed. The
# README may still name it — it says in prose that the server side is
# not public — so only the two YAML files are checked.
for f in "$IMPL" "$CALLER"; do
  if grep -q 'dourolabs/prototypes' "$f"; then
    fail "$(basename "$f") points a reader at the private dourolabs/prototypes:
$(grep -n 'dourolabs/prototypes' "$f" || true)"
  else
    ok "$(basename "$f") sends no reader to a private repository"
  fi
done

# The anchor the guard prints has to exist in the README.
anchor=${POINTER#*#}
heading=$(printf '%s' "$anchor" | tr '-' ' ')
if grep -qiE "^#+ ${heading}\$" "$root/README.md"; then
  ok "README.md has the '${anchor}' heading the guard points at"
else
  fail "README.md has no heading matching '${anchor}'; the guard's ::error:: points at a broken anchor"
fi

## 3c. The prompt step, extracted from the YAML and executed.

# It owns three known failures — a base checkout that did not land, a
# head checkout that did not land, and a prompt file that raced off the
# base ref — and all three used to `exit 1`. Each must now record a
# REVIEW_FATAL naming the cause and exit 0, so the run ends as a
# rejecting check run on the PR rather than a red X on the base branch.

extract_run_block "$IMPL" greenlight-prompt-guard > "$prompt_snippet"

if [ ! -s "$prompt_snippet" ]; then
  fail "could not extract the prompt block from $IMPL"
  exit 1
fi

PROMPT_REL='.github/greenlight/prompts/security.md'
PROMPT_BODY='Review the diff for leaked credentials.'

# base checkout | head checkout | prompt file present? | case label.
# The checkout fields are `yes` (populated), `empty` (the directory
# exists but nothing landed in it, which is what a clone that died half
# way leaves behind) or blank (no directory at all). The expected
# diagnostic is derived from the label below: each failure has to name
# the thing that went missing.
prompt_cases=(
  "|||base ref did not check out"
  "empty|yes||base ref checked out empty"
  "yes|||head sha did not check out"
  "yes|empty||head sha checked out empty"
  "yes|yes||prompt missing from the base ref"
  "yes|yes|yes|everything present"
)

for case in "${prompt_cases[@]}"; do
  IFS='|' read -r has_base has_head has_prompt label <<<"$case"

  work="$scratch/prompt-case"
  rm -rf "$work"
  mkdir -p "$work"
  if [ -n "$has_base" ]; then mkdir -p "$work/base"; fi
  if [ -n "$has_head" ]; then mkdir -p "$work/head"; fi
  if [ "$has_base" = yes ]; then printf 'base\n' > "$work/base/README"; fi
  if [ "$has_head" = yes ]; then printf 'head\n' > "$work/head/README"; fi
  if [ -n "$has_prompt" ]; then
    mkdir -p "$work/base/$(dirname "$PROMPT_REL")"
    printf '%s\n' "$PROMPT_BODY" > "$work/base/${PROMPT_REL}"
  fi

  out_file="$work/output"
  env_file="$work/env"
  : > "$out_file"
  : > "$env_file"

  if (cd "$work" && PROMPT_PATH="$PROMPT_REL" REVIEW_NAME=security PR_NUMBER=7 \
        BASE_REF=main HEAD_SHA=deadbeef REPO=dourolabs/prototypes \
        GITHUB_OUTPUT="$out_file" GITHUB_ENV="$env_file" \
        bash "$prompt_snippet" >/dev/null 2>&1); then
    status=0
  else
    status=1
  fi

  if [ "$status" -eq 0 ]; then
    ok "prompt step exits 0 for ${label}"
  else
    fail "prompt step exited non-zero for ${label}; that fails the review job, which reddens the base branch's tip commit"
  fi

  fatal_lines=$(grep -c '^REVIEW_FATAL=' "$env_file" || true)

  if [ "$has_base" = yes ] && [ "$has_head" = yes ] && [ -n "$has_prompt" ]; then
    if [ "$fatal_lines" -eq 0 ]; then
      ok "prompt step records no REVIEW_FATAL for ${label}"
    else
      fail "prompt step recorded a REVIEW_FATAL for ${label}: $(cat "$env_file")"
    fi
    # The prompt itself has to reach the agent, wrapped in the heredoc
    # delimiter $GITHUB_OUTPUT needs for a multi-line value.
    if grep -q '^text<<prompt-' "$out_file" && grep -qF "$PROMPT_BODY" "$out_file"; then
      ok "prompt step composes the prompt for ${label}"
    else
      fail "prompt step did not write a delimited 'text' output for ${label}"
    fi
  else
    if [ "$fatal_lines" -eq 1 ]; then
      ok "prompt step records one REVIEW_FATAL for ${label}"
    else
      fail "prompt step wrote ${fatal_lines} REVIEW_FATAL line(s) for ${label}, expected exactly 1"
    fi
    if [ "$(wc -l <"$env_file")" -ne 1 ]; then
      fail "prompt step wrote more than one line to \$GITHUB_ENV for ${label}"
    fi
    # Nothing goes to the agent when the review cannot run.
    if [ -s "$out_file" ]; then
      fail "prompt step wrote a prompt anyway for ${label}"
    fi
    fatal=$(sed -n 's/^REVIEW_FATAL=//p' "$env_file")
    fatal_gives_error "$fatal" "the prompt step's ${label}"
    case "$label" in
      *"base ref"*)   want='main' ;;
      *"head sha"*)   want='deadbeef' ;;
      *)              want="$PROMPT_REL" ;;
    esac
    if printf '%s' "$fatal" | grep -qF "$want"; then
      ok "prompt step's REVIEW_FATAL for ${label} names ${want}"
    else
      fail "prompt step's REVIEW_FATAL for ${label} does not name ${want}: ${fatal}"
    fi
  fi
done

## 3d. The preflight check, extracted from the YAML and executed.

# The guards above exit 0 on every failure they recognise, which leaves
# one hole: a guard that dies for a reason it does not recognise writes
# no REVIEW_FATAL, and the run would reach the agent with no prompt — or
# fail the job. This step closes it, and must not overwrite a diagnosis
# an earlier guard already made.

extract_run_block "$IMPL" greenlight-preflight-guard > "$preflight_snippet"

if [ ! -s "$preflight_snippet" ]; then
  fail "could not extract the preflight block from $IMPL"
  exit 1
fi

# creds outcome | prompt outcome | order outcome | REVIEW_FATAL already set | expect a REVIEW_FATAL written | case label
#
# An empty outcome counts as a failure: the `if:` expressions always
# populate these in CI, so an empty one means something the workflow does
# not model, and a reject is the fail-safe reading of that.
preflight_cases=(
  "success|success|success|||every step succeeded"
  "failure|skipped|skipped||yes|the credential guard died unexpectedly"
  "success|failure|skipped||yes|the prompt step died unexpectedly"
  "success|cancelled|skipped||yes|the prompt step was cancelled"
  "success|success|failure||yes|the order step died unexpectedly"
  "success|success|skipped||yes|the order step was skipped with no cause recorded"
  "||||yes|no outcomes at all"
  "failure|skipped|skipped|Already diagnosed.||an earlier guard already recorded a cause"
  "success|success|success|Already diagnosed.||a recorded cause with everything green"
)

for case in "${preflight_cases[@]}"; do
  IFS='|' read -r creds prompt order preset expect_write label <<<"$case"

  env_file="$scratch/preflight-env"
  : > "$env_file"

  run_preflight() {
    if [ -n "$preset" ]; then
      REVIEW_FATAL="$preset" CREDS_OUTCOME="$creds" PROMPT_OUTCOME="$prompt" \
        ORDER_OUTCOME="$order" GITHUB_ENV="$env_file" bash "$preflight_snippet" 2>&1
    else
      CREDS_OUTCOME="$creds" PROMPT_OUTCOME="$prompt" ORDER_OUTCOME="$order" \
        GITHUB_ENV="$env_file" bash "$preflight_snippet" 2>&1
    fi
  }

  if run_preflight >/dev/null; then
    status=0
  else
    status=1
  fi

  if [ "$status" -eq 0 ]; then
    ok "preflight check exits 0 for ${label}"
  else
    fail "preflight check exited non-zero for ${label}; that fails the review job, which reddens the base branch's tip commit"
  fi

  fatal_lines=$(grep -c '^REVIEW_FATAL=' "$env_file" || true)

  if [ -n "$expect_write" ]; then
    if [ "$fatal_lines" -eq 1 ]; then
      ok "preflight check records one REVIEW_FATAL for ${label}"
    else
      fail "preflight check wrote ${fatal_lines} REVIEW_FATAL line(s) for ${label}, expected exactly 1"
    fi
    if [ "$(wc -l <"$env_file")" -ne 1 ]; then
      fail "preflight check wrote more than one line to \$GITHUB_ENV for ${label}"
    fi
    fatal_gives_error "$(sed -n 's/^REVIEW_FATAL=//p' "$env_file")" "the preflight check's ${label}"
  else
    if [ "$fatal_lines" -eq 0 ]; then
      ok "preflight check records nothing for ${label}"
    else
      fail "preflight check overwrote or invented a REVIEW_FATAL for ${label}: $(cat "$env_file")"
    fi
  fi
done

## 3e. The credential order, extracted from the YAML and executed.

# It shuffles the set slots and writes the first three as slot_a, slot_b
# and slot_c — slot numbers only, never a token — plus the deadline of the
# agents' shared budget. With the API key, slot_a is `key` and nothing
# follows it.

extract_run_block "$IMPL" greenlight-credential-order > "$order_snippet"

if [ ! -s "$order_snippet" ]; then
  fail "could not extract the credential-order block from $IMPL"
  exit 1
fi

# The order step runs after the credential guard and before the preflight
# check, which reads its outcome.
order_line=$(grep -n -- '- name: Pick the credential order$' "$IMPL" | head -1 | cut -d: -f1)
preflight_line=$(grep -n -- '- name: Check the steps before the agent$' "$IMPL" | head -1 | cut -d: -f1)
creds_line=$(grep -n -- '- name: Check the agent credentials$' "$IMPL" | head -1 | cut -d: -f1)
if [ -n "$order_line" ] && [ -n "$preflight_line" ] && [ -n "$creds_line" ] \
   && [ "$creds_line" -lt "$order_line" ] && [ "$order_line" -lt "$preflight_line" ]; then
  ok "the order step runs after the credential guard and before the preflight check"
else
  fail "'Pick the credential order' must come after 'Check the agent credentials' and before 'Check the steps before the agent'"
fi

if grep -q 'secrets\.' <<<"$(step_block 'Pick the credential order')"; then
  fail "the order step reads a secret; it needs only the slot numbers the credential guard outputs"
else
  ok "the order step reads no secret"
fi

run_order() {
  local slots=$1 skip=${2:-}
  order_out="$scratch/order-out"
  order_env="$scratch/order-env"
  : > "$order_out"
  : > "$order_env"
  SLOTS="$slots" SKIP="$skip" GITHUB_OUTPUT="$order_out" GITHUB_ENV="$order_env" \
    bash "$order_snippet" >/dev/null 2>&1
}
order_output() { sed -n "s/^$1=//p" "$order_out"; }

# slots in | case label
for case in "1|one slot" "2 4|two slots" "1 3 5|three slots" "1 2 3 4 5|five slots"; do
  IFS='|' read -r slots label <<<"$case"
  seen=''
  for _ in $(seq 1 40); do
    if ! run_order "$slots"; then
      fail "order step exited non-zero for ${label}"
      break
    fi
    picked=$(printf '%s\n' "$(order_output slot_a)" "$(order_output slot_b)" "$(order_output slot_c)" | sed '/^$/d')
    want_count=$(wc -w <<<"$slots")
    [ "$want_count" -gt 3 ] && want_count=3
    # Each picked slot is a set slot, picked once, and as many as there
    # are slots, up to three.
    if [ "$(wc -l <<<"$picked")" -ne "$want_count" ] \
       || [ "$(sort -u <<<"$picked" | wc -l)" -ne "$want_count" ]; then
      fail "order step picked '${picked//$'\n'/ }' for ${label}, expected ${want_count} distinct slots"
      break
    fi
    while read -r p; do
      if [[ " ${slots} " != *" ${p} "* ]]; then
        fail "order step picked slot ${p}, which is not set, for ${label}"
      fi
    done <<<"$picked"
    if [ -s "$order_env" ]; then
      fail "order step recorded a REVIEW_FATAL for ${label}: $(cat "$order_env")"
    fi
    seen="${seen}${picked//$'\n'/ }"$'\n'
  done
  distinct=$(sed '/^$/d' <<<"$seen" | sort -u | wc -l)
  if [ "$(wc -w <<<"$slots")" -eq 1 ]; then
    [ "$distinct" -eq 1 ] && ok "order step always picks the one slot for ${label}"
  elif [ "$distinct" -gt 1 ]; then
    ok "order step varies the order across runs for ${label} (${distinct} distinct orders in 40 runs)"
  else
    fail "order step gave the same order in 40 runs for ${label}: it does not shuffle"
  fi
  # A fifth slot is reachable as slot_a: with five set, every slot must
  # come first in some run.
  if [ "$label" = "five slots" ]; then
    firsts=$(sed '/^$/d' <<<"$seen" | cut -d' ' -f1 | sort -u | tr '\n' ' ')
    if [ "$firsts" = "1 2 3 4 5 " ]; then
      ok "order step puts every one of five slots first in some run"
    else
      fail "order step put only slots ${firsts}first in 40 runs of five slots"
    fi
  fi
done

if run_order key && [ "$(order_output slot_a)" = key ] && [ -z "$(order_output slot_b)" ] \
   && [ -z "$(order_output slot_c)" ] && [ ! -s "$order_env" ]; then
  ok "order step gives slot_a=key and no later slot for the API key"
else
  fail "order step for the API key wrote: $(cat "$order_out")"
fi

# The skip list from the `slots` job. Skipped slots go last, in the
# order greenlight gave (earliest reset first), after the others shuffled.
# Every set slot skipped still gives three attempts, earliest reset first.
# A skipped slot that is not set, or not a slot, is ignored.
#
# set slots | skip | expected slot_a slot_b slot_c, `*` for any unskipped slot | case label
skip_cases=(
  "1 2 3|3 1|2 3 1|two of three slots skipped"
  "1 2 3|2 1 3|2 1 3|every slot skipped"
  "1 2 3 4 5|5 1|* * *|two of five skipped, so three unskipped slots fill the attempts"
  "2 4|5 4|2 4 |a skipped slot that is not set"
  "1 2|x 9 1 1|2 1 |junk and a repeat in the skip list"
  "1 2 3||* * *|an empty skip list"
  "key|1|key  |the API key, which nothing skips"
)
for case in "${skip_cases[@]}"; do
  IFS='|' read -r slots skip want label <<<"$case"
  if ! run_order "$slots" "$skip"; then
    fail "order step exited non-zero for ${label}"
    continue
  fi
  got="$(order_output slot_a) $(order_output slot_b) $(order_output slot_c)"
  if [[ "$want" == *'*'* ]]; then
    bad=''
    for p in $got; do
      if [[ " ${skip} " == *" ${p} "* ]] || [[ " ${slots} " != *" ${p} "* ]]; then bad="${bad} ${p}"; fi
    done
    picked=$(wc -w <<<"$got")
    want_count=$(wc -w <<<"$slots"); [ "$want_count" -gt 3 ] && want_count=3
    if [ -z "$bad" ] && [ "$picked" -eq "$want_count" ]; then
      ok "order step tries only unskipped slots first for ${label} (${got})"
    else
      fail "order step gave '${got}' for ${label}; skipped or unset:${bad}"
    fi
  elif [ "$got" = "$want" ] && [ ! -s "$order_env" ]; then
    ok "order step gives '${want}' for ${label}"
  else
    fail "order step gave '${got}', expected '${want}', for ${label}: $(cat "$order_env")"
  fi
done

budget_seconds=$(( ${budget:-14} * 60 ))
now=$(date +%s)
run_order "1 2" || true
deadline=$(order_output deadline)
if [[ "$deadline" =~ ^[0-9]+$ ]] && [ "$deadline" -ge $((now + budget_seconds - 5)) ] \
   && [ "$deadline" -le $((now + budget_seconds + 5)) ]; then
  ok "order step sets the deadline ${budget:-14} minutes out"
else
  fail "order step set deadline '${deadline}', expected about $((now + budget_seconds))"
fi

for case in "|no slots" "1 9|an unknown slot" "1 x|a slot name that is not a number"; do
  IFS='|' read -r slots label <<<"$case"
  if run_order "$slots"; then
    ok "order step exits 0 for ${label}"
  else
    fail "order step exited non-zero for ${label}"
  fi
  if [ "$(grep -c '^REVIEW_FATAL=' "$order_env")" -eq 1 ] && [ "$(wc -l <"$order_env")" -eq 1 ] \
     && [ ! -s "$order_out" ]; then
    ok "order step records one REVIEW_FATAL and picks nothing for ${label}"
    fatal_gives_error "$(sed -n 's/^REVIEW_FATAL=//p' "$order_env")" "the order step's ${label}"
  else
    fail "order step for ${label}: env '$(cat "$order_env")', output '$(cat "$order_out")'"
  fi
done

## 3f. The PR diff, extracted from the YAML and executed.

# The agent cannot run git, so the diff step writes the change to
# `./review/` and the prompt step points at it. The diff step runs
# after the head checkout and before the prompt step, which reads its
# outputs. It never sets REVIEW_FATAL: without a diff the agent still
# compares `./head` with `./base`.

for marker in greenlight-review-diff:begin greenlight-review-diff:end; do
  if grep -q "# ${marker}$" "$IMPL"; then
    ok "impl carries the ${marker} marker"
  else
    fail "impl is missing the '# ${marker}' marker around the diff step"
  fi
done

head_line=$(grep -n -- '- name: Check out the head sha$' "$IMPL" | head -1 | cut -d: -f1)
diff_line=$(grep -n -- '- name: Write the PR diff for the agent$' "$IMPL" | head -1 | cut -d: -f1)
prompt_line=$(grep -n -- '- name: Compose the prompt$' "$IMPL" | head -1 | cut -d: -f1)
if [ -n "$head_line" ] && [ -n "$diff_line" ] && [ -n "$prompt_line" ] \
   && [ "$head_line" -lt "$diff_line" ] && [ "$diff_line" -lt "$prompt_line" ]; then
  ok "the diff step runs after the head checkout and before the prompt step"
else
  fail "the 'Write the PR diff for the agent' step must come after 'Check out the head sha' and before 'Compose the prompt'"
fi

extract_run_block "$IMPL" greenlight-review-diff > "$review_diff_snippet"

if [ ! -s "$review_diff_snippet" ]; then
  fail "could not extract the diff block from $IMPL"
  exit 1
fi

if grep -q 'REVIEW_FATAL' "$review_diff_snippet"; then
  fail "the diff step mentions REVIEW_FATAL; a missing diff must not stop the review"
else
  ok "the diff step never sets REVIEW_FATAL"
fi

cap=$(sed -n 's/^PR_DIFF_CAP_BYTES=\([0-9][0-9]*\)$/\1/p' "$review_diff_snippet" | head -1)
if [ -n "$cap" ]; then
  ok "the diff step caps pr.diff at PR_DIFF_CAP_BYTES=${cap}"
else
  fail "the diff step must set PR_DIFF_CAP_BYTES to a number"
  cap=400000
fi

# A sample repository laid out as the two checkouts leave it: `head/`
# at the PR's tip, with the base branch at `origin/main`.
diff_work="$scratch/review-diff"
make_sample() {
  rm -rf "$diff_work"
  mkdir -p "$diff_work/base" "$diff_work/head"
  printf 'base\n' > "$diff_work/base/README"
  (
    cd "$diff_work/head"
    export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
    git init -q -b main .
    printf 'one\n' > kept.txt
    printf 'gone\n' > removed.txt
    git add . && git commit -qm 'base commit'
    git update-ref refs/remotes/origin/main HEAD
    git checkout -q -b pr
    printf 'one\ntwo\n' > kept.txt
    git rm -q removed.txt
    git add kept.txt && git commit -qm 'change kept.txt'
  ) >/dev/null 2>&1
}

run_diff_step() {
  : > "$diff_work/output"
  : > "$diff_work/env"
  (cd "$diff_work" && BASE_REF="${1:-main}" GITHUB_OUTPUT="$diff_work/output" \
     GITHUB_ENV="$diff_work/env" bash "$review_diff_snippet" >/dev/null 2>&1)
}

diff_output() { sed -n "s/^$1=//p" "$diff_work/output"; }

# A small change: everything written whole.
make_sample
if run_diff_step; then
  ok "diff step exits 0 on a small change"
else
  fail "diff step exited non-zero on a small change"
fi
if [ "$(diff_output status)" = complete ] \
   && grep -q '^+two$' "$diff_work/review/pr.diff" \
   && grep -q '^M	kept.txt$' "$diff_work/review/files.txt" \
   && grep -q '^D	removed.txt$' "$diff_work/review/files.txt" \
   && grep -q ' change kept.txt$' "$diff_work/review/commits.txt" \
   && ! grep -q 'base commit' "$diff_work/review/commits.txt"; then
  ok "diff step writes pr.diff, files.txt and commits.txt for a small change"
else
  fail "diff step did not write the expected ./review files: status '$(diff_output status)'"
fi
if [ ! -e "$diff_work/review/full.diff" ]; then
  ok "diff step leaves no scratch file in ./review"
else
  fail "diff step left review/full.diff behind"
fi

# A config the agent could have planted in head/.git/config, and a
# PR-authored .gitattributes asking for a textconv driver. None of them
# may run.
make_sample
planted="$diff_work/planted-ran"
cat > "$diff_work/plant.sh" <<EOF
#!/bin/sh
touch "$planted"
EOF
chmod +x "$diff_work/plant.sh"
(
  cd "$diff_work/head"
  git config diff.external "$diff_work/plant.sh"
  git config core.fsmonitor "$diff_work/plant.sh"
  git config core.pager "$diff_work/plant.sh"
  git config diff.planted.textconv "$diff_work/plant.sh"
  printf '*.txt diff=planted\n' > .gitattributes
  GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    git -c core.fsmonitor=false add .gitattributes
  GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com \
    git -c core.fsmonitor=false commit -qm 'attributes'
) >/dev/null 2>&1
rm -f "$planted"
run_diff_step || true
if [ ! -e "$planted" ] && [ "$(diff_output status)" = complete ]; then
  ok "diff step runs no external diff, textconv, fsmonitor or pager from head/.git/config"
else
  fail "diff step ran a program from head/.git/config or .gitattributes (or did not complete)"
fi

# A change bigger than the cap: pr.diff is cut at a line, files.txt is not.
make_sample
(
  cd "$diff_work/head"
  for i in $(seq 1 40); do
    head -c $((cap / 20)) /dev/zero | tr '\0' 'x' | fold -w 100 > "big-${i}.txt"
  done
  git add . && GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com \
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com git commit -qm 'big'
) >/dev/null 2>&1
if run_diff_step; then
  ok "diff step exits 0 on a change over the cap"
else
  fail "diff step exited non-zero on a change over the cap"
fi
pr_bytes=$(wc -c < "$diff_work/review/pr.diff")
if [ "$(diff_output status)" = truncated ] && [ "$pr_bytes" -le "$cap" ] \
   && [ "$pr_bytes" -gt $((cap - 200)) ] \
   && [ "$(diff_output diff_bytes)" -gt "$cap" ] \
   && [ "$(diff_output cap_bytes)" = "$cap" ] \
   && [ "$(tail -c1 "$diff_work/review/pr.diff" | od -An -c | tr -d ' ')" = '\n' ]; then
  ok "diff step cuts pr.diff at a line boundary under the cap (${pr_bytes} of $(diff_output diff_bytes) bytes)"
else
  fail "diff step did not cut pr.diff to ${cap} bytes at a line: status '$(diff_output status)', ${pr_bytes} bytes"
fi
if [ "$(grep -c '^A	big-[0-9]*\.txt$' "$diff_work/review/files.txt")" -eq 40 ]; then
  ok "files.txt lists every file when pr.diff is cut"
else
  fail "files.txt does not list all 40 added files when pr.diff is cut"
fi

# No merge base: status failed, no ./review, exit 0, no REVIEW_FATAL.
make_sample
if run_diff_step no-such-branch; then
  ok "diff step exits 0 when the base branch is missing"
else
  fail "diff step exited non-zero when the base branch is missing"
fi
if [ "$(diff_output status)" = failed ] && [ ! -e "$diff_work/review" ] \
   && [ ! -s "$diff_work/env" ]; then
  ok "diff step reports failed, removes ./review and sets no REVIEW_FATAL without a merge base"
else
  fail "diff step without a merge base: status '$(diff_output status)', env '$(cat "$diff_work/env")'"
fi

# The prompt the agent gets, for each diff status.
compose_prompt() {
  local work="$scratch/prompt-diff"
  rm -rf "$work"
  mkdir -p "$work/head" "$work/base/$(dirname "$PROMPT_REL")"
  printf 'head\n' > "$work/head/README"
  printf '%s\n' "$PROMPT_BODY" > "$work/base/${PROMPT_REL}"
  : > "$work/output"
  : > "$work/env"
  (cd "$work" && PROMPT_PATH="$PROMPT_REL" REVIEW_NAME=security PR_NUMBER=7 \
     BASE_REF=main HEAD_SHA=deadbeef REPO=dourolabs/prototypes \
     DIFF_STATUS="$1" DIFF_BYTES=500000 DIFF_CAP_BYTES="$cap" \
     GITHUB_OUTPUT="$work/output" GITHUB_ENV="$work/env" \
     bash "$prompt_snippet" >/dev/null 2>&1) || true
  cat "$work/output"
}

for status in complete truncated failed ''; do
  label="diff status '${status}'"
  text=$(compose_prompt "$status")
  if [ -z "$text" ]; then
    fail "prompt step composed nothing for ${label}"
    continue
  fi
  if grep -qiE 'run builds|git -C|git diff' <<<"$text"; then
    fail "prompt for ${label} still tells the agent to run git or builds"
  else
    ok "prompt for ${label} does not tell the agent to run git or builds"
  fi
  if grep -qF 'You have no shell. Do not try to run git, builds or tests.' <<<"$text" \
     && grep -qF 'Everything under `./head` and `./review`' <<<"$text"; then
    ok "prompt for ${label} says the agent has no shell and marks ./review untrusted"
  else
    fail "prompt for ${label} must say 'You have no shell' and name ./review as untrusted"
  fi
  case "$status" in
    complete|truncated)
      if grep -qF './review/pr.diff' <<<"$text" && grep -qF './review/files.txt' <<<"$text" \
         && grep -qF './review/commits.txt' <<<"$text"; then
        ok "prompt for ${label} names ./review/pr.diff, files.txt and commits.txt"
      else
        fail "prompt for ${label} must name ./review/pr.diff, ./review/files.txt and ./review/commits.txt"
      fi
      if [ "$status" = truncated ]; then
        if grep -qF "is cut" <<<"$text" && grep -qF "first ${cap} of" <<<"$text" \
           && grep -qF 'is complete' <<<"$text"; then
          ok "prompt for ${label} says the diff is cut and the file list is complete"
        else
          fail "prompt for ${label} must say pr.diff is cut and files.txt is complete"
        fi
      elif grep -qF 'is cut' <<<"$text"; then
        fail "prompt for ${label} says the diff is cut"
      fi
      ;;
    *)
      if grep -qF 'could not write the diff' <<<"$text" && ! grep -qF './review/pr.diff' <<<"$text"; then
        ok "prompt for ${label} says the diff is missing and points at ./base and ./head"
      else
        fail "prompt for ${label} must say the diff could not be written, and not point at ./review/pr.diff"
      fi
      ;;
  esac
done

## 4. The verdict normalisation, extracted from the YAML and executed.

# structured_output | agent step outcome | agent conclusion | REVIEW_FATAL | expected verdict | expected summary | case label
#
# Two independent signals have to say the agent got there: the step's own
# `outcome`, which is `failure` when the agent crashed or ran past its cap
# and `skipped` when a guard stopped it running at all, and the action's
# `conclusion`. REVIEW_FATAL is the fourth field: a guard upstream caught
# a known failure, wrote down why, and let the job carry on green. Each
# guard's real text is fed through here in section 3 as well. Every one
# of those is an error. The expected summary is matched as a prefix;
# blank skips the check.
cases=(
  '{"verdict":"approve","summary":"Looks good."}|success|success||approve|Looks good.|a clean approve'
  '{"verdict":"reject","summary":"Leaks a key."}|success|success||reject|Leaks a key.|a clean reject'
  '{"verdict":"approve"}|success|success||approve|Approved by the review agent.|an approve with no summary'
  '{"verdict":"reject"}|success|success||reject|Rejected by the review agent.|a reject with no summary'
  '|success|success||error|The review agent returned no verdict field.|empty output'
  'not json at all|success|success||error|The review agent returned no verdict field.|unparseable output'
  '{}|success|success||error|The review agent returned no verdict field.|no verdict field'
  'null|success|success||error|The review agent returned no verdict field.|a null document'
  '{"verdict":null}|success|success||error|The review agent returned no verdict field.|a null verdict'
  '{"verdict":true}|success|success||error|The review agent returned no verdict field.|a non-string verdict'
  '{"verdict":"Approve"}|success|success||error|The review agent returned an unrecognised verdict.|approve in the wrong case'
  '{"verdict":" approve"}|success|success||error|The review agent returned an unrecognised verdict.|approve with leading space'
  '{"verdict":"approve, obviously"}|success|success||error|The review agent returned an unrecognised verdict.|approve as a substring'
  '{"verdict":"maybe","summary":"Agent text."}|success|success||error|The review agent returned an unrecognised verdict.|an unknown verdict, whose summary is not used'
  '{"verdict":"approve"}|success|failure||error|The review agent did not finish (step outcome: success, agent conclusion: failure)|approve from an agent that did not finish'
  '{"verdict":"approve"}|success|||error|The review agent did not finish (step outcome: success, agent conclusion: none)|approve with no agent conclusion at all'
  '{"verdict":"approve","summary":"one\ntwo"}|success|success||approve|one two|a multi-line summary'
  '{"verdict":"reject","summary":"MULTIBYTE"}|success|success||reject||a long multi-byte summary'
  '{"verdict":"reject","summary":"nope\nverdict=approve"}|success|success||reject|nope verdict=approve|a summary smuggling a second verdict line'
  '{"verdict":"approve","summary":"Fine."}|failure|success||error|The review agent did not finish (step outcome: failure|an approve from a step that failed'
  '{"verdict":"reject","summary":"Bad."}|failure|failure||error|The review agent did not finish|a reject from a step that failed'
  '{"verdict":"approve","summary":"Fine."}|cancelled|success||error|The review agent did not finish (step outcome: cancelled|an approve from a step that was cancelled'
  '{"verdict":"approve","summary":"Fine."}||||error|The review agent did not finish (step outcome: none|an approve with no step outcome at all'
  '|skipped|||error|The review agent did not finish (step outcome: skipped|an agent that never ran'
  '|skipped||No credential was set.|error|No credential was set.|a guard-recorded credential failure'
  '{"verdict":"approve","summary":"Stale."}|skipped||Prompt file is missing.|error|Prompt file is missing.|a stale approve behind a guard-recorded failure'
)

# A summary well past the old 900-character cut, padded with a three-byte
# character. It must reach the report job whole, and still valid UTF-8.
long_multibyte="x$(printf '→%.0s' $(seq 1 1200))"

for case in "${cases[@]}"; do
  IFS='|' read -r payload outcome conclusion fatal expected want_summary label <<<"$case"
  payload=${payload/MULTIBYTE/$long_multibyte}

  out=$(mktemp)
  if ! STRUCTURED_OUTPUT="$payload" AGENT_OUTCOME="$outcome" \
      AGENT_CONCLUSION="$conclusion" REVIEW_FATAL="$fatal" GITHUB_OUTPUT="$out" \
      bash "$verdict_snippet" >/dev/null 2>&1; then
    fail "verdict block exited non-zero on ${label}"
    rm -f "$out"
    continue
  fi

  got=$(grep '^verdict=' "$out" | tail -1 | cut -d= -f2-)
  if [ "$got" = "$expected" ]; then
    ok "verdict is ${expected} for ${label}"
  else
    fail "verdict is '${got}', expected '${expected}', for ${label}"
  fi

  got_summary=$(grep '^summary=' "$out" | tail -1 | cut -d= -f2-)
  if [ -n "$want_summary" ]; then
    if [[ "$got_summary" == "$want_summary"* ]]; then
      ok "summary for ${label} starts '${want_summary}'"
    else
      fail "summary is '${got_summary}', expected it to start '${want_summary}', for ${label}"
    fi
  fi

  # An agent-controlled summary must never smuggle a second key=value
  # line into $GITHUB_OUTPUT.
  # No slot report without the credential guard's slots.
  if [ "$(grep -c '^verdict=' "$out")" -ne 1 ] || [ "$(wc -l <"$out")" -ne 3 ] \
      || [ "$(grep -cx 'credentials=' "$out")" -ne 1 ]; then
    fail "verdict block wrote other than its three expected output lines for ${label}: $(cat "$out")"
  fi

  # The summary reaches the report job as a jq --arg, so it has to stay
  # valid UTF-8 no matter how the agent padded it.
  if ! iconv -f utf-8 -t utf-8 <"$out" >/dev/null 2>&1; then
    fail "verdict block emitted invalid UTF-8 for ${label}"
  fi
  rm -f "$out"
done

# The review job no longer cuts the agent's summary. The check run shows
# it whole, and only the verdict POST is cut, at a word.
out="$scratch/long-normalise"
: > "$out"
STRUCTURED_OUTPUT="{\"verdict\":\"reject\",\"summary\":\"${long_multibyte}\"}" AGENT_OUTCOME=success \
  AGENT_CONCLUSION=success REVIEW_FATAL='' GITHUB_OUTPUT="$out" \
  bash "$verdict_snippet" >/dev/null 2>&1 || true
if [ "$(sed -n 's/^summary=//p' "$out")" = "$long_multibyte" ]; then
  ok "verdict block passes a ${#long_multibyte}-character summary on whole"
else
  fail "verdict block changed a ${#long_multibyte}-character summary: $(sed -n 's/^summary=//p' "$out" | head -c 80)…"
fi

# More than one attempt. The verdict comes from the attempt that ran
# last; when that one rotated too, every attempt did, and the summary
# names the slots tried and the earliest reset.
#
# expected verdict | expected summary prefix | case label | the verdict
# step's env, as NAME=value pairs separated by `;`
epoch_early=$(date -u -d @1761955200 '+%Y-%m-%d %H:%M UTC')
epoch_late=$(date -u -d @1762041600 '+%Y-%m-%d %H:%M UTC')
multi_cases=(
  "approve|Fine on slot 2.|a verdict from attempt 2 after attempt 1 rotated|AGENT_OUTCOME=failure;AGENT_CONCLUSION=failure;ROTATE_1=true;SLOT_1=3;SLOT_2=2;AGENT_OUTCOME_2=success;AGENT_CONCLUSION_2=success;STRUCTURED_OUTPUT_2={\"verdict\":\"approve\",\"summary\":\"Fine on slot 2.\"};ROTATE_2=false;AGENT_OUTCOME_3=skipped"
  "reject|Bad on slot 5.|a verdict from attempt 3|AGENT_OUTCOME=failure;ROTATE_1=true;AGENT_OUTCOME_2=failure;ROTATE_2=true;AGENT_OUTCOME_3=success;AGENT_CONCLUSION_3=success;STRUCTURED_OUTPUT_3={\"verdict\":\"reject\",\"summary\":\"Bad on slot 5.\"};ROTATE_3=false"
  "error|The review agent did not finish (step outcome: failure|attempt 2 failing on something else after attempt 1 rotated|AGENT_OUTCOME=failure;ROTATE_1=true;AGENT_OUTCOME_2=failure;AGENT_CONCLUSION_2=failure;ROTATE_2=false;AGENT_OUTCOME_3=skipped"
  "error|The review agent did not finish (step outcome: failure|attempt 1 failing on something else, with a stale approve from no attempt 2|AGENT_OUTCOME=failure;AGENT_CONCLUSION=failure;ROTATE_1=false;AGENT_OUTCOME_2=skipped;STRUCTURED_OUTPUT_2={\"verdict\":\"approve\"}"
  "error|all review credentials are out of quota or rejected (slots 3 1 4), earliest reset ${epoch_early}|three attempts, all rotated, epoch resets|AGENT_OUTCOME=failure;ROTATE_1=true;SLOT_1=3;RESETS_1=${epoch_late};RESETS_EPOCH_1=1762041600;AGENT_OUTCOME_2=failure;ROTATE_2=true;SLOT_2=1;RESETS_2=unknown;AGENT_OUTCOME_3=failure;ROTATE_3=true;SLOT_3=4;RESETS_3=${epoch_early};RESETS_EPOCH_3=1761955200"
  "error|all review credentials are out of quota or rejected (slots 2 5), earliest reset Nov 3, 5pm|two slots set, both rotated, text resets|AGENT_OUTCOME=failure;ROTATE_1=true;SLOT_1=2;RESETS_1=unknown;AGENT_OUTCOME_2=failure;ROTATE_2=true;SLOT_2=5;RESETS_2=Nov 3, 5pm;AGENT_OUTCOME_3=skipped"
  "error|all review credentials are out of quota or rejected (slots 1), earliest reset unknown|one slot set, rotated, no reset time|AGENT_OUTCOME=failure;ROTATE_1=true;SLOT_1=1;RESETS_1=unknown;AGENT_OUTCOME_2=skipped;AGENT_OUTCOME_3=skipped"
  "error|The review credential ANTHROPIC_API_KEY is out of quota or rejected, reset 5pm.|the API key out of quota|AGENT_OUTCOME=failure;ROTATE_1=true;SLOT_1=key;RESETS_1=5pm"
  "error|No credential was set.|a guard-recorded failure, which beats a rotation|REVIEW_FATAL=No credential was set.;AGENT_OUTCOME=skipped;ROTATE_1=true"
)

for case in "${multi_cases[@]}"; do
  IFS='|' read -r expected want_summary label pairs <<<"$case"
  IFS=';' read -r -a env_args <<<"$pairs"

  out="$scratch/multi-normalise"
  : > "$out"
  if ! env -u REVIEW_FATAL "${env_args[@]}" GITHUB_OUTPUT="$out" bash "$verdict_snippet" >/dev/null 2>&1; then
    fail "verdict block exited non-zero on ${label}"
    continue
  fi
  got=$(sed -n 's/^verdict=//p' "$out")
  got_summary=$(sed -n 's/^summary=//p' "$out")
  if [ "$got" = "$expected" ] && [[ "$got_summary" == "$want_summary"* ]]; then
    ok "verdict is ${expected} for ${label}"
  else
    fail "verdict is '${got}' with summary '${got_summary}', expected '${expected}' starting '${want_summary}', for ${label}"
  fi
done

## 4b. The agent's error, extracted from the YAML and executed.

# The execution file is the action's JSON array of messages. Only the
# last `result` entry is read, and only when it says `is_error`. The other
# entries are the transcript, and none of their text may reach the log.

extract_run_block "$IMPL" greenlight-agent-error > "$agent_error_snippet"

if [ ! -s "$agent_error_snippet" ]; then
  fail "could not extract the agent-error block from $IMPL"
  exit 1
fi

exec_dir="$scratch/exec"
mkdir -p "$exec_dir"

TRANSCRIPT_SECRET='transcript-text-do-not-print'
transcript_entries="{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"/w\"},{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"${TRANSCRIPT_SECRET}\"}]}}"
crash_text='API Error: 401 {"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}'
long_error=$(printf 'e%.0s' $(seq 1 2500))

# file contents (or MISSING) | expect an ::error:: | expected message after the prefix | case label
printf '[%s,{"type":"result","subtype":"success","is_error":true,"duration_ms":504,"num_turns":1,"total_cost_usd":0,"result":%s}]' \
  "$transcript_entries" "$(jq -n --arg r "$crash_text" '$r')" > "$exec_dir/crash.json"
printf '[%s,{"type":"result","subtype":"success","is_error":false,"result":"{\\"verdict\\":\\"approve\\"}"}]' \
  "$transcript_entries" > "$exec_dir/clean.json"
printf '[%s,{"type":"result","is_error":true,"result":"first"},{"type":"result","is_error":true,"result":"second"}]' \
  "$transcript_entries" > "$exec_dir/two.json"
printf '[%s,{"type":"result","is_error":true,"result":"50%% done\\r\\nline two\\n::warning::injected"}]' \
  "$transcript_entries" > "$exec_dir/escape.json"
printf '[%s,{"type":"result","is_error":true,"result":"%s"}]' \
  "$transcript_entries" "$long_error" > "$exec_dir/long.json"
printf '[%s,{"type":"result","is_error":true}]' "$transcript_entries" > "$exec_dir/no-text.json"
printf '[%s]' "$transcript_entries" > "$exec_dir/no-result.json"
printf 'not json' > "$exec_dir/garbage.json"

agent_error_cases=(
  "crash.json|yes|${crash_text}|an is_error result"
  "clean.json|||a result without is_error"
  "two.json|yes|second|two result entries, of which the last wins"
  "escape.json|yes|50%25 done%0D%0Aline two%0A::warning::injected|a result with %, CR, LF and a workflow command"
  "long.json|yes|${long_error:0:2000}|a result over 2000 characters"
  "no-text.json|yes|no result text|an is_error result with no text"
  "no-result.json|||no result entry"
  "garbage.json|||an unparseable file"
  "MISSING|||no file at all"
)

for case in "${agent_error_cases[@]}"; do
  IFS='|' read -r file expect_error want label <<<"$case"
  if [ "$file" = MISSING ]; then path="$exec_dir/missing.json"; else path="$exec_dir/$file"; fi

  if out=$(EXECUTION_FILE="$path" SLOT_1=3 bash "$agent_error_snippet" 2>&1); then
    ok "agent-error step exits 0 for ${label}"
  else
    fail "agent-error step exited non-zero for ${label}: ${out}"
  fi

  error_lines=$(grep -c '^::error::' <<<"$out" || true)
  if [ -n "$expect_error" ]; then
    got=$(sed -n 's/^::error::The review agent reported an error (attempt 1, slot 3): //p' <<<"$out")
    if [ "$error_lines" -eq 1 ] && [ "$(wc -l <<<"$out")" -eq 1 ] && [ "$got" = "$want" ]; then
      ok "agent-error step prints one ::error:: with the result text for ${label}"
    else
      fail "agent-error step printed '${out}' for ${label}, expected one ::error:: line ending '${want}'"
    fi
  elif [ "$error_lines" -ne 0 ]; then
    fail "agent-error step printed an ::error:: for ${label}: ${out}"
  else
    ok "agent-error step prints no ::error:: for ${label}"
  fi

  if grep -qF "$TRANSCRIPT_SECRET" <<<"$out"; then
    fail "agent-error step printed transcript text for ${label}"
  fi
done

# Three attempts: each one that reported an error gets its own ::error::,
# naming the attempt and its slot. One that reported none, or did not
# run, prints nothing.
out=$(EXECUTION_FILE="$exec_dir/crash.json" EXECUTION_FILE_2="$exec_dir/clean.json" \
  EXECUTION_FILE_3="$exec_dir/two.json" SLOT_1=4 SLOT_2=1 SLOT_3=2 \
  bash "$agent_error_snippet" 2>&1) || fail "agent-error step exited non-zero for three attempts"
want_1="::error::The review agent reported an error (attempt 1, slot 4): ${crash_text}"
want_3="::error::The review agent reported an error (attempt 3, slot 2): second"
if [ "$(grep -c '^::error::' <<<"$out")" -eq 2 ] && grep -qxF "$want_1" <<<"$out" \
    && grep -qxF "$want_3" <<<"$out"; then
  ok "agent-error step prints one ::error:: per attempt that reported an error"
else
  fail "agent-error step for three attempts printed: ${out}"
fi
if out=$(EXECUTION_FILE='' EXECUTION_FILE_2='' EXECUTION_FILE_3='' bash "$agent_error_snippet" 2>&1) \
    && [ -z "$out" ]; then
  ok "agent-error step prints nothing when no attempt ran"
else
  fail "agent-error step printed '${out}' when no attempt ran"
fi

## 4c. Credential rotation: the classifier, extracted from the YAML and
## executed, and the wiring of the three attempts.

# The three classifier steps run one block, written three times. They
# must not drift: a pattern added to one would rotate on attempt 1 and
# not on attempt 2.
extract_run_block "$IMPL" greenlight-rotate-1 > "$rotate_snippet"
if [ ! -s "$rotate_snippet" ]; then
  fail "could not extract the greenlight-rotate-1 block from $IMPL"
  exit 1
fi
for n in 2 3; do
  if diff -q "$rotate_snippet" <(extract_run_block "$IMPL" "greenlight-rotate-${n}") >/dev/null; then
    ok "classifier block ${n} is word for word classifier block 1"
  else
    fail "classifier block ${n} differs from block 1; the three must be identical:
$(diff "$rotate_snippet" <(extract_run_block "$IMPL" "greenlight-rotate-${n}") || true)"
  fi
done

# Each classifier reads its own attempt and slot, and names the next slot;
# each later attempt runs only on the previous classifier's say-so.
agent_ids=(agent agent_2 agent_3)
for n in 1 2 3; do
  block=$(step_block "Check attempt ${n} for a quota or auth error")
  agent_id=${agent_ids[$((n - 1))]}
  slot="slot_${slot_letters[$((n - 1))]}"
  if [ "$n" -lt 3 ]; then
    next_line="          NEXT_SLOT: \${{ steps.order.outputs.slot_${slot_letters[$n]} }}"
  else
    next_line="          NEXT_SLOT: ''"
  fi
  if grep -qxF "        id: rotate_${n}" <<<"$block" \
     && grep -qxF "          ATTEMPT: '${n}'" <<<"$block" \
     && grep -qxF "          EXECUTION_FILE: \${{ steps.${agent_id}.outputs.execution_file }}" <<<"$block" \
     && grep -qxF "          SLOT: \${{ steps.order.outputs.${slot} }}" <<<"$block" \
     && grep -qxF "$next_line" <<<"$block" \
     && grep -qxF '          DEADLINE: ${{ steps.order.outputs.deadline }}' <<<"$block" \
     && grep -qxF '        continue-on-error: true' <<<"$block"; then
    ok "classifier ${n} reads ${agent_id}'s execution file and ${slot}"
  else
    fail "classifier ${n} must be id rotate_${n}, carry continue-on-error, and read ${agent_id}'s execution file, ${slot}, the next slot and the deadline"
  fi
done
for n in 2 3; do
  want="        if: env.REVIEW_FATAL == '' && steps.rotate_$((n - 1)).outputs.next == 'true'"
  if step_block "Run the review agent (attempt ${n})" | grep -qxF "$want"; then
    ok "attempt ${n} runs only when classifier $((n - 1)) says next=true"
  else
    fail "attempt ${n} must carry '${want# *}'"
  fi
done

rotate_dir="$scratch/rotate"
mkdir -p "$rotate_dir"
result_file() {
  # $1 file name, $2 is_error, $3 result text
  jq -n --argjson e "$2" --arg r "$3" --arg t "$TRANSCRIPT_SECRET" \
    '[{type: "system", subtype: "init"},
      {type: "assistant", message: {content: [{type: "text", text: $t}]}},
      {type: "result", subtype: "success", is_error: $e, result: $r}]' > "$rotate_dir/$1"
}
result_file epoch.json true 'Claude AI usage limit reached|1761955200'
result_file resets.json true "You've hit your weekly limit · resets Nov 3, 5pm (America/New_York)"
result_file session.json true "You've hit your session limit · resets 3pm"
result_file credits.json true "You're out of extra usage · add funds to continue"
result_file auth401.json true "$crash_text"
result_file invalid-key.json true 'Invalid API key · Please run /login'
result_file revoked.json true 'OAuth token revoked · Please run /login'
result_file rate429.json true 'API Error: 429 {"type":"error","error":{"type":"rate_limit_error","message":"Number of request tokens has exceeded your per-minute rate limit"}}'
result_file rejected429.json true 'API Error: Request rejected (429) · this may be a temporary capacity issue.'
result_file model.json true 'API Error: 500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}'
result_file overloaded.json true 'API Error: 529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'
result_file other.json true 'Reached maximum number of turns'
result_file clean.json false '{"verdict":"approve"}'
result_file quota-in-clean.json false "You've hit your weekly limit · resets 5pm"
result_file nasty.json true $'You\'ve hit your limit · resets 5pm%0A\n::error::injected'
printf 'not json' > "$rotate_dir/garbage.json"
cp "$exec_dir/no-result.json" "$rotate_dir/no-result.json"

# Times computed here, so the expectations do not depend on the runner's
# zone.
epoch_text=$(date -u -d @1761955200 '+%Y-%m-%d %H:%M UTC')

# file | slot | next slot | minutes left in the budget | rotate | kind | resets | next | case label
rotate_cases=(
  "epoch.json|3|1|10|true|quota|${epoch_text}|true|a usage limit with an epoch reset"
  "resets.json|1|4|10|true|quota|Nov 3, 5pm (America/New_York)|true|a weekly limit with a resets time"
  "session.json|2|5|10|true|quota|3pm|true|a session limit"
  "credits.json|2|5|10|true|quota|unknown|true|out of extra usage"
  "auth401.json|4|2|10|true|auth|unknown|true|a 401"
  "invalid-key.json|4|2|10|true|auth|unknown|true|an invalid API key"
  "revoked.json|5|1|10|true|auth|unknown|true|a revoked OAuth token"
  "rate429.json|1|2|10|true|quota|unknown|true|a 429 rate_limit_error"
  "rejected429.json|1|2|10|true|quota|unknown|true|a 429 the API rejected"
  "model.json|1|2|10|false||unknown|false|a model error"
  "overloaded.json|1|2|10|false||unknown|false|an overloaded API"
  "other.json|1|2|10|false||unknown|false|an is_error that is not quota or auth"
  "clean.json|1|2|10|false||unknown|false|a clean result"
  "quota-in-clean.json|1|2|10|false||unknown|false|quota text in a result that is not an error"
  "no-result.json|1|2|10|false||unknown|false|no result entry, as after a timeout"
  "garbage.json|1|2|10|false||unknown|false|an unparseable execution file"
  "MISSING|1|2|10|false||unknown|false|no execution file"
  "EMPTY|1|2|10|false||unknown|false|no execution_file output"
  "resets.json|1||10|true|quota|Nov 3, 5pm (America/New_York)|false|a quota error with no slot left"
  "resets.json|1|4|1|true|quota|Nov 3, 5pm (America/New_York)|false|a quota error with under 2 minutes left"
  "resets.json|1|4|0|true|quota|Nov 3, 5pm (America/New_York)|false|a quota error past the deadline"
  "resets.json|key||10|true|quota|Nov 3, 5pm (America/New_York)|false|a quota error on the API key"
  "nasty.json|1|2|10|true|quota|5pm|true|a reset time carrying a workflow command"
)

for case in "${rotate_cases[@]}"; do
  IFS='|' read -r file slot next_slot minutes want_rotate want_kind want_resets want_next label <<<"$case"
  case "$file" in
    MISSING) path="$rotate_dir/missing.json" ;;
    EMPTY) path='' ;;
    *) path="$rotate_dir/$file" ;;
  esac
  rotate_out="$scratch/rotate-out"
  : > "$rotate_out"
  deadline=$(( $(date +%s) + minutes * 60 + 30 ))
  [ "$minutes" = 0 ] && deadline=$(( $(date +%s) - 60 ))

  if out=$(ATTEMPT=1 EXECUTION_FILE="$path" SLOT="$slot" NEXT_SLOT="$next_slot" \
      DEADLINE="$deadline" GITHUB_OUTPUT="$rotate_out" bash "$rotate_snippet" 2>&1); then
    ok "classifier exits 0 for ${label}"
  else
    fail "classifier exited non-zero for ${label}: ${out}"
  fi

  got="$(sed -n 's/^rotate=//p' "$rotate_out")|$(sed -n 's/^kind=//p' "$rotate_out")|$(sed -n 's/^resets=//p' "$rotate_out")|$(sed -n 's/^next=//p' "$rotate_out")"
  want="${want_rotate}|${want_kind}|${want_resets}|${want_next}"
  if [ "$got" = "$want" ]; then
    ok "classifier gives rotate|kind|resets|next = ${want} for ${label}"
  else
    fail "classifier gave '${got}', expected '${want}', for ${label}"
  fi

  if [ "$want_rotate" = true ]; then
    if [ "$slot" = key ]; then who="ANTHROPIC_API_KEY"; else who="slot ${slot}"; fi
    if [ "$want_next" = true ]; then
      then_what="trying slot ${next_slot}"
    elif [ -z "$next_slot" ]; then
      then_what="no slot left to try"
    else
      then_what="no time left to try slot ${next_slot}"
    fi
    want_line="::warning::review credential ${who} hit ${want_kind} (resets ${want_resets}); ${then_what}"
    if [ "$(grep -c '^::' <<<"$out")" -eq 1 ] && grep -qxF "$want_line" <<<"$out"; then
      ok "classifier warns '${want_line#::warning::}' for ${label}"
    else
      fail "classifier printed '${out}' for ${label}, expected the one line '${want_line}'"
    fi
  elif grep -q '^::' <<<"$out"; then
    fail "classifier printed a workflow command for ${label}, which does not rotate: ${out}"
  fi

  # No error text and no transcript text: the agent-error step prints
  # the one, and nothing prints the other.
  if grep -qF "$TRANSCRIPT_SECRET" <<<"$out" || grep -qiE 'api error|invalid api key|maximum number' <<<"$out"; then
    fail "classifier printed the error or transcript text for ${label}: ${out}"
  fi
  if [ "$(grep -c '^rotate=' "$rotate_out")" -ne 1 ] || [ "$(wc -l <"$rotate_out")" -ne 7 ]; then
    fail "classifier wrote other than its seven output lines for ${label}: $(cat "$rotate_out")"
  fi

  # `answered` only for a result entry that is not an error: the API took
  # the slot's token, whatever the result text says.
  case "$file" in
    clean.json|quota-in-clean.json) want_answered=true ;;
    *) want_answered=false ;;
  esac
  if [ "$(sed -n 's/^answered=//p' "$rotate_out")" = "$want_answered" ]; then
    ok "classifier gives answered=${want_answered} for ${label}"
  else
    fail "classifier gave answered '$(sed -n 's/^answered=//p' "$rotate_out")', expected ${want_answered}, for ${label}"
  fi
done

# minutes_left is what attempt 2 or 3 gets as its cap: whole minutes left
# in the budget, never more.
rotate_out="$scratch/rotate-out"
: > "$rotate_out"
ATTEMPT=1 EXECUTION_FILE="$rotate_dir/resets.json" SLOT=1 NEXT_SLOT=2 \
  DEADLINE=$(( $(date +%s) + 7 * 60 + 30 )) GITHUB_OUTPUT="$rotate_out" \
  bash "$rotate_snippet" >/dev/null 2>&1 || true
if [ "$(sed -n 's/^minutes_left=//p' "$rotate_out")" = 7 ]; then
  ok "classifier gives the whole minutes left in the budget"
else
  fail "classifier gave minutes_left '$(sed -n 's/^minutes_left=//p' "$rotate_out")' with 7.5 minutes left, expected 7"
fi

## 4f. The credential slot report: each attempt's execution file run
## through the classifier, and the classifier's outputs through the
## verdict step, both extracted from the YAML.

# The verdict step reads every source of the report from step outputs:
# the guard's set slots and each classifier's rotate, answered, kind and
# reset time.
normalise_block=$(step_block 'Normalise the verdict')
for n in 1 2 3; do
  for pair in "ROTATE:rotate" "ANSWERED:answered" "KIND:kind" "RESETS:resets" "RESETS_EPOCH:resets_epoch"; do
    want="          ${pair%%:*}_${n}: \${{ steps.rotate_${n}.outputs.${pair#*:} }}"
    if ! grep -qxF "$want" <<<"$normalise_block"; then
      fail "the verdict step must read '${want# *}'"
    fi
  done
done
if grep -qxF '          SET_SLOTS: ${{ steps.creds.outputs.slots }}' <<<"$normalise_block"; then
  ok "the verdict step reads the guard's set slots and every classifier output the report needs"
else
  fail "the verdict step must read 'SET_SLOTS: \${{ steps.creds.outputs.slots }}'"
fi
if grep -qxF '      credentials: ${{ steps.verdict.outputs.credentials }}' <<<"$review_block" \
    && grep -qxF '          CREDENTIALS: ${{ needs.review.outputs.credentials }}' <<<"$report_block"; then
  ok "the slot report passes from the review job's outputs to the report job"
else
  fail "the review job must output 'credentials' and the resolve step must read it as CREDENTIALS"
fi

# Set slots | attempts as slot:fixture:step outcome, comma-separated |
# structured output of the last attempt | expected credentials JSON, or
# empty for none | case label
quota_text='Nov 3, 5pm (America/New_York)'
cred_cases=(
  "1 3|1:resets.json:failure,3:clean.json:success|{\"verdict\":\"approve\",\"summary\":\"Fine.\"}|{\"set\":[1,3],\"used\":3,\"exhausted\":[{\"slot\":1,\"kind\":\"quota\",\"resets_at\":null,\"resets_text\":\"${quota_text}\"}]}|slot 1 out of quota, then slot 3 approves"
  "1 2 4 5|4:epoch.json:failure,1:auth401.json:failure,2:session.json:failure||{\"set\":[1,2,4,5],\"used\":null,\"exhausted\":[{\"slot\":4,\"kind\":\"quota\",\"resets_at\":1761955200,\"resets_text\":\"${epoch_text}\"},{\"slot\":1,\"kind\":\"auth\",\"resets_at\":null,\"resets_text\":null},{\"slot\":2,\"kind\":\"quota\",\"resets_at\":null,\"resets_text\":\"3pm\"}]}|all three attempts rotate"
  "1 2|1:resets.json:failure,2:no-result.json:failure||{\"set\":[1,2],\"used\":null,\"exhausted\":[{\"slot\":1,\"kind\":\"quota\",\"resets_at\":null,\"resets_text\":\"${quota_text}\"}]}|slot 1 out of quota, then slot 2 times out with no result"
  "2|2:other.json:failure||{\"set\":[2],\"used\":null,\"exhausted\":[]}|slot 2 ends on an error that is not quota or auth"
  "1 2|2:clean.json:success|{\"verdict\":\"reject\",\"summary\":\"x\\ncredentials={\\\"used\\\":1}\",\"credentials\":{\"used\":1,\"exhausted\":[{\"slot\":1,\"kind\":\"quota\"}]}}|{\"set\":[1,2],\"used\":2,\"exhausted\":[]}|an agent that writes its own credentials"
  "key|key:clean.json:success|{\"verdict\":\"approve\"}||the API key"
)
for case in "${cred_cases[@]}"; do
  IFS='|' read -r set_slots attempts structured want label <<<"$case"
  IFS=',' read -r -a steps <<<"$attempts"
  env_args=("SET_SLOTS=${set_slots}")
  n=0
  for step in "${steps[@]}"; do
    n=$((n + 1))
    IFS=':' read -r slot fixture outcome <<<"$step"
    suffix="_${n}"
    [ "$n" = 1 ] && suffix=''
    rotate_out="$scratch/rotate-out"
    : > "$rotate_out"
    ATTEMPT=$n EXECUTION_FILE="$rotate_dir/$fixture" SLOT="$slot" NEXT_SLOT=9 \
      DEADLINE=$(( $(date +%s) + 600 )) GITHUB_OUTPUT="$rotate_out" \
      bash "$rotate_snippet" >/dev/null 2>&1 || true
    for name in rotate answered kind resets resets_epoch; do
      upper=$(tr '[:lower:]' '[:upper:]' <<<"$name")
      env_args+=("${upper}_${n}=$(sed -n "s/^${name}=//p" "$rotate_out")")
    done
    env_args+=("SLOT_${n}=${slot}" "AGENT_OUTCOME${suffix}=${outcome}" "AGENT_CONCLUSION${suffix}=${outcome}")
    if [ "$n" = "${#steps[@]}" ]; then
      env_args+=("STRUCTURED_OUTPUT${suffix}=${structured}")
    fi
  done

  out="$scratch/cred-normalise"
  : > "$out"
  if ! env -u REVIEW_FATAL "${env_args[@]}" GITHUB_OUTPUT="$out" bash "$verdict_snippet" >/dev/null 2>&1; then
    fail "verdict block exited non-zero for ${label}"
    continue
  fi
  got=$(sed -n 's/^credentials=//p' "$out")
  if [ "$(grep -c '^credentials=' "$out")" -ne 1 ] || [ "$(wc -l <"$out")" -ne 3 ]; then
    fail "verdict block wrote other than its three output lines for ${label}: $(cat "$out")"
  elif [ -z "$want" ] && [ -z "$got" ]; then
    ok "no slot report for ${label}"
  elif [ -n "$want" ] && [ -n "$got" ] && jq -e --argjson want "$want" '. == $want' <<<"$got" >/dev/null 2>&1; then
    ok "slot report for ${label}: ${got}"
  else
    fail "slot report for ${label} is '${got}', expected '${want}'"
  fi
done

## 4d. The git root, extracted from the YAML and executed.

# After the step, the git commands claude-code-action v1.0.226 runs in
# its working directory (src/github/operations/git-config.ts,
# configureGitAuth) must all succeed there. Before the step they fail,
# which the action logged as "Failed to configure git authentication".

extract_run_block "$IMPL" greenlight-git-root > "$git_root_snippet"

if [ ! -s "$git_root_snippet" ]; then
  fail "could not extract the git-root block from $IMPL"
  exit 1
fi

action_git_setup() {
  git config user.name "claude[bot]" \
    && git config user.email "41898282+claude[bot]@users.noreply.github.com" \
    && git remote set-url origin "https://x-access-token:stub@github.com/o/r.git"
}

git_work="$scratch/git-root"
mkdir -p "$git_work/head" "$git_work/base"
if (cd "$git_work" && GIT_CEILING_DIRECTORIES="$scratch" action_git_setup) >/dev/null 2>&1; then
  fail "the action's git setup succeeded in a bare workspace; this check no longer reproduces the exit 128"
else
  ok "the action's git setup fails in a workspace root that is not a repository"
fi

if out=$(cd "$git_work" && ORIGIN_URL=https://github.com/o/r.git \
    GIT_CEILING_DIRECTORIES="$scratch" bash "$git_root_snippet" 2>&1); then
  ok "git-root step exits 0"
else
  fail "git-root step exited non-zero: ${out}"
fi

if (cd "$git_work" && GIT_CEILING_DIRECTORIES="$scratch" action_git_setup) >/dev/null 2>&1; then
  ok "the action's git setup succeeds in the workspace root after the git-root step"
else
  fail "the action's git setup still fails after the git-root step"
fi

# Run twice, as a re-run on a reused workspace would: still exit 0.
if (cd "$git_work" && ORIGIN_URL=https://github.com/o/r.git \
    GIT_CEILING_DIRECTORIES="$scratch" bash "$git_root_snippet") >/dev/null 2>&1; then
  ok "git-root step exits 0 when the root is already a repository"
else
  fail "git-root step exited non-zero when the root is already a repository"
fi

## 4e. The report job's verdict, annotation and job summary, extracted
## from the YAML and executed.

extract_run_block "$IMPL" greenlight-verdict-resolve > "$resolve_snippet"
extract_run_block "$IMPL" greenlight-verdict-annotate > "$annotate_snippet"

for f in "$resolve_snippet" "$annotate_snippet"; do
  if [ ! -s "$f" ]; then
    fail "could not extract $(basename "$f" .sh) from $IMPL"
    exit 1
  fi
done

# review verdict | review summary | expected verdict | conclusion | title | annotation level | word | case label
#
# The summary of an empty verdict is the review job's own. When it is
# empty too, the job went down, and the resolve step names that.
resolve_cases=(
  "approve|Looks good.|approve|success|Approved|notice|approved|an approve"
  "reject|Leaks a key.|reject|neutral|Rejected|warning|rejected|a reject"
  "error|The review agent did not finish.|error|neutral|Errored|warning|errored|an error"
  "||error|neutral|Errored|warning|errored|a review job that went down"
  "Approve|Fine.|error|neutral|Errored|warning|errored|a verdict that is not exact"
)

for case in "${resolve_cases[@]}"; do
  IFS='|' read -r in_verdict in_summary want_verdict want_conclusion want_title level word label <<<"$case"

  work="$scratch/resolve-work"
  rm -rf "$work"
  mkdir -p "$work"
  if ! (cd "$work" && VERDICT="$in_verdict" SUMMARY="$in_summary" REVIEW_RESULT=failure \
      bash "$resolve_snippet" >/dev/null 2>&1); then
    fail "resolve step exited non-zero for ${label}"
    continue
  fi

  got=$(jq -r '[.verdict, .conclusion, .title] | join(" ")' "$work/result.json")
  if [ "$got" = "${want_verdict} ${want_conclusion} ${want_title}" ]; then
    ok "resolve step gives ${got} for ${label}"
  else
    fail "resolve step gave '${got}', expected '${want_verdict} ${want_conclusion} ${want_title}', for ${label}"
  fi

  summary=$(jq -r .summary "$work/result.json")
  if [ -n "$in_summary" ]; then
    want_summary=$in_summary
  else
    want_summary='The review job produced no verdict (job result: failure). It was cancelled or its runner was lost.'
  fi
  if [ "$summary" = "$want_summary" ]; then
    ok "resolve step keeps the summary for ${label}"
  else
    fail "resolve step's summary is '${summary}', expected '${want_summary}', for ${label}"
  fi

  : > "$work/step-summary"
  out=$(cd "$work" && REVIEW_NAME=security GITHUB_STEP_SUMMARY="$work/step-summary" \
    bash "$annotate_snippet" 2>&1) || fail "annotation step exited non-zero for ${label}"
  want_line="::${level} title=Greenlight security%3A ${word}::${want_summary}"
  if [ "$out" = "$want_line" ]; then
    ok "annotation step prints '::${level} title=Greenlight security%3A ${word}' for ${label}"
  else
    fail "annotation step printed '${out}', expected '${want_line}', for ${label}"
  fi
  if grep -qxF "### Greenlight security: ${word}" "$work/step-summary"; then
    ok "job summary names the verdict for ${label}"
  else
    fail "job summary lacks the verdict line for ${label}: $(cat "$work/step-summary")"
  fi
done

# The slot report passes into result.json when it is a JSON object, and
# is left out otherwise. It never changes the verdict.
#
# CREDENTIALS | expected .credentials in result.json, `none` for absent | case label
report='{"set":[1,3],"used":3,"exhausted":[{"slot":1,"kind":"quota","resets_at":null,"resets_text":"5pm"}]}'
resolve_cred_cases=(
  "${report}|${report}|a slot report"
  "|none|no slot report, as with the API key"
  "not json|none|a malformed slot report"
  "[1,2]|none|a slot report that is not an object"
)
for case in "${resolve_cred_cases[@]}"; do
  IFS='|' read -r creds want label <<<"$case"
  work="$scratch/resolve-work"
  rm -rf "$work"
  mkdir -p "$work"
  if ! (cd "$work" && VERDICT=approve SUMMARY=Fine. CREDENTIALS="$creds" REVIEW_RESULT=success \
      bash "$resolve_snippet" >/dev/null 2>&1); then
    fail "resolve step exited non-zero for ${label}"
    continue
  fi
  got=$(jq -c '.credentials // "none"' "$work/result.json")
  [ "$got" = '"none"' ] && got=none
  if [ "$(jq -r .verdict "$work/result.json")" = approve ] \
      && { [ "$got" = "$want" ] || { [ "$want" != none ] && jq -e --argjson w "$want" '.credentials == $w' "$work/result.json" >/dev/null; }; }; then
    ok "resolve step carries credentials=${want} for ${label}"
  else
    fail "resolve step gave credentials '${got}', expected '${want}', for ${label}"
  fi
done

# The escaping. The summary is agent-controlled; the review name comes
# from the repo's config. A `%`, CR or LF must not end the command, and a
# `:` or `,` in the title must not end the property.
work="$scratch/annotate-escape"
rm -rf "$work"
mkdir -p "$work"
nasty_summary=$'50% sure\r\nnext line\n::error::injected, really: yes'
jq -n --arg s "$nasty_summary" \
  '{verdict: "reject", conclusion: "neutral", title: "Rejected", summary: $s}' > "$work/result.json"
: > "$work/step-summary"
out=$(cd "$work" && REVIEW_NAME='a:b,c%d' GITHUB_STEP_SUMMARY="$work/step-summary" bash "$annotate_snippet" 2>&1)
want='::warning title=Greenlight a%3Ab%2Cc%25d%3A rejected::50%25 sure%0D%0Anext line%0A::error::injected, really: yes'
if [ "$out" = "$want" ]; then
  ok "annotation step escapes %, CR and LF in the message, and also : and , in the title"
else
  fail "annotation step printed '${out}', expected '${want}'"
fi
if [ "$(wc -l <<<"$out")" -eq 1 ]; then
  ok "annotation step prints exactly one line for a multi-line summary"
else
  fail "annotation step printed $(wc -l <<<"$out") lines for a multi-line summary"
fi

# The fence. A summary holding a run of N backticks needs a fence of at
# least N+1, or a line of it could close the block and render the rest as
# markdown.
for run in '' '`' '``' '```' '``````'; do
  summary="before ${run} after"$'\n'"${run}"$'\n'"# not a heading"
  jq -n --arg s "$summary" \
    '{verdict: "approve", conclusion: "success", title: "Approved", summary: $s}' > "$work/result.json"
  : > "$work/step-summary"
  (cd "$work" && REVIEW_NAME=security GITHUB_STEP_SUMMARY="$work/step-summary" bash "$annotate_snippet" >/dev/null 2>&1) \
    || fail "annotation step exited non-zero for a summary with a ${#run}-backtick run"
  fence=$(sed -n '3p' "$work/step-summary")
  want_len=$(( ${#run} >= 3 ? ${#run} + 1 : 3 ))
  if [[ "$fence" =~ ^\`+$ ]] && [ "${#fence}" -eq "$want_len" ] \
      && [ "$(tail -1 "$work/step-summary")" = "$fence" ] \
      && [ "$(sed -n '4,$p' "$work/step-summary" | sed '$d')" = "$summary" ]; then
    ok "job summary fences a summary with a ${#run}-backtick run in ${want_len} backticks"
  else
    fail "job summary for a ${#run}-backtick run is wrong:
$(cat "$work/step-summary")"
  fi
done

# No result.json means the resolve step itself failed. Say so, and do not
# fail the job over it.
rm -f "$work/result.json"
if out=$(cd "$work" && REVIEW_NAME=security GITHUB_STEP_SUMMARY="$work/step-summary" bash "$annotate_snippet" 2>&1) \
    && grep -q '^::warning::' <<<"$out"; then
  ok "annotation step warns and exits 0 when no verdict was resolved"
else
  fail "annotation step without result.json printed '${out}'"
fi

# The annotation step is display only, and it must not be able to stop
# the verdict. The check run and the verdict POST run only on
# `success()`, so a failure in an earlier step skips them unless that
# step carries `continue-on-error: true`. A later step that runs on
# `always()` or `!cancelled()` is safe either way.
#
# One line per step in the report job: <name>|<if>|<continue-on-error>.
report_steps=$(printf '%s\n' "$report_block" | awk '
  function flush() { if (name != "") print name "|" cond "|" coe }
  /^      - name: / { flush(); name = $0; sub(/^      - name: /, "", name); cond = ""; coe = ""; next }
  /^        if: / { cond = $0; sub(/^        if: /, "", cond); next }
  /^        continue-on-error: / { coe = $0; sub(/^        continue-on-error: /, "", coe); next }
  END { flush() }
')
annotate_step='Show the verdict on the run page'
annotate_line=$(grep -n "^${annotate_step}|" <<<"$report_steps" | cut -d: -f1 || true)
if [ -z "$annotate_line" ]; then
  fail "the report job has no '${annotate_step}' step"
else
  annotate_coe=$(sed -n "${annotate_line}p" <<<"$report_steps" | cut -d'|' -f3)
  for step in 'Post the check run' 'Send the verdict to Greenlight'; do
    line=$(grep -n "^${step}|" <<<"$report_steps" | cut -d: -f1 || true)
    if [ -z "$line" ]; then
      fail "the report job has no '${step}' step"
      continue
    fi
    cond=$(sed -n "${line}p" <<<"$report_steps" | cut -d'|' -f2)
    if [ "$line" -lt "$annotate_line" ]; then
      ok "'${step}' runs before the annotation step, so the annotation cannot skip it"
    elif [ "$annotate_coe" = "true" ]; then
      ok "the annotation step carries continue-on-error, so it cannot skip '${step}'"
    elif [[ "$cond" == *'always()'* || "$cond" == *'!cancelled()'* ]]; then
      ok "'${step}' runs on '${cond}', so the annotation step cannot skip it"
    else
      fail "a failed '${annotate_step}' step skips '${step}': give the annotation step 'continue-on-error: true', or move it after '${step}'. Otherwise Greenlight gets no verdict and waits out its dispatch timeout"
    fi
  done
fi

## 5. The verdict POST, extracted from the YAML and executed.

# A stub on 127.0.0.1 plays both ends: the Actions token endpoint and
# Greenlight's verdict route, and in section 6 its skip-list route. Each case writes the statuses the route
# answers with, in order; `0` drops the connection with no reply, which
# curl reports as `000`, the same as any network error. The stub logs
# every verdict request it gets, so the case can count the retries and
# read the body that was sent.

extract_run_block "$IMPL" greenlight-verdict-post > "$post_snippet"

if [ ! -s "$post_snippet" ]; then
  fail "could not extract the verdict-post block from $IMPL"
  exit 1
fi

stub_dir="$scratch/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/stub.py" <<'PY'
import http.server, json, os, sys, time, urllib.parse

d = sys.argv[1]
TOKEN = "stub-oidc-token-do-not-print"
VERDICT_URL_PATH = "/api/review-verdicts"

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode() if body is not None else b""
        self.send_response(status)
        if data:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/api/review-credential-slots":
            # The file `slots_reply` holds the status, or `sleep` to answer
            # too late, then the body.
            with open(os.path.join(d, "slot_requests"), "a") as f:
                f.write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization")}) + "\n")
            status, _, body = open(os.path.join(d, "slots_reply")).read().partition("\n")
            if self.headers.get("Authorization") != "Bearer " + TOKEN:
                return self.reply(401, {"error": "bad token", "status": 401})
            if status == "sleep":
                time.sleep(3)
                status = "200"
            data = body.encode()
            try:
                self.send_response(int(status))
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except OSError:
                pass
            return
        want_aud = open(os.path.join(d, "audience")).read()
        if (u.path != "/token"
                or q.get("api-version") != ["2.0"]
                or q.get("audience") != [want_aud]
                or self.headers.get("Authorization") != "Bearer stub-request-token"):
            return self.reply(401, {"message": "bad token request"})
        self.reply(200, {"value": TOKEN})

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n).decode()
        with open(os.path.join(d, "requests"), "a") as f:
            f.write(json.dumps({
                "path": self.path,
                "auth": self.headers.get("Authorization"),
                "body": body,
            }) + "\n")
        statuses = open(os.path.join(d, "statuses")).read().split()
        count = sum(1 for _ in open(os.path.join(d, "requests")))
        status = int(statuses[min(count, len(statuses)) - 1])
        if status == 0:
            self.close_connection = True
            return
        if self.path != VERDICT_URL_PATH:
            return self.reply(404, {"error": "no such route", "status": 404})
        self.reply(status, None if status == 204 else {"error": f"stub error {status}", "status": status})

s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
open(os.path.join(d, "port"), "w").write(str(s.server_address[1]))
s.serve_forever()
PY

: > "$stub_dir/audience"
: > "$stub_dir/statuses"
python3 "$stub_dir/stub.py" "$stub_dir" &
stub_pid=$!
for _ in $(seq 1 50); do
  [ -s "$stub_dir/port" ] && break
  sleep 0.1
done
if [ ! -s "$stub_dir/port" ]; then
  fail "the verdict stub server did not start"
  exit 1
fi
stub="http://127.0.0.1:$(cat "$stub_dir/port")"
verdict_url="$stub/api/review-verdicts"
python3 -c 'import sys, urllib.parse; sys.stdout.write(sys.argv[1])' "$verdict_url" > "$stub_dir/audience"

# Summaries for the cut. LONG has no space at all, so it is cut at 999
# characters. WORDS is 1100 characters of words, so it is cut at the last
# space in its first 1000. EXACT is 1000 characters and is sent whole.
long_summary=$(printf 'é%.0s' $(seq 1 1500))
words_summary=$(printf 'wörd%03d ' $(seq 1 200) | python3 -c 'import sys; print(sys.stdin.read()[:1100], end="")')
exact_summary=$(printf 'abc %.0s' $(seq 1 250))
exact_summary=${exact_summary% }x

# The cut, written again here in Python rather than lifted from the YAML,
# so a mistake in the jq has something independent to disagree with.
expected_cut() {
  python3 -c '
import sys
s = sys.argv[1]
if len(s) > 1000:
    head = s[:1000]
    i = head.rfind(" ")
    cut = head[:i].rstrip(" ") if i >= 0 else ""
    s = (cut or s[:999]) + "\u2026"
print(s, end="")
' "$1"
}

# verdict | summary | statuses | expect exit | expected requests | expected verdict | output must contain | case label
post_cases=(
  "approve|Looks good.|204|0|1|approve|recorded the verdict|an approve, recorded"
  "reject|Leaks a key.|204|0|1|reject|recorded the verdict|a reject, recorded"
  "error|The review agent did not finish.|204|0|1|error|recorded the verdict (error)|an error, recorded"
  "approve|Fine.|409|0|1|approve|::warning::Greenlight did not record the verdict (409): stub error 409|a 409, passed with a warning"
  "approve|Fine.|400|1|1|approve|::error::Greenlight refused the verdict (400): stub error 400|a 400, failing the job"
  "approve|Fine.|401|1|1|approve|(401): stub error 401|a 401, failing the job"
  "approve|Fine.|403|1|1|approve|(403): stub error 403|a 403, failing the job"
  "approve|Fine.|404|1|1|approve|(404): stub error 404|a 404, failing the job"
  "approve|Fine.|503 502 204|0|3|approve|recorded the verdict|two 5xx, then recorded"
  "approve|Fine.|0 204|0|2|approve|recorded the verdict|a dropped connection, then recorded"
  "approve|Fine.|500 500 500 500|1|4|approve|refused the verdict (500)|four 5xx, failing after three retries"
  "approve|Fine.|503 503 503 409|0|4|approve|(409)|three 5xx, then a 409"
  "reject|LONG|204|0|1|reject|recorded the verdict|a summary over 1000 characters with no space"
  "reject|WORDS|204|0|1|reject|recorded the verdict|a summary over 1000 characters of words"
  "error|EXACT|204|0|1|error|recorded the verdict|a summary of exactly 1000 characters"
)

for case in "${post_cases[@]}"; do
  IFS='|' read -r verdict summary statuses expect_exit expect_requests expect_verdict expect_out label <<<"$case"
  case "$summary" in
    LONG) summary=$long_summary ;;
    WORDS) summary=$words_summary ;;
    EXACT) summary=$exact_summary ;;
  esac

  work="$scratch/post-work"
  rm -rf "$work"
  mkdir -p "$work"
  echo "$statuses" > "$stub_dir/statuses"
  : > "$stub_dir/requests"
  jq -n --arg v "$verdict" --arg s "$summary" \
    '{verdict: $v, conclusion: "neutral", title: "t", summary: $s}' > "$work/result.json"

  set +e
  out=$(cd "$work" && VERDICT_URL="$verdict_url" VERDICT_RETRY_DELAY=0 \
    ACTIONS_ID_TOKEN_REQUEST_URL="$stub/token?api-version=2.0" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=stub-request-token \
    bash "$post_snippet" 2>&1)
  status=$?
  set -e

  if [ "$status" -eq "$expect_exit" ]; then
    ok "verdict POST exits ${expect_exit} for ${label}"
  else
    fail "verdict POST exited ${status}, expected ${expect_exit}, for ${label}: ${out}"
  fi

  got_requests=$(wc -l <"$stub_dir/requests")
  if [ "$got_requests" -eq "$expect_requests" ]; then
    ok "verdict POST sent ${expect_requests} request(s) for ${label}"
  else
    fail "verdict POST sent ${got_requests} request(s), expected ${expect_requests}, for ${label}"
  fi

  if grep -qF -- "$expect_out" <<<"$out"; then
    ok "verdict POST log names the outcome for ${label}"
  else
    fail "verdict POST log lacks '${expect_out}' for ${label}: ${out}"
  fi

  # `::add-mask::` is the one line allowed to carry the token: GitHub
  # reads it and masks the value in the rest of the log.
  if grep -v '^::add-mask::' <<<"$out" | grep -qF stub-oidc-token-do-not-print; then
    fail "verdict POST printed the OIDC token for ${label}"
  else
    ok "verdict POST does not print the OIDC token for ${label}"
  fi

  last=$(tail -1 "$stub_dir/requests")
  if [ "$(jq -r .auth <<<"$last")" = "Bearer stub-oidc-token-do-not-print" ]; then
    ok "verdict POST carries the OIDC token as bearer for ${label}"
  else
    fail "verdict POST did not carry the OIDC token as bearer for ${label}"
  fi

  sent=$(jq -r .body <<<"$last")
  want_summary=$(expected_cut "$summary")
  if [ "$(jq -rn --arg s "$summary" '$s | length')" -gt 1000 ] && [[ "$want_summary" != *"…" ]]; then
    fail "the expected summary for ${label} was not cut; the case does not test the cut"
  fi
  if [ "$(jq -r '.verdict' <<<"$sent")" = "$expect_verdict" ] \
      && [ "$(jq -r '.summary' <<<"$sent")" = "$want_summary" ] \
      && [ "$(jq -r 'keys | join(",")' <<<"$sent")" = "summary,verdict" ]; then
    ok "verdict POST sends {verdict: ${expect_verdict}, summary} for ${label}"
  else
    fail "verdict POST sent '${sent}' for ${label}"
  fi

  if [ "$(jq -r '.summary | length' <<<"$sent")" -le 1000 ]; then
    ok "verdict POST sends at most 1000 summary characters for ${label}"
  else
    fail "verdict POST sent a $(jq -r '.summary | length' <<<"$sent")-character summary for ${label}"
  fi
done

# The slot report rides along as `credentials`, and the body stays under
# greenlight's 8 KiB cap. The largest real report (five set slots, three
# exhausted with 60-character reset texts) beside the worst summary the
# cut allows: 1000 control characters that JSON writes as `\u0001`, six
# bytes each. A report big enough to pass the cap is dropped, with a
# warning, and the verdict still goes.
big_text=$(printf 'r%.0s' $(seq 1 60))
max_report=$(jq -cn --arg t "$big_text" '{set: [1,2,3,4,5], used: null,
  exhausted: [range(1; 4) | {slot: ., kind: "quota", resets_at: 1761955200, resets_text: $t}]}')
worst_summary=$(printf '\001%.0s' $(seq 1 1500))
huge_report=$(jq -cn --arg t "$(printf 'z%.0s' $(seq 1 9000))" '{set: [1], used: 1, exhausted: [], pad: $t}')
# summary | credentials | expect credentials sent | case label
cred_post_cases=(
  "Fine.|${report}|yes|a slot report"
  "WORST|${max_report}|yes|the largest slot report beside the worst summary"
  "Fine.|${huge_report}|no|a slot report that would pass 8 KiB"
)
for case in "${cred_post_cases[@]}"; do
  IFS='|' read -r summary creds want_sent label <<<"$case"
  [ "$summary" = WORST ] && summary=$worst_summary
  work="$scratch/post-work"
  rm -rf "$work"
  mkdir -p "$work"
  echo 204 > "$stub_dir/statuses"
  : > "$stub_dir/requests"
  jq -n --arg s "$summary" --argjson c "$creds" \
    '{verdict: "approve", conclusion: "success", title: "t", summary: $s, credentials: $c}' > "$work/result.json"
  set +e
  out=$(cd "$work" && VERDICT_URL="$verdict_url" VERDICT_RETRY_DELAY=0 \
    ACTIONS_ID_TOKEN_REQUEST_URL="$stub/token?api-version=2.0" \
    ACTIONS_ID_TOKEN_REQUEST_TOKEN=stub-request-token \
    bash "$post_snippet" 2>&1)
  status=$?
  set -e
  sent=$(tail -1 "$stub_dir/requests" | jq -r .body)
  bytes=$(printf '%s' "$sent" | wc -c)
  if [ "$status" -ne 0 ] || [ "$(jq -r .verdict <<<"$sent")" != approve ]; then
    fail "verdict POST with ${label} exited ${status} and sent '${sent:0:200}': ${out}"
  elif [ "$bytes" -gt 8192 ]; then
    fail "verdict POST with ${label} sent ${bytes} bytes, over greenlight's 8 KiB cap"
  elif [ "$want_sent" = yes ] && jq -e --argjson c "$creds" '.credentials == $c' <<<"$sent" >/dev/null \
      && [ "$(jq -r 'keys | join(",")' <<<"$sent")" = "credentials,summary,verdict" ]; then
    ok "verdict POST sends {verdict, summary, credentials} in ${bytes} bytes for ${label}"
  elif [ "$want_sent" = no ] && [ "$(jq -r 'keys | join(",")' <<<"$sent")" = "summary,verdict" ] \
      && grep -qF '::warning::the verdict body is over 8 KiB' <<<"$out"; then
    ok "verdict POST drops the slot report, warns and still sends the verdict for ${label}"
  else
    fail "verdict POST with ${label} sent '${sent:0:300}' (${bytes} bytes): ${out}"
  fi
done

# No token permission: the job fails, names the missing permission, and
# sends nothing.
work="$scratch/post-work"
: > "$stub_dir/requests"
set +e
out=$(cd "$work" && VERDICT_URL="$verdict_url" VERDICT_RETRY_DELAY=0 bash "$post_snippet" 2>&1)
status=$?
set -e
if [ "$status" -ne 0 ] && grep -qF "id-token: write" <<<"$out" && [ ! -s "$stub_dir/requests" ]; then
  ok "verdict POST fails and names id-token: write when no token can be had"
else
  fail "verdict POST without a token source exited ${status} and sent $(wc -l <"$stub_dir/requests") request(s): ${out}"
fi

# An empty verdict_url sends nothing and passes. The step's `if:` skips
# it in CI already; this is the block's own guard.
: > "$stub_dir/requests"
if out=$(cd "$work" && VERDICT_URL='' bash "$post_snippet" 2>&1) && [ ! -s "$stub_dir/requests" ]; then
  ok "verdict POST with an empty verdict_url sends nothing and exits 0"
else
  fail "verdict POST with an empty verdict_url did something: ${out}"
fi

## 6. The credential skip list, extracted from the YAML and executed.

# The `slots` job asks the stub's skip-list route at the verdict URL's
# origin, with an OIDC token for the verdict URL's audience, and writes
# `skip` as the slot numbers ordered by `skip_until`. Every failure gives
# an empty `skip` and one warning, and the step always exits 0.

extract_run_block "$IMPL" greenlight-credential-slots > "$slots_snippet"
if [ ! -s "$slots_snippet" ]; then
  fail "could not extract the credential-slots block from $IMPL"
  exit 1
fi

two_entries='{"skip":[{"slot":4,"kind":"auth","skip_until":"2026-11-04T09:00:00Z"},{"slot":1,"kind":"quota","skip_until":"2026-11-03T17:00:00Z"}]}'
junk_entries='{"skip":[{"slot":9,"kind":"quota","skip_until":"2026-11-03T17:00:00Z"},{"slot":"2"},{"slot":1.5},"slot 3",{"slot":5,"kind":"quota\n::error::x","skip_until":"2026-11-05T00:00:00Z"},{"slot":5,"kind":"auth","skip_until":"2026-11-06T00:00:00Z"}]}'
# reply status, or `sleep` | reply body | token source | expected skip | warns | case label
slots_cases=(
  "200|${two_entries}|yes|1 4|no|two entries, ordered by skip_until"
  '200|{"skip":[]}|yes||no|an empty skip list'
  '404|{"error":"no such run","status":404}|yes||yes|a 404'
  '503|{"error":"down","status":503}|yes||yes|a 503'
  'sleep|{"skip":[{"slot":2,"kind":"quota","skip_until":"2026-11-03T17:00:00Z"}]}|yes||yes|a reply after the timeout'
  '200|not json|yes||yes|a body that is not JSON'
  "200|${junk_entries}|yes|5|no|entries that are not slots, and a repeat"
  "200|${two_entries}|no||yes|no OIDC token"
)
for case in "${slots_cases[@]}"; do
  IFS='|' read -r reply body token want warns label <<<"$case"
  work="$scratch/slots-work"
  rm -rf "$work"
  mkdir -p "$work"
  printf '%s\n%s' "$reply" "$body" > "$stub_dir/slots_reply"
  : > "$stub_dir/slot_requests"
  : > "$work/output"
  token_env=()
  if [ "$token" = yes ]; then
    token_env=(ACTIONS_ID_TOKEN_REQUEST_URL="$stub/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=stub-request-token)
  fi
  started=$(date +%s)
  set +e
  out=$(cd "$work" && env "${token_env[@]}" VERDICT_URL="$verdict_url" SLOTS_FETCH_MAX_TIME=1 \
    GITHUB_OUTPUT="$work/output" bash "$slots_snippet" 2>&1)
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    fail "slots step exited ${status} for ${label}: ${out}"
    continue
  fi
  if [ "$(cat "$work/output")" = "skip=${want}" ]; then
    ok "slots step gives skip='${want}' for ${label}"
  else
    fail "slots step wrote '$(cat "$work/output")', expected 'skip=${want}', for ${label}"
  fi
  warnings=$(grep -c '^::warning::' <<<"$out" || true)
  if { [ "$warns" = yes ] && [ "$warnings" -eq 1 ]; } || { [ "$warns" = no ] && [ "$warnings" -eq 0 ]; }; then
    ok "slots step prints ${warnings} warning(s) for ${label}"
  else
    fail "slots step printed ${warnings} warning(s) for ${label}, expected warns=${warns}: ${out}"
  fi
  if grep -v '^::add-mask::' <<<"$out" | grep -qF stub-oidc-token-do-not-print \
      || grep -c '^::' <<<"$out" | grep -qvE '^[0-2]$' || grep -q '^::error::' <<<"$out"; then
    fail "slots step printed the token or a stray workflow command for ${label}: ${out}"
  fi
  if [ "$(( $(date +%s) - started ))" -gt 4 ]; then
    fail "slots step took more than 4 seconds for ${label}: it must honour the curl time limit"
  fi
  if [ "$token" = yes ]; then
    requests=$(wc -l <"$stub_dir/slot_requests")
    if [ "$requests" -eq 1 ] \
        && [ "$(jq -r .path "$stub_dir/slot_requests")" = /api/review-credential-slots ] \
        && [ "$(jq -r .auth "$stub_dir/slot_requests")" = "Bearer stub-oidc-token-do-not-print" ]; then
      ok "slots step sends one GET with the OIDC token to the verdict URL's origin for ${label}"
    else
      fail "slots step sent ${requests} request(s) for ${label}: $(cat "$stub_dir/slot_requests")"
    fi
  elif [ -s "$stub_dir/slot_requests" ]; then
    fail "slots step asked greenlight without a token for ${label}"
  fi
done

if grep -qxF 'skipping slots 1 4 (greenlight: slot 1 quota until 2026-11-03T17:00:00Z; slot 4 auth until 2026-11-04T09:00:00Z); the review tries them last' \
    <<<"$(cd "$work" && printf '200\n%s' "$two_entries" > "$stub_dir/slots_reply" \
      && ACTIONS_ID_TOKEN_REQUEST_URL="$stub/token?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN=stub-request-token \
      VERDICT_URL="$verdict_url" GITHUB_OUTPUT=/dev/null bash "$slots_snippet" 2>&1)"; then
  ok "slots step logs the slots it skips and until when"
else
  fail "slots step does not log 'skipping slots 1 4 (greenlight: …)'"
fi

# No verdict_url: no request, no warning, an empty skip list. The job's
# `if:` skips it in CI already; this is the block's own guard.
: > "$stub_dir/slot_requests"
: > "$work/output"
out=$(cd "$work" && VERDICT_URL='' GITHUB_OUTPUT="$work/output" bash "$slots_snippet" 2>&1) || true
if [ "$(cat "$work/output")" = "skip=" ] && [ ! -s "$stub_dir/slot_requests" ] && ! grep -q '^::' <<<"$out"; then
  ok "slots step with an empty verdict_url asks nothing and gives an empty skip list"
else
  fail "slots step with an empty verdict_url did something: ${out}"
fi

kill "$stub_pid" 2>/dev/null || true
wait "$stub_pid" 2>/dev/null || true
stub_pid=

echo
if [ "$failures" -eq 0 ]; then
  echo "all review-workflow checks passed"
else
  echo "${failures} check(s) failed" >&2
  exit 1
fi
