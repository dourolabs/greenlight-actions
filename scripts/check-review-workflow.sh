#!/usr/bin/env bash
# Verify the greenlight AI review workflows without a live dispatch.
#
# Six things nothing else catches:
#
#  1. The permission split. The `review` job must not be able to post a
#     check run; the `report` job must. And the caller job has to grant
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
#  4. The verdict normalisation. Anything that is not an exact `approve`
#     must resolve to `reject`.
#  5. The two conclusions the `report` job posts. A reject posts
#     `neutral` so it stays out of the PR's status roll-up; `failure`
#     is the obvious-looking value that reddens it, and the regression
#     is invisible everywhere else because greenlight blocks the merge
#     either way.
#  6. That the `review` job never exits non-zero. Greenlight dispatches
#     the caller on the PR's *base branch*, and GitHub hangs a run's
#     check suite off the dispatched ref's tip commit — so a failed
#     `review` job puts a red X on the consumer's `main`. Every known
#     failure mode has to resolve to a rejecting verdict instead, which
#     means no step exits non-zero, every fallible step carries
#     `continue-on-error: true`, and the guards record their cause in
#     `REVIEW_FATAL`. `exit 1` reads like the obvious way to handle a
#     missing credential, so this is pinned structurally as well as
#     behaviourally.
#
# (3), (4) and (6) all work the same way: the shell block is lifted out
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

# The four shell blocks lifted out of the YAML further down, and one
# trap for all of them: a second `trap ... EXIT` would replace the first
# and leak.
guard_snippet=$(mktemp)
prompt_snippet=$(mktemp)
preflight_snippet=$(mktemp)
verdict_snippet=$(mktemp)
scratch=$(mktemp -d)
trap 'rm -rf "$guard_snippet" "$prompt_snippet" "$preflight_snippet" "$verdict_snippet" "$scratch"' EXIT

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

if grep -q '^    secrets: inherit$' "$CALLER"; then
  ok "caller inherits secrets"
else
  fail "caller must pass 'secrets: inherit' so the org-level credential reaches the reusable workflow"
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

for perm in 'contents: read' 'checks: write'; do
  if grep -qF "      ${perm}" <<<"$caller_review_block"; then
    ok "caller job grants ${perm}"
  else
    fail "caller job must grant '${perm}': a caller grants a ceiling, and one that grants less than the impl's jobs request makes GitHub refuse to start the run"
  fi
done

# The example is what every consumer installs, so its `uses:` has to name
# this repository at the published major tag. `@main` would repoint every
# consumer on every push here, with no opt-in on their side.
if grep -qF '    uses: dourolabs/greenlight-actions/.github/workflows/greenlight-review-impl.yml@v1' "$CALLER"; then
  ok "caller calls this repository's impl at @v1"
else
  fail "caller must call 'dourolabs/greenlight-actions/.github/workflows/greenlight-review-impl.yml@v1'"
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

if printf '%s\n' "$report_block" | grep -q '^      checks: write$'; then
  ok "report job declares checks: write"
else
  fail "report job must declare 'checks: write'"
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
# the two checkouts, the preflight check, and the agent.
continue_on_error=$(printf '%s\n' "$review_block" | grep -c '^        continue-on-error: true$' || true)
if [ "$continue_on_error" -ge 6 ]; then
  ok "every fallible step in the review job carries continue-on-error (${continue_on_error})"
else
  fail "only ${continue_on_error} step(s) in the review job carry 'continue-on-error: true', expected at least 6: the credential guard, both checkouts, the prompt step, the preflight check and the agent. Without it a failing step fails the job, which reddens the base branch's tip commit"
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
  else
    if [ "$fatal_lines" -eq 0 ]; then
      ok "preflight check records nothing for ${label}"
    else
      fail "preflight check overwrote or invented a REVIEW_FATAL for ${label}: $(cat "$env_file")"
    fi
  fi
done

## 4. The verdict normalisation, extracted from the YAML and executed.

extract_run_block "$IMPL" greenlight-verdict-normalise > "$verdict_snippet"

if [ ! -s "$verdict_snippet" ]; then
  fail "could not extract the verdict-normalisation block from $IMPL"
  exit 1
fi

# structured_output | agent step outcome | agent conclusion | REVIEW_FATAL | expected verdict | case label
#
# Two independent signals now have to say the agent got there: the step's
# own `outcome`, which is `failure` when the agent crashed or ran past
# its cap and `skipped` when a guard stopped it running at all, and the
# action's `conclusion`. REVIEW_FATAL is the fourth field: a guard
# upstream caught a known failure, wrote down why, and let the job carry
# on green. Every one of those is a reject.
cases=(
  '{"verdict":"approve","summary":"Looks good."}|success|success||approve|a clean approve'
  '{"verdict":"reject","summary":"Leaks a key."}|success|success||reject|a clean reject'
  '|success|success||reject|empty output'
  'not json at all|success|success||reject|unparseable output'
  '{}|success|success||reject|no verdict field'
  'null|success|success||reject|a null document'
  '{"verdict":null}|success|success||reject|a null verdict'
  '{"verdict":true}|success|success||reject|a non-string verdict'
  '{"verdict":"Approve"}|success|success||reject|approve in the wrong case'
  '{"verdict":" approve"}|success|success||reject|approve with leading space'
  '{"verdict":"approve, obviously"}|success|success||reject|approve as a substring'
  '{"verdict":"approve"}|success|failure||reject|approve from an agent that did not finish'
  '{"verdict":"approve"}|success|||reject|approve with no agent conclusion at all'
  '{"verdict":"approve","summary":"one\ntwo"}|success|success||approve|a multi-line summary'
  '{"verdict":"reject","summary":"MULTIBYTE"}|success|success||reject|a long multi-byte summary'
  '{"verdict":"reject","summary":"nope\nverdict=approve"}|success|success||reject|a summary smuggling a second verdict line'
  '{"verdict":"approve","summary":"Fine."}|failure|success||reject|an approve from a step that failed'
  '{"verdict":"approve","summary":"Fine."}|cancelled|success||reject|an approve from a step that was cancelled'
  '{"verdict":"approve","summary":"Fine."}||||reject|an approve with no step outcome at all'
  '|skipped|||reject|an agent that never ran'
  '|skipped||No credential was set.|reject|a guard-recorded credential failure'
  '{"verdict":"approve","summary":"Stale."}|skipped||Prompt file is missing.|reject|a stale approve behind a guard-recorded failure'
)

# A summary long enough to hit the 900-character cap, padded with a
# three-byte character so a byte-wise truncation would leave the value
# invalid UTF-8 and break the JSON the report job builds from it. The
# leading ASCII byte matters: it puts the 900-byte boundary inside a
# character rather than neatly between two.
long_multibyte="x$(printf '→%.0s' $(seq 1 1200))"

for case in "${cases[@]}"; do
  IFS='|' read -r payload outcome conclusion fatal expected label <<<"$case"
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

  # A guard's diagnostic is the whole reason for catching the failure
  # instead of failing the job, so it has to survive to the check run —
  # including past a stale structured_output that would otherwise win.
  if [ -n "$fatal" ]; then
    got_summary=$(grep '^summary=' "$out" | tail -1 | cut -d= -f2-)
    if [ "$got_summary" = "$fatal" ]; then
      ok "summary is the guard's diagnostic for ${label}"
    else
      fail "summary is '${got_summary}', expected the guard's '${fatal}', for ${label}"
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

echo
if [ "$failures" -eq 0 ]; then
  echo "all review-workflow checks passed"
else
  echo "${failures} check(s) failed" >&2
  exit 1
fi
