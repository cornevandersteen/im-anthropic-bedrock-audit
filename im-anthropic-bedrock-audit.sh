#!/usr/bin/env bash
# CloudShell compatibility: if invoked with `sh script.sh`, re-run in Bash.
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
#
# Ingram Micro Amazon Bedrock Audit Script
# Investigates missing Anthropic model access or quota problems despite an
# Anthropic reselling agreement provided by Ingram Micro.
#
# Copyright (c) 2026 Tobias Tomandl / Ingram Micro
# Version: 0.21
#
# Behavior:
# - No configuration changes are made.
# - Read-only by default: no model is invoked unless --invoke is passed.
# - Automatically inventories all Anthropic Bedrock models returned by AWS.
# - Reads Anthropic FTU/use-case, access states, quotas and quota request history.
# - With --invoke: if model access is READY and a matching runtime TPM quota is
#   > 0, performs a tiny runtime invocation. This can create minimal Bedrock
#   usage/cost. By default (EU scope) only EU inference profiles are tested;
#   --global additionally tests Global inference profiles.
# - Produces EXACTLY ONE output file: the complete terminal transcript as the
#   report. All intermediate data (raw JSON, working TSVs) is kept in a
#   temporary directory and removed on exit. No subfolder is left behind.
#

set -u
export AWS_PAGER=""

VERSION="0.21"
PROFILE=""
REGION="eu-central-1"
# Read-only by default: the runtime test (which invokes models and can create
# minimal Bedrock cost) is OFF unless --invoke is passed.
INVOKE="false"
# When invoking, the runtime test probes ONLY EU inference profiles by default.
# Pass --global to additionally probe Global inference profiles (one row/scope).
TEST_GLOBAL="false"

# Partner/customer are requested only at the end for naming the report file.
PARTNER=""
CUSTOMER=""

usage() {
cat <<EOF
Ingram Micro Amazon Bedrock Audit Script v${VERSION}

Usage:
  $0 [--profile NAME] [--region REGION] [--invoke] [--global]

Options:
  --profile NAME       AWS CLI profile. If omitted, current CloudShell/session
                       credentials are offered first, then named profiles.
  --region REGION      Default: eu-central-1
  --invoke             Run the automatic runtime test. This invokes models and
                       can create minimal Bedrock usage/cost. Off by default
                       (the audit is read-only unless this flag is set).
  --global             With --invoke, also test Global inference profiles.
                       Default tests EU inference profiles only.
  -h, --help           Show help.
EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }

short(){
  local s="${1:-}" n="${2:-70}"
  [[ ${#s} -gt $n ]] && printf "%s..." "${s:0:$n}" || printf "%s" "$s"
}

num_gt_zero(){
  local v="${1:-0}"
  [[ "$v" != "-" && "$v" != "None" && "$v" != "null" && -n "$v" ]] || return 1
  awk -v x="$v" 'BEGIN { exit !(x+0 > 0) }'
}

quota_value_for_model(){
  # Args: <scope-prefix-regex> <human-model-name> <quota-tsv>
  # Matches the model name exactly enough to avoid:
  #   "Claude Sonnet 4" accidentally matching "Claude Sonnet 4.5"
  #   "Claude Opus 5" accidentally matching "Claude Opus 5.5"
  local scope_re="$1"
  local model_name="$2"
  local quota_file="$3"

  awk -F'\t' -v scope="$scope_re" -v name="$model_name" '
    BEGIN {
      lname=tolower(name)
    }
    {
      q=$2
      lq=tolower(q)

      if (q !~ scope) next

      pos=index(lq,lname)
      if (pos==0) next

      # Character immediately after matched model name.
      nextc=substr(lq,pos+length(lname),1)

      # Exact model boundary: end-of-string or a non digit/dot character.
      # This permits "Claude Opus 4.6 V1" but rejects "Claude Opus 4.6" -> "4.6x"
      # and, critically, rejects "Claude Sonnet 4" matching "Claude Sonnet 4.5".
      if (nextc=="" || nextc !~ /[0-9.]/) {
        print $3
        exit
      }
    }
  ' "$quota_file"
}

safe_name(){
  printf "%s" "$1" \
    | tr ' ' '_' \
    | tr -cd '[:alnum:]_.-'
}

# Minimal raw-data note: report that data was captured, without storing it.
# Prints one line with byte size and line count of a temporary raw file.
# Args: <label> <file>
raw_note(){
  local label="$1" file="$2"
  if [[ -s "$file" ]]; then
    local bytes lines
    bytes="$(wc -c < "$file" | tr -d ' ')"
    lines="$(wc -l < "$file" | tr -d ' ')"
    echo "      [raw] ${label}: ${bytes} bytes, ${lines} lines captured (not stored)"
  else
    echo "      [raw] ${label}: no data captured"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --region) REGION="${2:-}"; shift 2 ;;
    --invoke) INVOKE="true"; shift ;;
    --global) TEST_GLOBAL="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Capture the COMPLETE console transcript from the very beginning.
TMP_REPORT="$(mktemp "${TMPDIR:-/tmp}/im-anthropic-bedrock-audit.XXXXXX")" || exit 1

# Preserve a handle to the real terminal BEFORE redirecting stdout/stderr into
# the tee pipe. Interactive prompts are written to this FD (TTY_FD) so they go
# to the screen only and never pollute the report transcript. If there is no
# controlling terminal (e.g. piped/non-interactive), fall back to stderr.
if [ -e /dev/tty ] && exec 3>/dev/tty 2>/dev/null; then
  TTY_FD=3
else
  TTY_FD=2
fi

exec > >(tee -a "$TMP_REPORT") 2>&1

# All intermediate data (raw JSON responses, working TSVs) is kept in ONE
# temporary directory and removed on exit. The script produces exactly one
# output file: the final report. No subfolder is left behind.
WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/im-anthropic-bedrock-work.XXXXXX")" || exit 1
cleanup(){
  rm -rf "$WORKDIR" 2>/dev/null
  rm -f "${PROFILE_FILE:-}" 2>/dev/null
}
trap cleanup EXIT

cat <<EOF

==============================================================================
  Ingram Micro Amazon Bedrock Audit Script
  Investigates missing Anthropic model access or quota problems despite an
  Anthropic reselling agreement provided by Ingram Micro.
  Version ${VERSION}
  Copyright (c) 2026 Tobias Tomandl / Ingram Micro
==============================================================================

EOF

echo "[0/8] PRE-FLIGHT"
command -v aws >/dev/null 2>&1 || {
  echo "  [FAIL] AWS CLI not installed or not in PATH."
  echo "         Install AWS CLI v2 and run the script again."
  exit 1
}
AWS_VERSION="$(aws --version 2>&1)"
echo "  [ OK ] $AWS_VERSION"
echo "  [ OK ] bash ${BASH_VERSION:-unknown}"

# AWS CLI wrapper.
# Do NOT use an empty Bash array here: macOS still ships Bash 3.2, and with
# `set -u` expanding an empty array can terminate the script as "unbound variable".
# CloudShell can use its ambient temporary credentials; local runs can use a profile.
awsx() {
  if [[ -n "${PROFILE:-}" ]]; then
    command aws --profile "$PROFILE" "$@"
  else
    command aws "$@"
  fi
}

PROFILE_FILE="$(mktemp "${TMPDIR:-/tmp}/im-anthropic-bedrock-profiles.XXXXXX")" || exit 1
aws configure list-profiles 2>/dev/null | sed '/^[[:space:]]*$/d' > "$PROFILE_FILE"
PROFILE_COUNT="$(wc -l < "$PROFILE_FILE" | tr -d ' ')"

AMBIENT_OK="false"
if command aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1; then
  AMBIENT_OK="true"
fi

CREDENTIAL_SOURCE=""

if [[ -n "$PROFILE" ]]; then
  CREDENTIAL_SOURCE="AWS profile: $PROFILE"
else
  if [[ "$AMBIENT_OK" == "true" ]]; then
    echo
    echo "  Available credential sources:"
    echo "     1) Current AWS session / CloudShell credentials"

    if [[ "${PROFILE_COUNT:-0}" -gt 0 ]]; then
      N=2
      while IFS= read -r PNAME; do
        printf "    %2d) AWS profile: %s\n" "$N" "$PNAME"
        N=$((N+1))
      done < "$PROFILE_FILE"
    fi
    echo

    MAX_CHOICE=$((PROFILE_COUNT + 1))
    while true; do
      read -r -p "  Select credentials [1-${MAX_CHOICE}] (default 1): " N
      N="${N:-1}"
      if [[ "$N" =~ ^[0-9]+$ ]] && ((N>=1 && N<=MAX_CHOICE)); then
        if ((N == 1)); then
          PROFILE=""
          CREDENTIAL_SOURCE="Current AWS session / CloudShell"
        else
          LINE=$((N-1))
          PROFILE="$(sed -n "${LINE}p" "$PROFILE_FILE")"
          CREDENTIAL_SOURCE="AWS profile: $PROFILE"
        fi
        break
      fi
      echo "  Invalid selection."
    done
  else
    if [[ "${PROFILE_COUNT:-0}" -le 0 ]]; then
      echo
      echo "  [FAIL] No usable current AWS session and no AWS CLI profiles found."
      echo "         In CloudShell, refresh/reopen the shell and try again."
      rm -f "$PROFILE_FILE"
      exit 1
    fi

    echo
    echo "  Available AWS profiles:"
    N=1
    while IFS= read -r PNAME; do
      printf "    %2d) %s\n" "$N" "$PNAME"
      N=$((N+1))
    done < "$PROFILE_FILE"
    echo

    while true; do
      read -r -p "  Select profile [1-${PROFILE_COUNT}]: " N
      if [[ "$N" =~ ^[0-9]+$ ]] && ((N>=1 && N<=PROFILE_COUNT)); then
        PROFILE="$(sed -n "${N}p" "$PROFILE_FILE")"
        CREDENTIAL_SOURCE="AWS profile: $PROFILE"
        break
      fi
      echo "  Invalid selection."
    done
  fi
fi

rm -f "$PROFILE_FILE"
echo
echo "[1/8] ACCOUNT"
IDJSON="$(awsx sts get-caller-identity --region "$REGION" --output json 2>&1)" || {
  echo "  [FAIL] Authentication failed."
  echo "         Credential source: $CREDENTIAL_SOURCE"
  echo "$IDJSON"
  if [[ -n "$PROFILE" ]]; then
    echo "  For SSO try: aws sso login --profile \"$PROFILE\""
  fi
  exit 1
}

ACCOUNT_ID="$(awsx sts get-caller-identity --region "$REGION" --query Account --output text)"
CALLER_ARN="$(awsx sts get-caller-identity --region "$REGION" --query Arn --output text)"
# Timestamps in UTC. TS is the compact yyyymmddhhmmss form shown on the display
# lines (which carry a "UTC" label). TS_FILE separates date and time with a
# dash (yyyymmdd-hhmmss) for a more readable report filename. TS_FILE is derived
# from TS (not a second `date` call) so both always refer to the same instant.
TS="$(date -u +'%Y%m%d%H%M%S')"
TS_FILE="${TS:0:8}-${TS:8:6}"
# Intermediate files live in the temporary WORKDIR (removed on exit).
OUT="$WORKDIR"

printf "  %-12s %s\n" "Account:" "$ACCOUNT_ID"
printf "  %-12s %s\n" "Credentials:" "$CREDENTIAL_SOURCE"
printf "  %-12s %s\n" "Region:" "$REGION"
printf "  %-12s %s\n" "Caller:" "$CALLER_ARN"
printf "  %-12s %s UTC\n" "Timestamp:" "$TS"

printf '%s\n' "$IDJSON" > "$OUT/01-sts-identity.json"

PROVIDER="Anthropic"

echo
echo "[2/8] FOUNDATION MODEL INVENTORY"
echo "      Dynamic AWS inventory - no hard-coded model versions."

MODEL_TSV="$OUT/10-model-inventory.tsv"
: > "$MODEL_TSV"

P="$PROVIDER"

awsx bedrock list-foundation-models \
  --by-provider "$P" \
  --region "$REGION" \
  --output json \
  > "$OUT/10-anthropic-foundation-models.json" \
  2> "$OUT/10-anthropic-foundation-models-error.txt" || true
raw_note "list-foundation-models" "$OUT/10-anthropic-foundation-models.json"

echo
echo "  Anthropic"
printf "  %-30s  %-45s  %-10s\n" "MODEL" "MODEL ID" "LIFECYCLE"
printf "  %-30s  %-45s  %-10s\n" \
  "------------------------------" \
  "---------------------------------------------" \
  "----------"

awsx bedrock list-foundation-models \
  --by-provider "Anthropic" \
  --region "$REGION" \
  --query 'modelSummaries[*].[modelName,modelId,modelLifecycle.status]' \
  --output text 2>/dev/null |
while IFS=$'\t' read -r NAME MID LIFE; do
  [[ -z "${MID:-}" ]] && continue
  printf "  %-30s  %-45s  %-10s\n" "$NAME" "$MID" "$LIFE"
  printf "Anthropic\t%s\t%s\t%s\n" "$NAME" "$MID" "$LIFE" >> "$MODEL_TSV"
done

echo
echo "[3/8] SYSTEM INFERENCE PROFILES"

awsx bedrock list-inference-profiles \
  --type-equals SYSTEM_DEFINED \
  --region "$REGION" \
  \
  --output json \
  > "$OUT/11-system-inference-profiles.json" \
  2> "$OUT/11-system-inference-profiles-error.txt" || true
raw_note "list-inference-profiles" "$OUT/11-system-inference-profiles.json"

PROFILE_TSV="$OUT/11-provider-inference-profiles.tsv"
: > "$PROFILE_TSV"

echo
echo "  Anthropic"
printf "  %-52s  %-52s  %-8s\n" "PROFILE NAME" "PROFILE ID" "STATUS"
printf "  %-52s  %-52s  %-8s\n" \
  "----------------------------------------------------" \
  "----------------------------------------------------" \
  "--------"

awsx bedrock list-inference-profiles \
  --type-equals SYSTEM_DEFINED \
  --region "$REGION" \
  --query "inferenceProfileSummaries[?contains(inferenceProfileId, '.anthropic.')].[inferenceProfileName,inferenceProfileId,status]" \
  --output text 2>/dev/null |
while IFS=$'\t' read -r N PID S; do
  [[ -z "${PID:-}" ]] && continue
  printf "  %-52s  %-52s  %-8s\n" "$N" "$PID" "$S"
  printf "Anthropic\t%s\t%s\t%s\n" "$N" "$PID" "$S" >> "$PROFILE_TSV"
done

echo
echo "[4/8] ANTHROPIC FTU / USE CASE"

FTU="N/A"
FTU_DATE="UNKNOWN"

  FTU_RAW="$OUT/20-anthropic-use-case.json"
  FTU_ERR="$OUT/20-anthropic-use-case-error.txt"
  FTU_DECODED="$OUT/21-anthropic-use-case-decoded.json"

  if awsx bedrock get-use-case-for-model-access \
      --region "$REGION" \
      \
      --output json \
      > "$FTU_RAW" \
      2> "$FTU_ERR"; then

    FTU="PRESENT"
    echo "  [ OK ] Stored Anthropic use-case returned."

    # Decode formData robustly. With AWS CLI the blob can appear with more than
    # one Base64 layer, so try repeated decoding until valid JSON is reached.
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$FTU_RAW" "$FTU_DECODED" <<'PY'
import sys, json, base64, binascii

src, dst = sys.argv[1], sys.argv[2]

try:
    outer = json.load(open(src, encoding="utf-8"))
except Exception:
    raise SystemExit(2)

value = outer.get("formData")
if value is None:
    raise SystemExit(3)

if isinstance(value, bytes):
    current = value
else:
    current = str(value).encode("utf-8")

parsed = None
decoded_text = None

# First check whether the value is already JSON, then try up to 3 Base64 layers.
for depth in range(4):
    try:
        txt = current.decode("utf-8").strip()
    except Exception:
        txt = ""

    if txt:
        try:
            candidate = json.loads(txt)
            if isinstance(candidate, dict):
                parsed = candidate
                decoded_text = txt
                break
        except Exception:
            pass

    if depth == 3:
        break

    try:
        # Add missing Base64 padding if required.
        padded = current + b"=" * ((4 - len(current) % 4) % 4)
        current = base64.b64decode(padded, validate=False)
    except (binascii.Error, ValueError):
        break

if parsed is None:
    raise SystemExit(4)

with open(dst, "w", encoding="utf-8") as f:
    json.dump(parsed, f, indent=2, ensure_ascii=False)
PY
      DECODE_RC=$?
    else
      DECODE_RC=127
    fi

    if [[ ${DECODE_RC:-1} -eq 0 && -s "$FTU_DECODED" ]]; then
      python3 - "$FTU_DECODED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
users = {
    "0": "Internal",
    "1": "External",
    "2": "Internal + External"
}
print("  Company:        " + str(d.get("companyName", "-")))
print("  Website:        " + str(d.get("companyWebsite", "-")))
print("  Intended users: " + users.get(str(d.get("intendedUsers", "")),
                                      str(d.get("intendedUsers", "-"))))
print("  Industry:       " + str(d.get("industryOption", "-")))
other = d.get("otherIndustryOption", "")
if other:
    print("  Other industry: " + str(other))
use_case = str(d.get("useCases", "-")).replace("\n", " ").strip()
print("  Use case:")
if len(use_case) <= 500:
    print("    " + use_case)
else:
    print("    " + use_case[:500] + "...")
PY
    else
      echo "  [WARN] Use-case exists, but formData could not be decoded as JSON."
    fi

    # Best-effort submission/update timestamp:
    # GetUseCaseForModelAccess itself has no timestamp. CloudTrail Event History
    # can expose PutUseCaseForModelAccess if the event is still retained in this region.
    CT_FILE="$OUT/22-anthropic-use-case-cloudtrail.json"
    if awsx cloudtrail lookup-events \
        --lookup-attributes AttributeKey=EventName,AttributeValue=PutUseCaseForModelAccess \
        --region "$REGION" \
        \
        --max-results 50 \
        --output json \
        > "$CT_FILE" \
        2> "$OUT/22-anthropic-use-case-cloudtrail-error.txt"; then

      if command -v python3 >/dev/null 2>&1; then
        FTU_DATE="$(python3 - "$CT_FILE" <<'PY'
import json, sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
    events=d.get("Events", [])
    if not events:
        print("UNKNOWN")
    else:
        events=sorted(events, key=lambda x: x.get("EventTime", ""), reverse=True)
        print(events[0].get("EventTime", "UNKNOWN"))
except Exception:
    print("UNKNOWN")
PY
)"
      fi
    fi

    if [[ -n "$FTU_DATE" && "$FTU_DATE" != "UNKNOWN" ]]; then
      echo "  Last PutUseCase event: $FTU_DATE"
      echo "  Timestamp source:      CloudTrail Event History ($REGION)"
    else
      FTU_DATE="UNKNOWN"
      echo "  Last PutUseCase event: UNKNOWN"
      echo "  Timestamp note:        Bedrock GetUseCase has no date; no retained"
      echo "                         PutUseCase CloudTrail event was found in $REGION."
    fi

  else
    FTU="NOT FOUND / NOT READABLE"
    echo "  [WARN] $FTU"
    tail -n 1 "$FTU_ERR" 2>/dev/null | sed 's/^/         /'
  fi

  echo
  echo "  Note:"
  echo "    GetUseCaseForModelAccess reads the currently stored use case."
  echo "    PutUseCaseForModelAccess can update it; this audit never modifies it."
  echo "    For a single-end-customer Organization, an Organization-level use case"
  echo "    can be appropriate. Mixed-customer Organizations should be checked"
  echo "    account-by-account rather than assuming one generic use case is enough."
echo
echo "[5/8] MODEL ACCESS / AVAILABILITY"
echo "      Availability is read from the base model (account + region) and is"
echo "      scope-independent: it is NOT split into EU vs Global here. The"
echo "      EU/Global distinction applies to inference profiles - see the"
echo "      profile list in [3/8] and the per-scope runtime test in [7/8]."
echo "      REGION below is the API's regionAvailability for the base model,"
echo "      not an EU-vs-Global indicator."
echo

printf "  %-10s %-28s %-13s %-12s %-12s %-12s %-12s\n" \
  "PROVIDER" "MODEL" "AGREEMENT" "AUTH" "ENTITLEMENT" "REGION" "RESULT"
printf "  %-10s %-28s %-13s %-12s %-12s %-12s %-12s\n" \
  "----------" "----------------------------" "-------------" "------------" "------------" "------------" "------------"

ACCESS_TSV="$OUT/30-model-access.tsv"
: > "$ACCESS_TSV"

while IFS=$'\t' read -r P NAME MID LIFE; do
  [[ -z "${MID:-}" ]] && continue
  SAFE="$(printf "%s" "$MID" | tr '/:.' '___')"

  # One API call per model. A multi-field JMESPath query returns AGREEMENT /
  # AUTH / ENTITLEMENT / REGION as a single tab-separated line. Previously this
  # made five separate calls per model, which was slow and increased the risk
  # of API throttling. No python3 dependency is needed here.
  AVAIL_ERR="$OUT/30-availability-${SAFE}-error.txt"
  AVAIL_LINE="$(awsx bedrock get-foundation-model-availability \
    --model-id "$MID" \
    --region "$REGION" \
    --query '[agreementAvailability.status, authorizationStatus, entitlementAvailability, regionAvailability]' \
    --output text \
    2> "$AVAIL_ERR")"
  AVAIL_RC=$?

  if [[ $AVAIL_RC -eq 0 ]]; then
    IFS=$'\t' read -r AGR AUT ENT REG <<< "$AVAIL_LINE"

    # Normalize empty/None fields to "-" so the table stays aligned.
    [[ -z "$AGR" || "$AGR" == None ]] && AGR="-"
    [[ -z "$AUT" || "$AUT" == None ]] && AUT="-"
    [[ -z "$ENT" || "$ENT" == None ]] && ENT="-"
    [[ -z "$REG" || "$REG" == None ]] && REG="-"

    RESULT="READY"
    [[ "$AGR" != AVAILABLE ]] && RESULT="AGREEMENT"
    [[ "$AUT" != AUTHORIZED ]] && RESULT="AUTH"
    [[ "$ENT" != AVAILABLE ]] && RESULT="ENTITLEMENT"
    [[ "$REG" != AVAILABLE ]] && RESULT="REGION"
  else
    AGR="-"; AUT="-"; ENT="-"; REG="-"; RESULT="API ERROR"
  fi

  printf "  %-10s %-28s %-13s %-12s %-12s %-12s %-12s\n" \
    "$P" "$(short "$NAME" 28)" "$AGR" "$AUT" "$ENT" "$REG" "$RESULT"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$P" "$NAME" "$MID" "$LIFE" "$AGR" "$AUT" "$ENT" "$REG" "$RESULT" \
    >> "$ACCESS_TSV"
done < "$MODEL_TSV"

echo
echo "[6/8] RELEVANT RUNTIME QUOTAS"
echo "      Full quota names are printed without truncation."

awsx service-quotas list-service-quotas \
  --service-code bedrock \
  --region "$REGION" \
  \
  --output json \
  > "$OUT/40-applied-bedrock-quotas.json" \
  2> "$OUT/40-applied-bedrock-quotas-error.txt" || true

awsx service-quotas list-aws-default-service-quotas \
  --service-code bedrock \
  --region "$REGION" \
  \
  --output json \
  > "$OUT/41-default-bedrock-quotas.json" \
  2> "$OUT/41-default-bedrock-quotas-error.txt" || true

Q="$OUT/40-anthropic-runtime-quotas.tsv"
: > "$Q"

QUERY="Quotas[?(contains(QuotaName, 'tokens per minute') || contains(QuotaName, 'requests per minute')) && (contains(QuotaName, 'Anthropic') || contains(QuotaName, 'Claude'))].[QuotaCode,QuotaName,Value]"

awsx service-quotas list-service-quotas \
  --service-code bedrock \
  --region "$REGION" \
  \
  --query "$QUERY" \
  --output text 2>/dev/null |
while IFS=$'\t' read -r CODE NAME ACTUAL; do
  [[ -z "${CODE:-}" ]] && continue

  DEF="$(awsx service-quotas get-aws-default-service-quota \
    --service-code bedrock \
    --quota-code "$CODE" \
    --region "$REGION" \
    \
    --query 'Quota.Value' \
    --output text 2>/dev/null || true)"

  [[ -z "$DEF" || "$DEF" == None ]] && DEF="-"
  printf "%s\t%s\t%s\t%s\n" "$CODE" "$NAME" "$ACTUAL" "$DEF" >> "$Q"
done

while IFS=$'\t' read -r CODE NAME ACTUAL DEF; do
  A="$(printf "%s" "$ACTUAL" | sed -E 's/\.0$//')"
  D="$(printf "%s" "$DEF" | sed -E 's/\.0$//')"

  echo
  printf "  %-12s  Actual: %-12s  Default: %-12s\n" "$CODE" "$A" "$D"
  echo "               $NAME"
done < "$Q"

echo
echo "[7/8] AUTOMATIC RUNTIME TEST"
echo "      Off by default (read-only). Enable with --invoke; then runs only"
echo "      when ACCESS=READY and a matching TPM quota is > 0."
if [[ "$TEST_GLOBAL" == "true" ]]; then
  echo "      Scope: EU and Global inference profiles (--global). One row per"
  echo "             scope that has a profile and a TPM quota > 0."
else
  echo "      Scope: EU inference profiles only (default). Use --global to also"
  echo "             test Global inference profiles."
fi
echo "      Skip reasons: SKIP/<STATE> = access not READY; SKIP/QUOTA0 = a"
echo "      dedicated TPM quota exists but is 0; SKIP/NO-QUOTA = no dedicated"
echo "      cross-region TPM quota exists for this model (often LEGACY models);"
echo "      SKIP/NO-EU = no EU inference profile with a TPM quota > 0 (default"
echo "      scope; the model may still be reachable via Global with --global)."
echo "      RETENTION-REQ = model is a covered model that requires an"
echo "      account-wide data retention opt-in before it can be invoked."
echo "      This audit does not change that setting; enable it separately."
echo

RUNTIME_TSV="$OUT/50-runtime-tests.tsv"
: > "$RUNTIME_TSV"

# Runs one runtime probe for a given scope and prints one table row.
# Args: <provider> <model-name> <scope-label> <inference-profile-id>
# May set the global RETENTION_SEEN flag and appends to RUNTIME_TSV.
run_probe(){
  local P="$1" NAME="$2" SCOPE="$3" TEST_ID="$4"
  local SAFE RESP ERR RC E ERROR_SUMMARY RESULT

  SAFE="$(printf "%s" "$TEST_ID" | tr '/:.' '___')"
  RESP="$OUT/50-runtime-${SAFE}.json"
  ERR="$OUT/50-runtime-${SAFE}-error.txt"

  # Only maxTokens is set. The `temperature` parameter is intentionally NOT
  # sent: newer Anthropic models (Opus 4.7/4.8, Opus 5, Sonnet 5, Fable) reject
  # it with "`temperature` is deprecated for this model", and it adds no value
  # to a minimal availability probe.
  awsx bedrock-runtime converse \
    --model-id "$TEST_ID" \
    --messages '[{"role":"user","content":[{"text":"Reply exactly with: OK"}]}]' \
    --inference-config '{"maxTokens":8}' \
    --region "$REGION" \
    --output json \
    > "$RESP" 2> "$ERR"
  RC=$?

  ERROR_SUMMARY=""
  if [[ $RC -eq 0 ]]; then
    RESULT="OK"
  else
    E="$(tr '\n' ' ' < "$ERR" | sed 's/[[:space:]]\+/ /g' | sed 's/^ *//;s/ *$//')"
    ERROR_SUMMARY="$(short "$E" 180)"

    if printf "%s" "$E" | grep -qiE \
      "data retention|retention mode"; then
      # Covered models (e.g. Claude Fable) require an account-wide data
      # retention opt-in before they can be invoked; 'default' is rejected.
      # This audit does NOT change configuration, so we only flag it.
      RESULT="RETENTION-REQ"
    elif printf "%s" "$E" | grep -qiE \
      "not supported|unsupported|does not support|not available for this api"; then
      RESULT="API-N/A"
    elif printf "%s" "$E" | grep -qiE \
      "AccessDenied|not authorized|not available for this account|registration is incomplete|entitlement"; then
      RESULT="ACCESS-FAIL"
    elif printf "%s" "$E" | grep -qiE \
      "Throttl|TooManyRequests|quota|rate"; then
      RESULT="THROTTLED"
    else
      RESULT="FAILED"
    fi
  fi

  printf "  %-10s %-28s %-10s %-48s %-14s\n" \
    "$P" "$(short "$NAME" 28)" "$SCOPE" "$(short "$TEST_ID" 48)" "$RESULT"

  if [[ "$RESULT" == "RETENTION-REQ" ]]; then
    # Just the codeword in the table; the explanatory note is printed once
    # after the table. Do not print the raw ValidationException per row.
    RETENTION_SEEN="true"
  elif [[ -n "$ERROR_SUMMARY" ]]; then
    echo "               Error: $ERROR_SUMMARY"
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$P" "$NAME" "$SCOPE" "$TEST_ID" "$RESULT" "$ERROR_SUMMARY" >> "$RUNTIME_TSV"
}

if [[ "$INVOKE" != "true" ]]; then
  echo "  Runtime tests are disabled by default (read-only)."
  echo "  Pass --invoke to run them (this invokes models and can create"
  echo "  minimal Bedrock usage/cost)."
else
  printf "  %-10s %-28s %-10s %-48s %-14s\n" \
    "PROVIDER" "MODEL" "SCOPE" "PROFILE / MODEL ID" "RESULT"
  printf "  %-10s %-28s %-10s %-48s %-14s\n" \
    "----------" "----------------------------" "----------" \
    "------------------------------------------------" "--------------"

  # Set to "true" if any model reports RETENTION-REQ; a single explanatory note
  # is then printed once after the table (not per row). The loop reads from a
  # file (not a pipe), so it runs in the current shell and this flag persists.
  RETENTION_SEEN="false"

  while IFS=$'\t' read -r P NAME MID LIFE AGR AUT ENT REG ACCESS; do
    [[ "$ACCESS" == "READY" ]] || {
      printf "  %-10s %-28s %-10s %-48s %-14s\n" \
        "$P" "$(short "$NAME" 28)" "-" "-" "SKIP/$ACCESS"
      printf "%s\t%s\t-\t-\tSKIP/%s\n" "$P" "$NAME" "$ACCESS" >> "$RUNTIME_TSV"
      continue
    }

    EU_PID="$(awk -F'\t' -v p="$P" -v mid="eu.${MID}" \
      '$1==p && $3==mid {print $3; exit}' "$PROFILE_TSV")"
    GL_PID="$(awk -F'\t' -v p="$P" -v mid="global.${MID}" \
      '$1==p && $3==mid {print $3; exit}' "$PROFILE_TSV")"

    MATCH_NAME="$NAME"

    EU_QUOTA="$(quota_value_for_model "^Cross-region model inference tokens per minute" "$MATCH_NAME" "$Q")"
    GL_QUOTA="$(quota_value_for_model "^Global cross-region model inference tokens per minute" "$MATCH_NAME" "$Q")"

    # A scope is "testable" when it has an inference profile AND a TPM quota > 0.
    EU_OK="false"; GL_OK="false"
    [[ -n "$EU_PID" ]] && num_gt_zero "${EU_QUOTA:-0}" && EU_OK="true"
    [[ -n "$GL_PID" ]] && num_gt_zero "${GL_QUOTA:-0}" && GL_OK="true"

    TESTED_ANY="false"

    # Default scope: EU only. With --global, also probe Global. Each testable
    # scope produces its own row (full coverage, no EU->Global fallback).
    if [[ "$EU_OK" == "true" ]]; then
      run_probe "$P" "$NAME" "EU" "$EU_PID"
      TESTED_ANY="true"
    fi
    if [[ "$TEST_GLOBAL" == "true" && "$GL_OK" == "true" ]]; then
      run_probe "$P" "$NAME" "GLOBAL" "$GL_PID"
      TESTED_ANY="true"
    fi

    [[ "$TESTED_ANY" == "true" ]] && continue

    # Nothing was tested for this model. Choose the most accurate skip reason.
    if [[ "$TEST_GLOBAL" != "true" && "$GL_OK" == "true" ]]; then
      # A Global profile with quota exists, but default scope is EU-only.
      SKIP_REASON="SKIP/NO-EU"
    elif [[ -n "${EU_QUOTA:-}" || -n "${GL_QUOTA:-}" ]]; then
      # A quota value was found but it was 0 (in the relevant scope(s)).
      SKIP_REASON="SKIP/QUOTA0"
    else
      # No dedicated cross-region TPM quota exists at all (often LEGACY models).
      SKIP_REASON="SKIP/NO-QUOTA"
    fi
    printf "  %-10s %-28s %-10s %-48s %-14s\n" \
      "$P" "$(short "$NAME" 28)" "-" "-" "$SKIP_REASON"
    printf "%s\t%s\t-\t-\t%s\n" "$P" "$NAME" "$SKIP_REASON" >> "$RUNTIME_TSV"
  done < "$ACCESS_TSV"

  # Print the RETENTION-REQ explanation once, only if it actually occurred.
  if [[ "$RETENTION_SEEN" == "true" ]]; then
    echo
    echo "  Note (RETENTION-REQ):"
    echo "    One or more models are covered models that require an account-wide"
    echo "    data retention opt-in before they can be invoked; the 'default'"
    echo "    retention mode is rejected. This audit changes no configuration."
    echo "    Enable the required data retention mode separately, then re-run."
  fi
fi

echo
echo "[8/8] QUOTA REQUEST HISTORY"

awsx service-quotas list-requested-service-quota-change-history \
  --service-code bedrock \
  --region "$REGION" \
  \
  --output json \
  > "$OUT/42-quota-request-history.json" \
  2> "$OUT/42-quota-request-history-error.txt" || true

HQUERY="RequestedQuotas[?contains(QuotaName, 'Anthropic') || contains(QuotaName, 'Claude')].[QuotaName,DesiredValue,Status,CaseId,Created]"

H="$(awsx service-quotas list-requested-service-quota-change-history \
  --service-code bedrock \
  --region "$REGION" \
  \
  --query "$HQUERY" \
  --output table 2>/dev/null || true)"

if [[ -n "$H" ]]; then
  printf "%s\n" "$H" | sed 's/^/  /'
else
  echo "  No relevant Service Quotas request history returned."
fi

echo
echo "=============================================================================="
echo "  AUDIT COMPLETE"
echo "=============================================================================="
echo "  Account:   $ACCOUNT_ID"
echo "  Timestamp: $TS UTC"
echo

# Interactive prompts are written to the preserved terminal FD (TTY_FD), not to
# stdout/stderr, so they are NOT captured into the tee'd transcript. Otherwise
# the report would contain half-empty prompt lines like "Partner name [Partner]:"
# with the typed answer missing (read does not echo the answer into the pipe).
# The resolved values are printed into the report once, below.
if [[ -t 0 ]]; then
  printf "\n  Report naming\n  -------------\n" >&"$TTY_FD"

  printf "  Partner name  [Partner]: " >&"$TTY_FD"
  read -r PARTNER < /dev/tty
  PARTNER="${PARTNER:-Partner}"

  printf "  Customer name [Customer]: " >&"$TTY_FD"
  read -r CUSTOMER < /dev/tty
  CUSTOMER="${CUSTOMER:-Customer}"
else
  PARTNER="Partner"
  CUSTOMER="Customer"
fi

DEFAULT_FILE="IM_Bedrock_Audit_$(safe_name "$PARTNER")_$(safe_name "$CUSTOMER")_${ACCOUNT_ID}_${TS_FILE}.txt"

if [[ -t 0 ]]; then
  printf "  Report filename [%s]: " "$DEFAULT_FILE" >&"$TTY_FD"
  read -r USER_FILE < /dev/tty
else
  USER_FILE=""
fi

FINAL_REPORT="${USER_FILE:-$DEFAULT_FILE}"
[[ "$FINAL_REPORT" == *.txt ]] || FINAL_REPORT="${FINAL_REPORT}.txt"

# Move the complete console transcript to the final report file.
# tee keeps writing to the same inode, so late output is still captured.
mv "$TMP_REPORT" "$FINAL_REPORT"

echo
echo "  Report naming"
echo "  -------------"
echo "  Partner:  $PARTNER"
echo "  Customer: $CUSTOMER"
echo
echo "  Complete report (single file):"
echo "    $FINAL_REPORT"
echo
echo "  Please send this report file to Ingram Micro for technical review."
echo
