#!/usr/bin/env bash
# Verify the greenlight AI review workflows without a live dispatch.
#
# Nine things nothing else catches:
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
#  3. The agent credentials. Either secret authenticates the agent, both
#     reach the action, and the guard that enforces "exactly one" runs
#     before the checkouts.
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
#     sits in a fence no backtick run in it can close.
#
# (3), (4) and (6) to (9) all work the same way: the shell block is lifted out
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
agent_error_snippet="$scratch/agent-error.sh"
git_root_snippet="$scratch/git-root.sh"
resolve_snippet="$scratch/resolve.sh"
annotate_snippet="$scratch/annotate.sh"
post_snippet="$scratch/post.sh"
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
# declared_inputs, but secret names are upper case.
declared_secrets() {
  awk '
    /^    secrets:$/ { inside = 1; next }
    inside && /^      [A-Z_]+:$/ { sub(/:$/, "", $1); print $1; next }
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

for name in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
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

if printf '%s\n' "$review_block" | grep -q '^      contents: read$'; then
  ok "review job declares contents: read"
else
  fail "review job must declare 'contents: read'"
fi

if printf '%s\n' "$review_block" | grep -qE '^      (checks|pull-requests|issues|actions|contents): write$'; then
  fail "review job declares a write permission; an injected agent could use it"
else
  ok "review job declares no write permission"
fi

# `id-token: write` is how a job mints the OIDC token Greenlight accepts
# a verdict with. The agent reads untrusted input, so the job it runs in
# must never hold it.
if printf '%s\n' "$review_block" | grep -q '^ *id-token:'; then
  fail "review job declares id-token; an injected agent could mint the token Greenlight accepts a verdict with"
else
  ok "review job declares no id-token permission"
fi

if printf '%s\n' "$report_block" | grep -q '^      checks: write$'; then
  ok "report job declares checks: write"
else
  fail "report job must declare 'checks: write'"
fi

if printf '%s\n' "$report_block" | grep -q '^      id-token: write$'; then
  ok "report job declares id-token: write"
else
  fail "report job must declare 'id-token: write': it mints the token the verdict POST carries"
fi

if printf '%s\n' "$report_block" | grep -qF "        if: \${{ inputs.verdict_url != '' }}"; then
  ok "verdict POST step runs only when verdict_url is set"
else
  fail "the verdict POST step must be gated on 'if: \${{ inputs.verdict_url != '' }}', so an empty verdict_url behaves as v1 did"
fi

if printf '%s\n' "$report_block" | grep -q '^    needs: review$'; then
  ok "report job needs review"
else
  fail "report job must declare 'needs: review'"
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
if printf '%s\n' "$report_block" | grep -q '^            conclusion=neutral$'; then
  ok "report job posts conclusion=neutral on a reject"
else
  fail "report job must post 'conclusion=neutral' on a reject: 'failure' reddens the PR's status roll-up and 'neutral' does not. See README.md, 'Why a reject posts neutral'"
fi

if printf '%s\n' "$report_block" | grep -q '^            conclusion=failure$'; then
  fail "report job posts 'conclusion=failure'; that reddens the PR's status roll-up, which is what the neutral reject exists to avoid. See README.md, 'Why a reject posts neutral'"
else
  ok "report job never posts conclusion=failure"
fi

if printf '%s\n' "$report_block" | grep -q '^            conclusion=success$'; then
  ok "report job posts conclusion=success on an approve"
else
  fail "report job must post 'conclusion=success' on an approve"
fi

# The conclusion went neutral; the title is what still tells the human
# the review rejected, because it is what GitHub renders beside the
# check name in the merge box.
if printf '%s\n' "$report_block" | grep -q '^            title="Rejected"$'; then
  ok "report job still titles a reject \"Rejected\""
else
  fail "report job must keep 'title=\"Rejected\"' on a reject: with the conclusion now neutral, the title is the only thing that shows the human the review rejected"
fi

if printf '%s\n' "$report_block" | grep -q '^            title="Errored"$'; then
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

if printf '%s\n' "$review_block" | grep -qE '^ *exit [1-9]'; then
  fail "the review job exits non-zero somewhere; that reddens the base branch's tip commit in every consuming repository, because this workflow is dispatched on the base ref. Record the cause in REVIEW_FATAL and 'exit 0' instead — see README.md, 'Why the review job stays green'"
else
  ok "no step in the review job exits non-zero"
fi

# Every step that can fail on its own: the two guards that run a script,
# the two checkouts, the preflight check, the git root, the agent and the
# step that prints the agent's error.
continue_on_error=$(printf '%s\n' "$review_block" | grep -c '^        continue-on-error: true$' || true)
if [ "$continue_on_error" -ge 8 ]; then
  ok "every fallible step in the review job carries continue-on-error (${continue_on_error})"
else
  fail "only ${continue_on_error} step(s) in the review job carry 'continue-on-error: true', expected at least 8: the credential guard, both checkouts, the prompt step, the preflight check, the git root, the agent and the agent's error. Without it a failing step fails the job, which reddens the base branch's tip commit"
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

# The agent's cap has to be a *step* timeout. A step that overruns fails,
# and a failed step is already a reject; a job that overruns is cancelled
# and cannot be caught from inside the job.
agent_block=$(printf '%s\n' "$review_block" | awk '
  /^      - name: Run the review agent$/ { inside = 1 }
  inside && /^      - name: / && ++seen > 1 { inside = 0 }
  inside { print }
')

if printf '%s\n' "$agent_block" | grep -qE '^        timeout-minutes: [0-9]+$'; then
  ok "the agent step carries its own timeout-minutes"
else
  fail "the agent step must carry its own 'timeout-minutes': the job-level cap cancels the job, and a cancelled job cannot turn itself into a reject"
fi

if printf '%s\n' "$agent_block" | grep -q '^        continue-on-error: true$'; then
  ok "the agent step carries continue-on-error"
else
  fail "the agent step must carry 'continue-on-error: true'; an agent that crashes or overruns would otherwise fail the job and redden the base branch's tip commit"
fi

# The step cap has to leave the job cap room to run the verdict step, and
# both have to stay under greenlight's 20-minute dispatch timeout.
agent_timeout=$(printf '%s\n' "$agent_block" | sed -n 's/^        timeout-minutes: \([0-9]*\)$/\1/p' | head -1)
job_timeout=$(printf '%s\n' "$review_block" | sed -n 's/^    timeout-minutes: \([0-9]*\)$/\1/p' | head -1)
if [ -n "$agent_timeout" ] && [ -n "$job_timeout" ] \
   && [ "$agent_timeout" -lt "$job_timeout" ] && [ "$job_timeout" -lt 20 ]; then
  ok "agent cap (${agent_timeout}m) < review job cap (${job_timeout}m) < greenlight's 20m dispatch timeout"
else
  fail "the agent step's timeout (${agent_timeout:-none}) must be under the review job's (${job_timeout:-none}), which must be under greenlight's 20-minute dispatch timeout"
fi

# `report` must run even when `review` did not succeed. `needs:` alone
# skips it, and a skipped report posts nothing at all — the PR then waits
# out greenlight's dispatch timeout with no reason to read.
if printf '%s\n' "$report_block" | grep -qF '!cancelled()'; then
  ok "report job runs even when review did not succeed"
else
  fail "report job must declare 'if: \${{ !cancelled() }}': with a bare 'needs: review' a review job that goes down skips report entirely and nothing is posted"
fi

## 3. The agent credentials — either secret works, exactly one at a time.

CREDENTIALS=(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN)
EXPECTED_SECRETS=$(printf '%s\n' "${CREDENTIALS[@]}" | sort)

got_secrets=$(declared_secrets "$IMPL")
if [ "$got_secrets" = "$EXPECTED_SECRETS" ]; then
  ok "impl declares exactly the two credential secrets"
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
  fail "impl marks a credential secret 'required: true'; that locks out the other one"
else
  ok "impl marks neither credential secret required"
fi

# Both reach the action. An unset secret renders empty and the action
# treats empty as absent, so this is unconditional on purpose — see the
# comment on the step.
for name in "${CREDENTIALS[@]}"; do
  input=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  if printf '%s\n' "$review_block" | grep -qF "          ${input}: \${{ secrets.${name} }}"; then
    ok "agent step is passed ${name}"
  else
    fail "agent step must pass '${input}: \${{ secrets.${name} }}'"
  fi
done

# The guard has to run before the checkouts: a credential mistake should
# cost zero clones.
guard_line=$(printf '%s\n' "$review_block" | grep -n 'greenlight-credential-guard:end' | head -1 | cut -d: -f1)
checkout_line=$(printf '%s\n' "$review_block" | grep -n 'uses: actions/checkout' | head -1 | cut -d: -f1)
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
# the secrets and never print one.
SENTINEL_KEY='sk-ant-SENTINELKEY'
SENTINEL_TOKEN='sk-ant-oat-SENTINELTOKEN'

# api key | oauth token | admits? | case label
#
# The two bad combinations used to `exit 1`. They now exit 0 and record
# the cause in REVIEW_FATAL instead, because a failed step fails the job
# and the job's check run sits on the base branch's tip commit in the
# consuming repository. The diagnostic the old exit bought — an
# `::error::` naming both secrets and pointing at the README — is still
# asserted, and the REVIEW_FATAL line is what turns the mistake into a
# rejecting check run on the PR.
credential_cases=(
  "|||neither credential set"
  "${SENTINEL_KEY}||yes|only the API key"
  "|${SENTINEL_TOKEN}|yes|only the OAuth token"
  "${SENTINEL_KEY}|${SENTINEL_TOKEN}||both credentials set"
)

for case in "${credential_cases[@]}"; do
  IFS='|' read -r key token admits label <<<"$case"

  env_file="$scratch/guard-env"
  : > "$env_file"

  if out=$(ANTHROPIC_API_KEY="$key" CLAUDE_CODE_OAUTH_TOKEN="$token" \
      GITHUB_ENV="$env_file" bash "$guard_snippet" 2>&1); then
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

  if [ -n "$admits" ]; then
    if [ "$fatal_lines" -eq 0 ]; then
      ok "guard admits ${label}"
    else
      fail "guard recorded a REVIEW_FATAL for ${label}; it must admit it"
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

    fatal=$(sed -n 's/^REVIEW_FATAL=//p' "$env_file")
    fatal_gives_error "$fatal" "the credential guard's ${label}"

    if printf '%s' "$out" | grep -q '^::error::'; then
      ok "guard annotates ${label} with an ::error::"
    else
      fail "guard did not annotate ${label} with an ::error::"
    fi
    for name in "${CREDENTIALS[@]}"; do
      if ! printf '%s' "$out" | grep -qF "$name"; then
        fail "guard's error for ${label} does not name ${name}"
      fi
      if ! printf '%s' "$fatal" | grep -qF "$name"; then
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
  for value in "$SENTINEL_KEY" "$SENTINEL_TOKEN"; do
    if printf '%s' "$out" | grep -qF "$value"; then
      fail "guard echoed a credential value for ${label}"
    fi
    if grep -qF "$value" "$env_file"; then
      fail "guard recorded a credential value in REVIEW_FATAL for ${label}"
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

# creds outcome | prompt outcome | REVIEW_FATAL already set | expect a REVIEW_FATAL written | case label
#
# An empty outcome counts as a failure: the `if:` expressions always
# populate these in CI, so an empty one means something the workflow does
# not model, and a reject is the fail-safe reading of that.
preflight_cases=(
  "success|success|||both steps succeeded"
  "failure|skipped||yes|the credential guard died unexpectedly"
  "success|failure||yes|the prompt step died unexpectedly"
  "success|cancelled||yes|the prompt step was cancelled"
  "|||yes|no outcomes at all"
  "failure|skipped|Already diagnosed.||an earlier guard already recorded a cause"
  "success|success|Already diagnosed.||a recorded cause with everything green"
)

for case in "${preflight_cases[@]}"; do
  IFS='|' read -r creds prompt preset expect_write label <<<"$case"

  env_file="$scratch/preflight-env"
  : > "$env_file"

  run_preflight() {
    if [ -n "$preset" ]; then
      REVIEW_FATAL="$preset" CREDS_OUTCOME="$creds" PROMPT_OUTCOME="$prompt" \
        GITHUB_ENV="$env_file" bash "$preflight_snippet" 2>&1
    else
      CREDS_OUTCOME="$creds" PROMPT_OUTCOME="$prompt" \
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
  if [ "$(grep -c '^verdict=' "$out")" -ne 1 ] || [ "$(wc -l <"$out")" -ne 2 ]; then
    fail "verdict block wrote more than the two expected output lines for ${label}"
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

  if out=$(EXECUTION_FILE="$path" bash "$agent_error_snippet" 2>&1); then
    ok "agent-error step exits 0 for ${label}"
  else
    fail "agent-error step exited non-zero for ${label}: ${out}"
  fi

  error_lines=$(grep -c '^::error::' <<<"$out" || true)
  if [ -n "$expect_error" ]; then
    got=$(sed -n 's/^::error::The review agent reported an error: //p' <<<"$out")
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

## 4c. The git root, extracted from the YAML and executed.

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

## 4d. The report job's verdict, annotation and job summary, extracted
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

## 5. The verdict POST, extracted from the YAML and executed.

# A stub on 127.0.0.1 plays both ends: the Actions token endpoint and
# Greenlight's verdict route. Each case writes the statuses the route
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
import http.server, json, os, sys, urllib.parse

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
