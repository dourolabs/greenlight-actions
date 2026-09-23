#!/usr/bin/env bash
# Verify the greenlight AI review workflows without a live dispatch.
#
# Four things nothing else catches:
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
#
# (3) and (4) both work the same way: the shell block is lifted out of
# the shipped YAML by its `greenlight-*:begin`/`:end` markers and run
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

# The two shell blocks lifted out of the YAML further down, and one trap
# for both: a second `trap ... EXIT` would replace the first and leak.
guard_snippet=$(mktemp)
verdict_snippet=$(mktemp)
trap 'rm -f "$guard_snippet" "$verdict_snippet"' EXIT

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

# api key | oauth token | expected exit | case label
credential_cases=(
  "|||neither credential set"
  "${SENTINEL_KEY}||0|only the API key"
  "|${SENTINEL_TOKEN}|0|only the OAuth token"
  "${SENTINEL_KEY}|${SENTINEL_TOKEN}||both credentials set"
)

for case in "${credential_cases[@]}"; do
  IFS='|' read -r key token expected_ok label <<<"$case"

  if out=$(ANTHROPIC_API_KEY="$key" CLAUDE_CODE_OAUTH_TOKEN="$token" \
      bash "$guard_snippet" 2>&1); then
    status=0
  else
    status=1
  fi

  if [ "$status" -eq 0 ] && [ -n "$expected_ok" ]; then
    ok "guard admits ${label}"
  elif [ "$status" -ne 0 ] && [ -z "$expected_ok" ]; then
    if printf '%s' "$out" | grep -q '^::error::'; then
      ok "guard rejects ${label} with an ::error::"
    else
      fail "guard rejected ${label} without an ::error:: annotation"
    fi
    for name in "${CREDENTIALS[@]}"; do
      if ! printf '%s' "$out" | grep -qF "$name"; then
        fail "guard's error for ${label} does not name ${name}"
      fi
    done
    # The pointer has to resolve for a reader outside dourolabs, which is
    # the whole reason this repository is public.
    if ! printf '%s' "$out" | grep -qF "$POINTER"; then
      fail "guard's error for ${label} does not point at ${POINTER}"
    fi
  elif [ "$status" -eq 0 ]; then
    fail "guard admitted ${label}; it must fail"
  else
    fail "guard rejected ${label}; it must admit it"
  fi

  # Whatever it printed, it must not have printed a credential.
  for value in "$SENTINEL_KEY" "$SENTINEL_TOKEN"; do
    if printf '%s' "$out" | grep -qF "$value"; then
      fail "guard echoed a credential value for ${label}"
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

## 4. The verdict normalisation, extracted from the YAML and executed.

extract_run_block "$IMPL" greenlight-verdict-normalise > "$verdict_snippet"

if [ ! -s "$verdict_snippet" ]; then
  fail "could not extract the verdict-normalisation block from $IMPL"
  exit 1
fi

# structured_output | conclusion | expected verdict | case label
cases=(
  '{"verdict":"approve","summary":"Looks good."}|success|approve|a clean approve'
  '{"verdict":"reject","summary":"Leaks a key."}|success|reject|a clean reject'
  '|success|reject|empty output'
  'not json at all|success|reject|unparseable output'
  '{}|success|reject|no verdict field'
  'null|success|reject|a null document'
  '{"verdict":null}|success|reject|a null verdict'
  '{"verdict":true}|success|reject|a non-string verdict'
  '{"verdict":"Approve"}|success|reject|approve in the wrong case'
  '{"verdict":" approve"}|success|reject|approve with leading space'
  '{"verdict":"approve, obviously"}|success|reject|approve as a substring'
  '{"verdict":"approve"}|failure|reject|approve from an agent that did not finish'
  '{"verdict":"approve"}||reject|approve with no agent conclusion at all'
  '{"verdict":"approve","summary":"one\ntwo"}|success|approve|a multi-line summary'
  '{"verdict":"reject","summary":"MULTIBYTE"}|success|reject|a long multi-byte summary'
  '{"verdict":"reject","summary":"nope\nverdict=approve"}|success|reject|a summary smuggling a second verdict line'
)

# A summary long enough to hit the 900-character cap, padded with a
# three-byte character so a byte-wise truncation would leave the value
# invalid UTF-8 and break the JSON the report job builds from it. The
# leading ASCII byte matters: it puts the 900-byte boundary inside a
# character rather than neatly between two.
long_multibyte="x$(printf '→%.0s' $(seq 1 1200))"

for case in "${cases[@]}"; do
  IFS='|' read -r payload conclusion expected label <<<"$case"
  payload=${payload/MULTIBYTE/$long_multibyte}

  out=$(mktemp)
  if ! STRUCTURED_OUTPUT="$payload" AGENT_CONCLUSION="$conclusion" GITHUB_OUTPUT="$out" \
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
