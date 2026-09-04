#!/usr/bin/env bash
#
# Apica Ascent on-prem installer
# ==============================
# Installs a k0s Kubernetes cluster (single- or multi-node) with MetalLB, OpenEBS, Envoy
# Gateway and optionally the CloudNativePG operator (the PLATFORM), then deploys the Apica
# Ascent helm chart (the APPLICATION). Run it ON the controller node as a user with
# passwordless sudo. Multi-node installs need SSH access from the controller to each worker.
#
# Usage: ./ascent-install.sh [<command>] [--config ascent.conf] [--<option> <value> ...] [--yes]
#        ./ascent-install.sh                      # interactive: asks the settings, then runs 'all'
#
# Without a config file the installer asks for every required setting (passwords are typed
# hidden) and writes ascent.conf + ascent-secrets.conf (mode 600) before it starts; later runs
# reuse them. Any config key can also be given as an option: --domain x.example.com,
# --s3-url https://..., --ingest-gb-per-day 100 (option name = lowercase key with dashes).
# Settings still missing are asked for interactively; without a terminal the run stops and
# lists them. Secrets on the command line work but are visible in shell history — prefer the
# prompt, ASCENT_<VAR> environment variables or ascent-secrets.conf.
#
# Commands
#   preflight             Check host, network, config, TLS, S3 credentials and sizing; prints ONE
#                         complete report of every failure and warning. Changes nothing.
#   all                   preflight, then 'platform install', then 'app install'.
#   platform install      Firewall chain, k0s (install, or adopt/resume an existing one), worker
#                         join + pool labels, OpenEBS + MetalLB, Envoy Gateway, CNPG operator
#                         (DB_ENGINE=cnpg). Idempotent: existing pieces are reused.
#   platform uninstall    Remove EVERYTHING this installer created and nothing else: app, add-ons
#                         it installed, its firewall chains, k0s only if it created the cluster.
#                         Alias: cleanup. Asks for confirmation.
#   platform status       Same as 'status'.
#   app install           Generate values, ingest TLS secret, helm install, verify (pods, gateway,
#                         HTTPS, admin login). Never touches the platform.
#   app upgrade           Same as 'app install' for an existing release (new CHART_VERSION, sizing
#                         or settings). Keeps the existing data volumes.
#   app rollback          helm rollback to the previous revision, then verify. Asks for confirmation.
#   app uninstall         Remove the Ascent release, its namespace and ALL its data. The platform
#                         stays. Alias: uninstall. Asks for confirmation.
#   app status            Same as 'status'.
#   worker join <ip:pool> Prepare and join one worker (pool: ingest|base|common) and label it;
#                         re-runnable for a failed join.
#   status                Installer state, host, platform and application health, login check.
#   diagnose              Write a redacted support bundle (host, k0s, Kubernetes, app logs, installer
#                         state) to ~/ascent-install/diagnostics/.
#   network k0s workers addons envoy cnpg values deploy verify
#                         Run a single platform/app phase (all idempotent), e.g. to retry one step.
#
# Options
#   --config <file>       Configuration file (default: ./ascent.conf, then next to the script).
#                         Secrets go in ascent-secrets.conf beside it, or ASCENT_<VAR> env vars.
#   --<key> <value>       Any config key, e.g. --domain, --admin-email, --s3-bucket, --db-engine.
#   --interactive, -i     Re-ask every setting (current values as defaults) and rewrite the files.
#   --yes                 Skip confirmation prompts (required when stdin is not a terminal).
#   --help                This text.
#
# Every run writes a redacted log to ~/ascent-install/logs/. On failure the installer prints
# diagnostics, the last successful phase and the exact command to resume.

# Everything lives in main(): bash parses the whole file before executing, so replacing the
# file during a run cannot affect the running copy.
main() {
set -Eeuo pipefail
# provisional ERR trap until the diagnostics trap is installed below
trap 'echo "[ascent-install] ERROR: command failed (exit $?) at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

INSTALLER_VERSION="0.3.0"
START_TS="$(date +%s)"

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------
banner() {
  cat <<'EOF'

  /$$$$$$            /$$                         /$$
 /$$__  $$          |__/                        |__/
| $$  \ $$  /$$$$$$  /$$  /$$$$$$$  /$$$$$$      /$$  /$$$$$$
| $$$$$$$$ /$$__  $$| $$ /$$_____/ |____  $$    | $$ /$$__  $$
| $$__  $$| $$  \ $$| $$| $$        /$$$$$$$    | $$| $$  \ $$
| $$  | $$| $$  | $$| $$| $$       /$$__  $$    | $$| $$  | $$
| $$  | $$| $$$$$$$/| $$|  $$$$$$$|  $$$$$$$ /$$| $$|  $$$$$$/
|__/  |__/| $$____/ |__/ \_______/ \_______/|__/|__/ \______/
          | $$
          | $$
          |__/
EOF
  echo "  Apica Ascent on-prem installer v${INSTALLER_VERSION}"
  echo
}

# ---------------------------------------------------------------------------
# logging
# ---------------------------------------------------------------------------
C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'; C_GRN=$'\033[1;32m'; C_BLU=$'\033[1;34m'; C_OFF=$'\033[0m'
log()  { echo -e "${C_GRN}[ascent-install]${C_OFF} $*"; }
info() { echo -e "${C_BLU}[ascent-install]${C_OFF} $*"; }
warn() { echo -e "${C_YEL}[ascent-install] WARN:${C_OFF} $*" >&2; }
die()  { echo -e "${C_RED}[ascent-install] ERROR:${C_OFF} $*" >&2; print_failure_context; exit 1; }
hr()   { echo "------------------------------------------------------------------"; }

# ---------------------------------------------------------------------------
# defaults (override in the config file)
# ---------------------------------------------------------------------------
# --- versions ---
K0S_VERSION="v1.34.7+k0s.0"
KUBECTL_VERSION="v1.34.7"
HELM_VERSION="v3.21.0"                   # Helm 4 is NOT supported by the chart
ENVOY_GATEWAY_VERSION="v1.6.0"
OPENEBS_CHART_VERSION="3.9.0"
METALLB_CHART_VERSION="0.15.3"
CNPG_OPERATOR_CHART_VERSION="0.29.0"     # cloudnative-pg operator (DB_ENGINE=cnpg only)

# --- chart source ---
CHART_SOURCE="repo"                 # repo | path
CHART_REPO_URL="https://apicasystem.github.io/apica-ascent-helm"
CHART_VERSION="3.1.5"
CHART_PATH=""                       # used when CHART_SOURCE=path
RELEASE_NAME="apica-ascent"
NAMESPACE="apica-ascent"
EXTRA_VALUES_FILE=""                # optional extra helm values file (applied last)
IMAGE_REGISTRY=""                   # optional private registry mirror (global.imageRegistry)

# --- cluster ---
CLUSTER_MODE="k0s"                  # k0s: install/adopt k0s on this host | existing: use the current kubeconfig (EKS, OpenShift, ...)
CLOUD_PROVIDER="none"               # LoadBalancer annotations for existing clusters: none | aws (NLB) | oci (chart defaults)
PRIVATE_IP=""                       # auto-detected when empty
PUBLIC_IP=""                        # optional; added to API SANs and used in verify
WORKERS=""                          # "ip:pool ip:pool ..." pools: ingest | base | common
CONTROLLER_POOL=""                  # optional: also label the controller with a pool
SSH_USER="ubuntu"
SSH_KEY=""                          # required when WORKERS is set
NODE_POOL_LABEL="apica-node-pool"

# --- networking ---
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
LB_IP=""                            # metallb pool IP; defaults to PRIVATE_IP
NODE_SUBNET=""                      # defaults to the primary interface's subnet
APPLY_NETWORK_FIXES="auto"          # auto | true | false  (OCI VCN src/dst-check workarounds)

# --- application ---
DOMAIN=""                           # required, e.g. ascent.example.com
TLS_CERT_FILE=""                    # PEM cert (+ intermediates) matching DOMAIN
TLS_KEY_FILE=""                     # PEM private key (unencrypted)
TLS_CA_FILE=""                      # optional: intermediate/CA chain for the ingest secret
TLS_SELF_SIGNED="false"             # generate a self-signed cert when no cert files are given
S3_URL=""                           # required, S3-compatible endpoint (no bucket, no trailing /)
S3_BUCKET=""                        # required
S3_REGION=""                        # required
S3_ACCESS=""                        # required
S3_SECRET=""                        # required
S3_CA_FILE=""                       # optional: CA bundle for a private-CA S3 endpoint (MinIO etc.)
ADMIN_NAME="admin"
ADMIN_PASSWORD=""                   # required: >=12 chars, upper+lower+digit+special
ADMIN_ORG="apica"
ADMIN_EMAIL=""                      # required
PG_PASSWORD=""                      # required: >=8 chars from [A-Za-z0-9._~-] (embedded in URLs)
DB_ENGINE="bitnami"                 # bitnami (single Postgres) | cnpg (CloudNativePG cluster)
RATE_LIMIT_FLAGS=""                 # optional override of the derived ingest rate limit, e.g. "-max_bytes_per_sec=346729"
# --- sizing (https://docs.apica.io/getting-started/paas-deployment/paas-architecture) ---
INGEST_GB_PER_DAY=""                # expected daily ingest volume in GB; empty = chart default rate limit (30 GB/day in chart 3.1.5, 64 GB/day in newer charts)
INGEST_MODE="lake"                  # lake = Flow + Lake (indexed, searchable) | flow = Flow only (pipeline, no Lake)
WORKLOAD_TIER="2"                   # 1 simple routing … 2 standard (filter/tag/PII, 2 outputs) … 5 AI/LLM stack
INGEST_DESTINATIONS="1"             # number of output destinations (each extra one costs ~15% throughput)
PEAK_MULTIPLIER="2"                 # capacity headroom for traffic spikes (guide default 2x)
STORAGE_CLASS="openebs-hostpath"
UPLOAD_DASHBOARD="false"                # chart post-install hook; fails with 401 (casdoor) on 3.1.x and blocks helm for 20m

# --- safety / integrity ---
ADOPT_EXISTING_CLUSTER="false"      # must be true to reuse a k0s cluster this installer did not create
SKIP_CHECKSUM_VERIFY="false"        # downloads are verified against the pinned SHA-256 below
K0S_SHA256="f9e1335e2c4cc6e1cea3970d38bd5282d6382f4aea5050924ff50c520194619f"       # k0s-v1.34.7+k0s.0-amd64
KUBECTL_SHA256="b46ecf2b80f76d5a7d58c296c2e11e42c85eaa1eb866ddbc1e91625f71c21000"   # kubectl v1.34.7 linux/amd64
HELM_SHA256="0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36"      # helm-v3.21.0-linux-amd64.tar.gz
SECRETS_FILE=""                     # KEY=value file holding ADMIN_PASSWORD PG_PASSWORD S3_ACCESS S3_SECRET (default: ascent-secrets.conf next to the config)

# --- misc ---
INSTALL_DIR="${HOME}/ascent-install"
MIN_CPU=4;        REC_CPU=8
MIN_RAM_MIB=14336; REC_RAM_MIB=15360   # 14 GiB hard floor; ~16 GB recommended
MIN_DISK_GB=50;   REC_DISK_GB=300      # PVC requests total ~280-360 GiB on a full stack

KNOWN_VARS="K0S_VERSION KUBECTL_VERSION HELM_VERSION ENVOY_GATEWAY_VERSION OPENEBS_CHART_VERSION
METALLB_CHART_VERSION CNPG_OPERATOR_CHART_VERSION CHART_SOURCE CHART_REPO_URL CHART_VERSION CHART_PATH
RELEASE_NAME NAMESPACE EXTRA_VALUES_FILE IMAGE_REGISTRY PRIVATE_IP PUBLIC_IP WORKERS CONTROLLER_POOL
SSH_USER SSH_KEY NODE_POOL_LABEL POD_CIDR SERVICE_CIDR LB_IP NODE_SUBNET APPLY_NETWORK_FIXES DOMAIN
TLS_CERT_FILE TLS_KEY_FILE TLS_CA_FILE TLS_SELF_SIGNED S3_URL S3_BUCKET S3_REGION S3_ACCESS S3_SECRET
S3_CA_FILE ADMIN_NAME ADMIN_PASSWORD ADMIN_ORG ADMIN_EMAIL PG_PASSWORD DB_ENGINE RATE_LIMIT_FLAGS
STORAGE_CLASS UPLOAD_DASHBOARD INSTALL_DIR MIN_CPU REC_CPU MIN_RAM_MIB REC_RAM_MIB MIN_DISK_GB REC_DISK_GB
ADOPT_EXISTING_CLUSTER SKIP_CHECKSUM_VERIFY K0S_SHA256 KUBECTL_SHA256 HELM_SHA256 SECRETS_FILE
INGEST_GB_PER_DAY INGEST_MODE WORKLOAD_TIER INGEST_DESTINATIONS PEAK_MULTIPLIER CLUSTER_MODE CLOUD_PROVIDER"
SECRET_VARS="ADMIN_PASSWORD PG_PASSWORD S3_ACCESS S3_SECRET"
PATH_VARS="INSTALL_DIR TLS_CERT_FILE TLS_KEY_FILE TLS_CA_FILE S3_CA_FILE SSH_KEY EXTRA_VALUES_FILE CHART_PATH SECRETS_FILE"

# ---------------------------------------------------------------------------
# config + arg parsing
# ---------------------------------------------------------------------------
CONFIG_FILE=""
ASSUME_YES="false"; INTERACTIVE="false"
PHASE=""; WORKER_JOIN_ARG=""
ORIGINAL_ARGS="$*"
declare -A CLI_VARS=()
cli_option_to_var() { local k="${1#--}"; k="${k#-}"; k="${k//-/_}"; printf '%s' "${k^^}"; }
set_cli_var() { # set_cli_var <--option> <value>
  local var; var="$(cli_option_to_var "$1")"
  if ! grep -qw "${var}" <<<"${KNOWN_VARS} ${SECRET_VARS}"; then
    echo "unknown option $1 (options are config keys in lowercase with dashes, e.g. --domain, --s3-url, --admin-email; see --help)" >&2; return 1
  fi
  CLI_VARS["${var}"]="$2"
}
POS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="${2:-}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#*=}"; shift ;;
    --yes|-y) ASSUME_YES="true"; shift ;;
    --interactive|-i) INTERACTIVE="true"; shift ;;
    --help|-h|help) PHASE="help"; shift ;;
    --*=*|-[a-zA-Z]*=*) set_cli_var "${1%%=*}" "${1#*=}" || exit 2; shift ;;
    -*) [[ $# -ge 2 ]] || { echo "option $1 needs a value" >&2; exit 2; }; set_cli_var "$1" "$2" || exit 2; shift 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
if [[ "${PHASE}" != "help" && ${#POS[@]} -gt 0 ]]; then
  case "${POS[0]}" in
    platform) [[ "${POS[1]:-}" =~ ^(install|uninstall|status)$ ]] || { echo "usage: platform install|uninstall|status" >&2; exit 2; }; PHASE="platform-${POS[1]}" ;;
    app)      [[ "${POS[1]:-}" =~ ^(install|upgrade|rollback|uninstall|status)$ ]] || { echo "usage: app install|upgrade|rollback|uninstall|status" >&2; exit 2; }; PHASE="app-${POS[1]}" ;;
    worker)   [[ "${POS[1]:-}" == join && -n "${POS[2]:-}" ]] || { echo "usage: worker join <ip:pool>" >&2; exit 2; }; PHASE="worker-join"; WORKER_JOIN_ARG="${POS[2]}" ;;
    *)        [[ ${#POS[@]} -eq 1 ]] || { echo "unexpected argument: ${POS[1]}" >&2; exit 2; }; PHASE="${POS[0]}" ;;
  esac
fi

usage() { # print the leading comment block (from line 2 up to the first non-comment line)
  awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "${BASH_SOURCE[0]}"
  exit 0
}
# no command: with a terminal or with options given, the implied command is 'all'; otherwise show usage
IMPLIED_ALL="false"
if [[ -z "${PHASE}" ]]; then
  if [[ ${#CLI_VARS[@]} -gt 0 || -t 0 ]]; then PHASE="all"; IMPLIED_ALL="true"; else PHASE="help"; fi
fi
[[ "${PHASE}" == "help" ]] && usage
case "${PHASE}" in
  preflight|network|k0s|workers|addons|envoy|cnpg|values|deploy|verify|all|uninstall|cleanup|status|diagnose) ;;
  platform-install|platform-uninstall|platform-status|app-install|app-upgrade|app-rollback|app-uninstall|app-status|worker-join) ;;
  *) echo "unknown command '${PHASE}' (see --help)" >&2; exit 2 ;;
esac

# running as root without sudo installed (minimal images)
if [[ ${EUID} -eq 0 ]] && ! command -v sudo >/dev/null 2>&1; then
  sudo() { [[ "${1:-}" == "-n" ]] && shift; "$@"; }
fi

# ---------------------------------------------------------------------------
# configuration: parsed line by line, never sourced (no shell expansion of values)
# ---------------------------------------------------------------------------
CONFIG_UNKNOWN=(); CONFIG_BAD_LINES=(); CONFIG_SECRETS_IN_MAIN=()
is_secret_var() { grep -qw "$1" <<<"${SECRET_VARS}"; }
load_config_file() { # load_config_file <file> <secrets-allowed:true|false>
  local file="$1" allow="$2" line key val rest n=0
  if grep -q $'\r' "${file}"; then
    echo "config file ${file} has Windows (CRLF) line endings — run: sed -i 's/\r\$//' ${file}" >&2; exit 2
  fi
  while IFS= read -r line || [[ -n "${line}" ]]; do
    n=$((n+1))
    [[ "${line}" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "${line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then CONFIG_BAD_LINES+=("${file}:${n}"); continue; fi
    key="${BASH_REMATCH[2]}"; val="${BASH_REMATCH[3]}"
    case "${val}" in
      \"*)  val="${val#\"}"; rest="${val#*\"}"; val="${val%%\"*}" ;;
      \'*)  val="${val#\'}"; rest="${val#*\'}"; val="${val%%\'*}" ;;
      *)    rest=""; val="${val%%#*}"; val="${val%"${val##*[![:space:]]}"}" ;;
    esac
    [[ "${rest}" =~ ^[[:space:]]*(#.*)?$ ]] || { CONFIG_BAD_LINES+=("${file}:${n} (text after the closing quote)"); continue; }
    if ! grep -qw "${key}" <<<"${KNOWN_VARS} ${SECRET_VARS}"; then CONFIG_UNKNOWN+=("${key}"); continue; fi
    is_secret_var "${key}" && [[ "${allow}" != "true" ]] && CONFIG_SECRETS_IN_MAIN+=("${key}")
    printf -v "${key}" '%s' "${val}"
  done < "${file}"
}
expand_home() { local v="$1"; v="${v/#\~/${HOME}}"; v="${v/#\$\{HOME\}/${HOME}}"; v="${v/#\$HOME/${HOME}}"; printf '%s' "${v}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${CONFIG_FILE}" ]]; then
  for _c in "./ascent.conf" "${SCRIPT_DIR}/ascent.conf"; do [[ -f "${_c}" ]] && { CONFIG_FILE="${_c}"; break; }; done
  [[ -z "${CONFIG_FILE}" ]] || echo "[ascent-install] using ${CONFIG_FILE} (no --config given)"
fi
unset _c
if [[ -n "${CONFIG_FILE}" ]]; then
  [[ -f "${CONFIG_FILE}" ]] || { echo "config file not found: ${CONFIG_FILE}" >&2; exit 2; }
  load_config_file "${CONFIG_FILE}" false
  # secrets: dedicated file next to the config unless SECRETS_FILE says otherwise
  if [[ -z "${SECRETS_FILE}" && -f "$(dirname "${CONFIG_FILE}")/ascent-secrets.conf" ]]; then SECRETS_FILE="$(dirname "${CONFIG_FILE}")/ascent-secrets.conf"; fi
  if [[ -n "${SECRETS_FILE}" ]]; then
    SECRETS_FILE="$(expand_home "${SECRETS_FILE}")"
    [[ -f "${SECRETS_FILE}" ]] || { echo "SECRETS_FILE not found: ${SECRETS_FILE}" >&2; exit 2; }
    load_config_file "${SECRETS_FILE}" true
  fi
  if [[ ${#CONFIG_BAD_LINES[@]} -gt 0 ]]; then
    echo "config: lines that are not KEY=value (values with quotes inside need the other quote style): ${CONFIG_BAD_LINES[*]}" >&2; exit 2
  fi
fi
# environment overrides for secrets (CI / secret managers): ASCENT_ADMIN_PASSWORD etc.
for _v in ${SECRET_VARS}; do _e="ASCENT_${_v}"; if [[ -n "${!_e:-}" ]]; then printf -v "${_v}" '%s' "${!_e}"; fi; done
# command-line options override the files
CLI_SECRET_FLAGS=""
for _v in "${!CLI_VARS[@]}"; do printf -v "${_v}" '%s' "${CLI_VARS[${_v}]}"; if is_secret_var "${_v}"; then CLI_SECRET_FLAGS="${CLI_SECRET_FLAGS} ${_v}"; fi; done
for _v in ${PATH_VARS}; do if [[ -n "${!_v}" ]]; then printf -v "${_v}" '%s' "$(expand_home "${!_v}")"; fi; done
unset _v _e

# ---------------------------------------------------------------------------
# interactive completion: ask for whatever a command needs and is not configured, then persist it
# ---------------------------------------------------------------------------
REQUIRED_VARS="DOMAIN ADMIN_NAME ADMIN_ORG ADMIN_EMAIL ADMIN_PASSWORD PG_PASSWORD S3_URL S3_BUCKET S3_REGION S3_ACCESS S3_SECRET"
command_needs_config() { case "${PHASE}" in preflight|all|platform-install|app-install|app-upgrade|values|deploy|verify|worker-join) return 0 ;; *) return 1 ;; esac; }
missing_required() { local v; for v in ${REQUIRED_VARS}; do [[ -n "${!v}" ]] || echo "${v}"; done; [[ -n "${TLS_CERT_FILE}" || "${TLS_SELF_SIGNED}" == "true" ]] || echo TLS_CERT_FILE; }
VALIDATION_MSG=""
v_domain()   { [[ "$1" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)+$ ]] && ! [[ "$1" =~ ^[0-9.]+$ ]] || { VALIDATION_MSG="must be a lowercase DNS name like ascent.example.com"; return 1; }; }
v_email()    { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { VALIDATION_MSG="must be an email address"; return 1; }; }
v_word()     { [[ -n "$1" && ! "$1" =~ [[:space:]] ]] || { VALIDATION_MSG="must not be empty or contain spaces"; return 1; }; }
v_admin_pw() { local why=""; [[ ${#1} -ge 12 ]] || why="${why} 12+ chars"; [[ "$1" =~ [A-Z] ]] || why="${why} uppercase"; [[ "$1" =~ [a-z] ]] || why="${why} lowercase"; [[ "$1" =~ [0-9] ]] || why="${why} digit"; [[ "$1" =~ [^A-Za-z0-9] ]] || why="${why} special"
               [[ "$1" == *\'* && "$1" == *\"* ]] && why="${why} (must not contain both ' and \")"; [[ -z "${why}" ]] || { VALIDATION_MSG="password policy: needs${why}"; return 1; }; }
v_pg_pw()    { [[ "$1" =~ ^[A-Za-z0-9._~-]{8,}$ ]] || { VALIDATION_MSG="8+ characters, only letters, digits and . _ ~ - (it is embedded in database URLs)"; return 1; }; }
v_url()      { [[ "${1%/}" =~ ^https?://[^/]+$ ]] || { VALIDATION_MSG="the bare endpoint, e.g. https://s3.us-east-1.amazonaws.com (no bucket, no path)"; return 1; }; }
v_file()     { [[ -f "$(expand_home "$1")" ]] || { VALIDATION_MSG="file not found"; return 1; }; }
v_int()      { [[ "$1" =~ ^[0-9]+$ ]] || { VALIDATION_MSG="must be a whole number"; return 1; }; }
v_choice()   { local x="$1"; shift; local c; for c in "$@"; do [[ "${x}" == "${c}" ]] && return 0; done; VALIDATION_MSG="one of: $*"; return 1; }
v_bucket()   { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]{1,61}[a-z0-9])?$ ]] || { VALIDATION_MSG="lowercase letters, digits, . and -"; return 1; }; }
ask() { # ask <VAR> <prompt> <default> <validator...>   (validator may be empty; "secret:" prefix hides input and asks twice)
  local var="$1" text="$2" def="$3" secret="" ans ans2; shift 3
  [[ "${1:-}" == secret ]] && { secret="yes"; shift; }
  while true; do
    if [[ -n "${secret}" ]]; then
      printf '%s: ' "${text}" > /dev/tty; IFS= read -r -s ans < /dev/tty; printf '\n' > /dev/tty
    else
      printf '%s%s: ' "${text}" "${def:+ [${def}]}" > /dev/tty; IFS= read -r ans < /dev/tty
    fi
    local used_default=""
    [[ -z "${ans}" && -n "${def}" ]] && { ans="${def}"; used_default="yes"; }
    [[ -n "${ans}" ]] || { printf '  a value is required\n' > /dev/tty; continue; }
    if [[ $# -gt 0 ]] && ! "$@" "${ans}"; then printf '  %s\n' "${VALIDATION_MSG}" > /dev/tty; continue; fi
    if [[ -n "${secret}" && -n "${used_default}" ]]; then printf '  using the generated value (saved to ascent-secrets.conf)\n' > /dev/tty
    elif [[ -n "${secret}" ]]; then
      printf '%s (again): ' "${text}" > /dev/tty; IFS= read -r -s ans2 < /dev/tty; printf '\n' > /dev/tty
      [[ "${ans}" == "${ans2}" ]] || { printf '  the two entries differ\n' > /dev/tty; continue; }
    fi
    printf -v "${var}" '%s' "${ans}"; return 0
  done
}
ask_var() { # prompt for one config key with its default and validator
  case "$1" in
    CLUSTER_MODE)   ask CLUSTER_MODE "Cluster: k0s = install k0s on this host, existing = use the current kubeconfig" "${CLUSTER_MODE:-k0s}" v_choice k0s existing ;;
    STORAGE_CLASS)  ask STORAGE_CLASS "Storage class" "${STORAGE_CLASS}" v_word ;;
    CLOUD_PROVIDER) ask CLOUD_PROVIDER "Cloud provider for LoadBalancer annotations (none|aws|oci)" "${CLOUD_PROVIDER}" v_choice none aws oci ;;
    DOMAIN)         ask DOMAIN "Domain users will open, e.g. ascent.example.com" "${DOMAIN}" v_domain ;;
    ADMIN_NAME)     ask ADMIN_NAME "Admin user name" "${ADMIN_NAME:-admin}" v_word ;;
    ADMIN_ORG)      ask ADMIN_ORG "Admin organisation" "${ADMIN_ORG:-apica}" v_word ;;
    ADMIN_EMAIL)    ask ADMIN_EMAIL "Admin email (used to log in)" "${ADMIN_EMAIL}" v_email ;;
    ADMIN_PASSWORD) ask ADMIN_PASSWORD "Admin password (12+ chars, upper, lower, digit, special; hidden)" "" secret v_admin_pw ;;
    PG_PASSWORD)    local gen; gen="$(openssl rand -base64 36 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c1-24)"
                    printf 'Postgres password: press Enter to use a generated one, or type your own (8+ chars, letters/digits/._~-)\n' > /dev/tty
                    ask PG_PASSWORD "Postgres password (hidden)" "${gen}" secret v_pg_pw ;;
    S3_URL)         ask S3_URL "S3 endpoint URL, e.g. https://s3.us-east-1.amazonaws.com" "${S3_URL}" v_url; S3_URL="${S3_URL%/}" ;;
    S3_BUCKET)      ask S3_BUCKET "S3 bucket" "${S3_BUCKET}" v_bucket ;;
    S3_REGION)      local guess=""; [[ "${S3_URL}" =~ objectstorage\.([a-z0-9-]+)\.oraclecloud\.com|s3[.-]([a-z0-9-]+)\.amazonaws\.com ]] && guess="${BASH_REMATCH[1]:-${BASH_REMATCH[2]}}"
                    ask S3_REGION "S3 region" "${S3_REGION:-${guess}}" v_word ;;
    S3_ACCESS)      ask S3_ACCESS "S3 access key" "${S3_ACCESS}" v_word ;;
    S3_SECRET)      ask S3_SECRET "S3 secret key (hidden)" "" secret v_word ;;
    TLS_CERT_FILE)  printf 'TLS: enter the certificate file for %s, or leave empty to generate a self-signed certificate\n' "${DOMAIN}" > /dev/tty
                    printf 'Certificate file (PEM, leaf + intermediates): ' > /dev/tty; IFS= read -r TLS_CERT_FILE < /dev/tty
                    if [[ -z "${TLS_CERT_FILE}" ]]; then TLS_SELF_SIGNED="true"
                    else TLS_CERT_FILE="$(expand_home "${TLS_CERT_FILE}")"; v_file "${TLS_CERT_FILE}" || { printf '  %s\n' "${VALIDATION_MSG}" > /dev/tty; TLS_CERT_FILE=""; ask_var TLS_CERT_FILE; return; }
                      ask TLS_KEY_FILE "Private key file (PEM, unencrypted)" "${TLS_KEY_FILE}" v_file; TLS_KEY_FILE="$(expand_home "${TLS_KEY_FILE}")"
                      printf 'CA / intermediate chain file (optional, Enter to skip): ' > /dev/tty; IFS= read -r TLS_CA_FILE < /dev/tty; TLS_CA_FILE="$(expand_home "${TLS_CA_FILE}")"; fi ;;
    DB_ENGINE)      ask DB_ENGINE "Database: bitnami = single Postgres, cnpg = CloudNativePG cluster" "${DB_ENGINE}" v_choice bitnami cnpg ;;
    INGEST_GB_PER_DAY) ask INGEST_GB_PER_DAY "Expected ingest volume in GB per day (sizes pods, disk and the rate limit)" "${INGEST_GB_PER_DAY:-50}" v_int ;;
    INGEST_MODE)    ask INGEST_MODE "Ingest mode: lake = indexed & searchable, flow = pipeline only" "${INGEST_MODE}" v_choice lake flow ;;
    *)              ask "$1" "$1" "${!1}" ;;
  esac
}
WIZARD_ORDER="CLUSTER_MODE DOMAIN ADMIN_NAME ADMIN_ORG ADMIN_EMAIL ADMIN_PASSWORD PG_PASSWORD S3_URL S3_BUCKET S3_REGION S3_ACCESS S3_SECRET TLS_CERT_FILE DB_ENGINE INGEST_GB_PER_DAY INGEST_MODE"
run_wizard() { # run_wizard <all|missing>
  local v
  printf '\nApica Ascent installer — configuration\n(answers are saved to ascent.conf and ascent-secrets.conf; Enter accepts the value in brackets)\n\n' > /dev/tty
  if [[ "$1" == all ]]; then
    for v in ${WIZARD_ORDER}; do
      ask_var "${v}"
      if [[ "${v}" == CLUSTER_MODE && "${CLUSTER_MODE}" == existing ]]; then ask_var STORAGE_CLASS; ask_var CLOUD_PROVIDER; fi
    done
  else
    for v in $(missing_required); do ask_var "${v}"; done
  fi
}
quote_conf() { if [[ "$1" == *\'* ]]; then printf '"%s"' "$1"; else printf "'%s'" "$1"; fi; }
config_set_key() { # config_set_key <file> <KEY> <value>: replace the line or append
  local f="$1" k="$2" v; v="$(quote_conf "$3")"
  [[ -f "${f}" ]] || { umask 077; : > "${f}"; }
  if grep -qE "^[[:space:]]*(export[[:space:]]+)?${k}=" "${f}"; then
    local tmp; tmp="$(mktemp)"; awk -v k="${k}" -v v="${v}" 'BEGIN{done=0} $0 ~ "^[ \t]*(export[ \t]+)?"k"=" && !done {print k"="v; done=1; next} {print}' "${f}" > "${tmp}" && cat "${tmp}" > "${f}" && rm -f "${tmp}"
  else printf '%s=%s\n' "${k}" "${v}" >> "${f}"; fi
  chmod 600 "${f}"
}
persist_config() { # write every user-facing key to the config files (secrets to the secrets file)
  local main="${CONFIG_FILE:-./ascent.conf}" sec="${SECRETS_FILE:-$(dirname "${CONFIG_FILE:-./ascent.conf}")/ascent-secrets.conf}" k
  [[ -f "${main}" ]] || printf '# Apica Ascent installer configuration — written by the installer on %s\n# Secrets live in %s\n' "$(date -u +%FT%TZ)" "$(basename "${sec}")" > "${main}"
  [[ -f "${sec}" ]]  || { umask 077; printf '# Apica Ascent installer secrets — mode 600, never commit\n' > "${sec}"; }
  for k in CLUSTER_MODE DOMAIN ADMIN_NAME ADMIN_ORG ADMIN_EMAIL S3_URL S3_BUCKET S3_REGION TLS_CERT_FILE TLS_KEY_FILE TLS_CA_FILE TLS_SELF_SIGNED DB_ENGINE INGEST_GB_PER_DAY INGEST_MODE; do
    if [[ -n "${!k}" ]]; then config_set_key "${main}" "${k}" "${!k}"; fi
  done
  if [[ "${CLUSTER_MODE}" == existing ]]; then config_set_key "${main}" STORAGE_CLASS "${STORAGE_CLASS}"; config_set_key "${main}" CLOUD_PROVIDER "${CLOUD_PROVIDER}"; fi
  for k in "${!CLI_VARS[@]}"; do if ! is_secret_var "${k}"; then config_set_key "${main}" "${k}" "${!k}"; fi; done
  for k in ${SECRET_VARS}; do if [[ -n "${!k}" ]]; then config_set_key "${sec}" "${k}" "${!k}"; fi; done
  chmod 600 "${main}" "${sec}"
  CONFIG_FILE="${main}"; SECRETS_FILE="${sec}"
  echo "[ascent-install] configuration saved to ${main} and ${sec} (mode 600) — later runs pick them up automatically"
}
if [[ "${PHASE}" != help ]] && command_needs_config; then
  _missing="$(missing_required | tr '\n' ' ')"
  if [[ "${INTERACTIVE}" == "true" || ( -z "${CONFIG_FILE}" && -n "${_missing}" ) ]]; then
    [[ -t 0 && -w /dev/tty ]] || { echo "no configuration and no terminal: pass --config <file>, the --<option> values, or ASCENT_<VAR> variables (missing:${_missing:+ ${_missing}})" >&2; exit 2; }
    run_wizard all; persist_config
  elif [[ -n "${_missing}" ]]; then
    if [[ -t 0 && -w /dev/tty ]]; then
      printf 'Not configured yet:%s\nEnter them now? [Y/n] ' "${_missing:+ ${_missing}}" > /dev/tty; IFS= read -r _a < /dev/tty
      [[ "${_a}" =~ ^[Nn] ]] && { echo "aborted: set the missing values in ${CONFIG_FILE} or pass them as options" >&2; exit 2; }
      run_wizard missing; persist_config
    else
      echo "required settings missing:${_missing} — set them in ${CONFIG_FILE:-ascent.conf}/ascent-secrets.conf, pass --<option> values, or ASCENT_<VAR> variables" >&2; exit 2
    fi
  elif [[ ${#CLI_VARS[@]} -gt 0 ]]; then
    persist_config   # values given as options are recorded so that later runs do not need them again
  fi
  unset _missing _a
fi
if [[ "${IMPLIED_ALL}" == "true" && "${ASSUME_YES}" != "true" ]]; then
  printf 'Run preflight, platform install and app install now? [Y/n] ' > /dev/tty; IFS= read -r _a < /dev/tty
  [[ "${_a}" =~ ^[Nn] ]] && { echo "not started; run './ascent-install.sh all' when ready (configuration is saved)"; exit 0; }
  unset _a
fi

# --- redaction: every line printed or logged passes through here ---
REDACT_EXPRS=(-E
  -e 's/((passw(or)?d|secret|token|api[_-]?key|access_key|secret_key|AWS_SECRET_ACCESS_KEY|AWS_ACCESS_KEY_ID|external_cert_key|tls\.key|syslog\.key)[A-Za-z0-9_.-]*[[:space:]]*[:=][[:space:]]*)[^[:space:]<].*/\1<redacted>/I'
  -e 's/(password[^:]{0,24}:[[:space:]]*)[^[:space:]<].*/\1<redacted>/I'
  -e 's/(Authorization:[[:space:]]*)[^[:space:]<].*/\1<redacted>/I')
sed_escape() { printf '%s' "$1" | sed -e 's/[][\\.*^$/|()+?{}]/\\&/g'; }
for _v in ${SECRET_VARS}; do
  _val="${!_v}"; [[ ${#_val} -ge 4 ]] || continue
  REDACT_EXPRS+=(-e "s/$(sed_escape "${_val}")/<redacted>/g")
done; unset _v _val
redact() { sed -u "${REDACT_EXPRS[@]}"; }

# --- log everything to a file as well (redacted) ---
mkdir -p "${INSTALL_DIR}/logs"; chmod 700 "${INSTALL_DIR}"
LOG_FILE="${INSTALL_DIR}/logs/ascent-install-$(date +%Y%m%d-%H%M%S)-${PHASE//[^A-Za-z0-9_-]/_}.log"
exec > >(redact | tee -a "${LOG_FILE}") 2>&1
# temporary files (secret values for helm) live under a private dir removed on exit
TMP_DIR="$(mktemp -d "${INSTALL_DIR}/tmp.XXXXXX")"; chmod 700 "${TMP_DIR}"
trap 'rm -rf "${TMP_DIR}"' EXIT

# A pinned checksum is only valid for its pinned version. If the version was overridden while the
# checksum still holds the built-in value, clear it so verify_sha256 requires a matching *_SHA256 (or
# SKIP_CHECKSUM_VERIFY=true). Default versions and user-supplied checksums are left untouched.
PIN_K0S_VERSION="v1.34.7+k0s.0";  PIN_K0S_SHA256="f9e1335e2c4cc6e1cea3970d38bd5282d6382f4aea5050924ff50c520194619f"
PIN_KUBECTL_VERSION="v1.34.7";    PIN_KUBECTL_SHA256="b46ecf2b80f76d5a7d58c296c2e11e42c85eaa1eb866ddbc1e91625f71c21000"
PIN_HELM_VERSION="v3.21.0";       PIN_HELM_SHA256="0093eb572e3d2380f094df162ddb525e219249de88957afe24cfbb19632acd36"
if [[ "${K0S_VERSION}" != "${PIN_K0S_VERSION}" && "${K0S_SHA256}" == "${PIN_K0S_SHA256}" ]]; then K0S_SHA256=""; fi
if [[ "${KUBECTL_VERSION}" != "${PIN_KUBECTL_VERSION}" && "${KUBECTL_SHA256}" == "${PIN_KUBECTL_SHA256}" ]]; then KUBECTL_SHA256=""; fi
if [[ "${HELM_VERSION}" != "${PIN_HELM_VERSION}" && "${HELM_SHA256}" == "${PIN_HELM_SHA256}" ]]; then HELM_SHA256=""; fi

# derived defaults
existing_cluster() { [[ "${CLUSTER_MODE}" == "existing" ]]; }
# 'ip' may be missing on a non-Linux operator host (existing-cluster mode): never fail here
PRIMARY_IF="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' || true)"; PRIMARY_IF="${PRIMARY_IF:-eth0}"
if [[ -z "${PRIVATE_IP}" ]]; then
  PRIVATE_IP="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' || true)"
fi
if existing_cluster; then
  LB_IP="${LB_IP:-}"                 # the cluster's own LoadBalancer implementation assigns the address
else
  [[ -n "${PRIVATE_IP}" ]] || die "could not auto-detect PRIVATE_IP (no default route?); set it in the config"
  LB_IP="${LB_IP:-${PRIVATE_IP}}"
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
ip2int() { local IFS=.; read -r a b c d <<<"$1"; echo $(( (a<<24) | (b<<16) | (c<<8) | d )); }
int2ip() { echo "$(( ($1>>24)&255 )).$(( ($1>>16)&255 )).$(( ($1>>8)&255 )).$(( $1&255 ))"; }
is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && { local IFS=.; for o in $1; do [[ $o -le 255 ]] || return 1; done; }; }
is_cidr() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && is_ipv4 "${1%/*}"; }
cidr_mask() { local p="$1"; (( p == 0 )) && echo 0 || echo $(( (0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF )); }
cidr_network() { local ip="${1%/*}" p="${1#*/}"; echo "$(int2ip $(( $(ip2int "${ip}") & $(cidr_mask "${p}") )))/${p}"; }
cidr_contains() { # cidr_contains <cidr> <ip>
  local net="${1%/*}" p="${1#*/}" m; m="$(cidr_mask "${p}")"
  [[ $(( $(ip2int "$2") & m )) -eq $(( $(ip2int "${net}") & m )) ]]
}
cidrs_overlap() { cidr_contains "$1" "${2%/*}" || cidr_contains "$2" "${1%/*}"; }

# derive NODE_SUBNET from the interface that actually carries PRIVATE_IP
if [[ -z "${NODE_SUBNET}" && -n "${PRIVATE_IP}" ]]; then
  _ifcidr="$(ip -o -4 addr show 2>/dev/null | awk -v ip="${PRIVATE_IP}" '$4 ~ "^"ip"/" {print $4; exit}')"
  if [[ -n "${_ifcidr}" ]]; then NODE_SUBNET="$(cidr_network "${_ifcidr}")"
  else NODE_SUBNET="$(cidr_network "${PRIVATE_IP}/24")"; fi
fi

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null || echo 0; }   # GNU or BSD stat
resolve4() { # IPv4 addresses of a name, one per line (getent on Linux, dig elsewhere)
  if command -v getent >/dev/null 2>&1; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
  elif command -v dig >/dev/null 2>&1; then dig +short A "$1" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u; fi
}
yq_str() { # YAML double-quoted scalar, safe for any printable characters
  local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "${s}"
}
b64_file() { base64 < "$1" | tr -d '\n'; }
is_oci() { grep -qi "oraclecloud" /sys/class/dmi/id/chassis_asset_tag 2>/dev/null; }
is_ec2() { grep -qiE "amazon" /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/bios_vendor 2>/dev/null || grep -qE '^i-' /sys/class/dmi/id/board_asset_tag 2>/dev/null; }
cloud_name() { if is_oci; then echo "Oracle Cloud"; elif is_ec2; then echo "AWS EC2"; fi; }
# OCI VCNs and EC2 ENIs drop packets whose source is a pod IP (source/destination checks);
# the fix is an IPIP overlay for pod traffic plus SNAT for pod->node traffic
network_fixes_enabled() {
  case "${APPLY_NETWORK_FIXES}" in
    true) return 0 ;; false) return 1 ;; auto) is_oci || is_ec2 ;;
    *) return 1 ;;
  esac
}
is_multi_node() { [[ -n "${WORKERS}" ]]; }
k0s_running() { sudo -n k0s status >/dev/null 2>&1; }
k0s_unit() { # prints "controller" or "worker" when a k0s systemd unit already exists on this host
  if systemctl list-unit-files --no-legend k0scontroller.service 2>/dev/null | grep -q k0scontroller; then echo controller
  elif systemctl list-unit-files --no-legend k0sworker.service 2>/dev/null | grep -q k0sworker; then echo worker; fi
}
k0s_unit_is_single() { grep -qs -- '--single' /etc/systemd/system/k0scontroller.service; }
have_kubectl() { command -v kubectl >/dev/null 2>&1 && kubectl get --raw /readyz >/dev/null 2>&1; }

# remote-script prelude: make 'sudo' a no-op when the remote user is root
REMOTE_PRELUDE='if [ "$(id -u)" = 0 ] && ! command -v sudo >/dev/null 2>&1; then sudo() { [ "$1" = -n ] && shift; "$@"; }; fi'
ssh_worker() { # ssh_worker <ip> <command...>
  local ip="$1"; shift
  ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
      -o ConnectTimeout=15 "${SSH_USER}@${ip}" "$@"
}

elapsed() { local s=$(( $(date +%s) - START_TS )); printf '%dm%02ds' $((s/60)) $((s%60)); }

# ---------------------------------------------------------------------------
# state: one key=value file recording what this installer created or changed; 'cleanup' acts only on it.
# ---------------------------------------------------------------------------
STATE_DIR="${INSTALL_DIR}/state"
STATE_FILE="${STATE_DIR}/installer.state"
state_get() { [[ -f "${STATE_FILE}" ]] && grep -m1 "^$1=" "${STATE_FILE}" | cut -d= -f2- || true; }
state_set() { # state_set <key> <value>
  mkdir -p "${STATE_DIR}"; chmod 700 "${STATE_DIR}"
  { [[ -f "${STATE_FILE}" ]] && grep -v "^$1=" "${STATE_FILE}"; echo "$1=$2"; } > "${STATE_FILE}.tmp" 2>/dev/null || true
  mv "${STATE_FILE}.tmp" "${STATE_FILE}"; chmod 600 "${STATE_FILE}"
}
state_del() { [[ -f "${STATE_FILE}" ]] || return 0; grep -v "^$1=" "${STATE_FILE}" > "${STATE_FILE}.tmp" || true; mv "${STATE_FILE}.tmp" "${STATE_FILE}"; }
state_keys() { [[ -f "${STATE_FILE}" ]] && grep -oE "^$1[^=]*" "${STATE_FILE}" || true; }   # keys with a prefix
mark()   { state_set "$1" true; }                 # ownership marker: "we created/changed this"
marked() { [[ "$(state_get "$1")" == "true" ]]; }
migrate_legacy_markers() { # v0.2.0 used one empty file per marker
  local f; for f in "${STATE_DIR}"/*; do
    [[ -f "${f}" && "${f}" != "${STATE_FILE}" && "${f}" != "${STATE_FILE}.tmp" && "${f##*/}" != *.tmp ]] || continue
    state_set "${f##*/}" true; rm -f "${f}"
  done
}
migrate_legacy_markers
cluster_uid() { kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || sudo -n k0s kubectl get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
cluster_known() { # the running cluster is one this installer created or was told to adopt
  local uid; uid="$(cluster_uid)"; [[ -n "${uid}" && "${uid}" == "$(state_get cluster.uid)" ]]
}

# ---------------------------------------------------------------------------
# sizing — Apica sizing & capacity planning guide (Tier baselines in GB/day per ingest vCPU)
#   Ingest vCPUs = ceil(GB/day ÷ baseline × destination factor × peak × HA)   (+10 vCPU / 28 GB / 150 GB core tier)
#   ~1 ingest pod per 4 vCPU, 4 GB RAM per vCPU (Lake) / 2 GB (Flow), 50 GB disk per pod minimum
# ---------------------------------------------------------------------------
FLASH_PVC_SIZE=""; SZ_ENABLED="false"; SZ_VCPU=0; SZ_PODS=0; SZ_POD_CPU=0; SZ_POD_MEM_GI=0; SZ_POD_DISK_GI=0; SZ_TOTAL_VCPU=0; SZ_TOTAL_RAM_GB=0; SZ_TOTAL_DISK_GB=0; SZ_BYTES_PER_SEC=0
compute_sizing() {
  [[ -n "${INGEST_GB_PER_DAY}" ]] || return 0
  [[ "${INGEST_GB_PER_DAY}" =~ ^[0-9]+$ && "${WORKLOAD_TIER}" =~ ^[1-5]$ && "${INGEST_DESTINATIONS}" =~ ^[0-9]+$ && "${PEAK_MULTIPLIER}" =~ ^[0-9]+$ && "${INGEST_MODE}" =~ ^(lake|flow)$ ]] || return 0
  local -a lake_base=(0 60 50 37 26 19) flow_base=(0 200 164 116 82 58) lake_ram=(0 3 4 5 7 13) flow_ram=(0 2 3 5 7 10)
  local base ram fpct=100 ha=100
  if [[ "${INGEST_MODE}" == lake ]]; then base=${lake_base[$WORKLOAD_TIER]}; ram=${lake_ram[$WORKLOAD_TIER]}; else base=${flow_base[$WORKLOAD_TIER]}; ram=${flow_ram[$WORKLOAD_TIER]}; fi
  case "${INGEST_DESTINATIONS}" in 0|1) fpct=100 ;; 2) fpct=85 ;; 3) fpct=70 ;; *) fpct=55 ;; esac
  is_multi_node && ha=120
  local num=$(( INGEST_GB_PER_DAY * PEAK_MULTIPLIER * ha * 100 )) den=$(( base * fpct * 100 ))
  SZ_VCPU=$(( (num + den - 1) / den )); (( SZ_VCPU < 1 )) && SZ_VCPU=1
  SZ_PODS=$(( (SZ_VCPU + 3) / 4 )); is_multi_node || SZ_PODS=1
  SZ_POD_CPU=$(( (SZ_VCPU + SZ_PODS - 1) / SZ_PODS )); (( SZ_POD_CPU < 1 )) && SZ_POD_CPU=1
  SZ_POD_MEM_GI=$(( SZ_POD_CPU * ram ))
  if [[ "${INGEST_MODE}" == lake ]]; then SZ_POD_DISK_GI=$(( (INGEST_GB_PER_DAY * 8 / 10 + SZ_PODS - 1) / SZ_PODS )); (( SZ_POD_DISK_GI < 50 )) && SZ_POD_DISK_GI=50
  else SZ_POD_DISK_GI=50; fi
  SZ_TOTAL_VCPU=$(( SZ_VCPU + 10 )); SZ_TOTAL_RAM_GB=$(( SZ_VCPU * ram + 28 )); SZ_TOTAL_DISK_GB=$(( 150 + SZ_PODS * SZ_POD_DISK_GI ))
  SZ_BYTES_PER_SEC=$(( INGEST_GB_PER_DAY * 1000000000 / 86400 ))
  SZ_ENABLED="true"
}
compute_sizing
sizing_summary() {
  echo "  ${INGEST_GB_PER_DAY} GB/day, mode ${INGEST_MODE}, tier ${WORKLOAD_TIER}, ${INGEST_DESTINATIONS} destination(s), peak x${PEAK_MULTIPLIER}$(is_multi_node && echo ', HA x1.2')"
  echo "  ingest: ${SZ_VCPU} vCPU → ${SZ_PODS} flash pod(s) × ${SZ_POD_CPU} CPU / ${SZ_POD_MEM_GI} GiB / ${SZ_POD_DISK_GI} GiB disk; rate limit ${SZ_BYTES_PER_SEC} B/s"
  echo "  total incl. core tier: ${SZ_TOTAL_VCPU} vCPU, ${SZ_TOTAL_RAM_GB} GB RAM, ${SZ_TOTAL_DISK_GB} GB disk (S3 sized separately: volume × retention × compression)"
}

# ---------------------------------------------------------------------------
# error handling + diagnostics
# ---------------------------------------------------------------------------
CURRENT_PHASE="init"

pods_unhealthy() { # pods_unhealthy <ns> -> prints "pod status ready" for pods not Running(all ready)/Completed
  kubectl get pods -n "$1" --no-headers 2>/dev/null | awk '
    { split($2, r, "/");
      if (($3 != "Running" && $3 != "Completed" && $3 != "Succeeded") || ($3 == "Running" && r[1] != r[2]))
        print $1, $3, $2 }'
}

dump_ns_diagnostics() { # dump_ns_diagnostics <namespace>
  local ns="$1"
  have_kubectl || { echo "  (kubectl not usable — cannot collect pod diagnostics)"; return 0; }
  echo; echo "== namespace ${ns}: pods that are not healthy =="
  local bad; bad="$(pods_unhealthy "${ns}")"
  if [[ -z "${bad}" ]]; then echo "  (all pods Running/Completed)"; else echo "${bad}" | sed 's/^/  /'; fi
  local n=0 pod
  while read -r pod _; do
    [[ -n "${pod}" ]] || continue
    n=$((n+1)); [[ ${n} -gt 6 ]] && { echo "  ... (more pods omitted; see kubectl get pods -n ${ns})"; break; }
    echo; echo "-- ${pod}: recent events"
    kubectl describe pod -n "${ns}" "${pod}" 2>/dev/null | sed -n '/^Events:/,$p' | tail -n 12 | sed 's/^/  /'
    echo "-- ${pod}: last log lines (all containers)"
    kubectl logs -n "${ns}" "${pod}" --all-containers --tail=20 2>&1 | tail -n 40 | sed 's/^/  /'
  done <<<"${bad}"
  echo; echo "-- warning events (newest last)"
  kubectl get events -n "${ns}" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -n 15 | sed 's/^/  /'
  echo "-- PVCs not Bound"
  kubectl get pvc -n "${ns}" --no-headers 2>/dev/null | awk '$2 != "Bound"' | sed 's/^/  /'
  echo "-- jobs (helm hooks wait for these; incomplete ones show their last log lines)"
  kubectl get jobs -n "${ns}" --no-headers 2>/dev/null | sed 's/^/  /'
  local job
  while read -r job _; do
    [[ -n "${job}" ]] || continue
    echo "-- job ${job}: last log lines"
    kubectl logs -n "${ns}" "job/${job}" --tail=15 2>&1 | tail -n 20 | sed -E 's/([Pp]assword[^:]*:).*/\1 <masked>/' | sed 's/^/  /'
  done < <(kubectl get jobs -n "${ns}" --no-headers 2>/dev/null | awk '$2 !~ /Complete/ && $3 !~ /^1\/1$/ {print $1}')
}

print_failure_context() {
  trap - ERR; set +e   # diagnostics must never re-trigger the error trap (e.g. grep with no match)
  hr
  echo "Phase '${CURRENT_PHASE}' failed after $(elapsed). Diagnostics:"
  case "${CURRENT_PHASE}" in
    k0s)
      echo "-- k0s status"; sudo -n k0s status 2>&1 | sed 's/^/  /' || true
      echo "-- k0scontroller journal (last 40 lines)"
      sudo -n journalctl -u k0scontroller --no-pager -n 40 2>&1 | sed 's/^/  /' || true
      have_kubectl && { echo "-- nodes"; kubectl get nodes -o wide 2>&1 | sed 's/^/  /'; dump_ns_diagnostics kube-system; }
      ;;
    workers)
      have_kubectl && { echo "-- nodes"; kubectl get nodes -o wide 2>&1 | sed 's/^/  /'; }
      if [[ -n "${FAILED_WORKER:-}" ]]; then
        echo "-- worker ${FAILED_WORKER}: k0sworker journal (last 30 lines)"
        ssh_worker "${FAILED_WORKER}" "sudo -n journalctl -u k0sworker --no-pager -n 30" 2>&1 | sed 's/^/  /' || true
      fi
      ;;
    addons)
      have_kubectl && {
        echo "-- k0s helm extension charts"; kubectl get charts.helm.k0sproject.io -n kube-system -o wide 2>&1 | sed 's/^/  /'
        dump_ns_diagnostics openebs; dump_ns_diagnostics metallb; }
      ;;
    envoy)   have_kubectl && { helm status eg -n envoy-gateway-system 2>&1 | head -n 12 | sed 's/^/  /'; dump_ns_diagnostics envoy-gateway-system; } ;;
    cnpg)    have_kubectl && dump_ns_diagnostics cnpg-system ;;
    deploy|verify)
      have_kubectl && {
        echo "-- helm release"; helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>&1 | head -n 12 | sed 's/^/  /'
        dump_ns_diagnostics "${NAMESPACE}"
        echo "-- gateway / gatewayclass"; kubectl get gateway -n "${NAMESPACE}" 2>&1 | sed 's/^/  /'; kubectl get gatewayclass 2>&1 | sed 's/^/  /'
        echo "-- LoadBalancer services"; kubectl get svc -n "${NAMESPACE}" 2>/dev/null | grep -E 'LoadBalancer|NAME' | sed 's/^/  /'; }
      ;;
    uninstall) have_kubectl && kubectl get ns "${NAMESPACE}" 2>&1 | sed 's/^/  /' ;;
  esac
  echo
  local last; last="$(state_get installer.last_completed_phase)"
  echo "Last successful phase:  ${last:-none}${last:+ (at $(state_get "phase.${last}.completed_at"))}"
  echo "Failed phase:           ${CURRENT_PHASE}"
  echo "Resume after fixing the cause (completed phases are re-verified in seconds, not repeated blindly):"
  if [[ "${ORIGINAL_ARGS:-}" == *"--config"* ]]; then echo "    ${BASH_SOURCE[0]} ${ORIGINAL_ARGS}"
  else echo "    ${BASH_SOURCE[0]} ${ORIGINAL_ARGS:-${PHASE}} ${CONFIG_FILE:+--config ${CONFIG_FILE}}"; fi
  case "${CURRENT_PHASE}" in
    network|k0s|workers|addons|envoy|cnpg|values|deploy|verify) echo "    ${BASH_SOURCE[0]} ${CURRENT_PHASE} ${CONFIG_FILE:+--config ${CONFIG_FILE}}      # retry only this phase" ;;
  esac
  echo "Support bundle:         ${BASH_SOURCE[0]} diagnose ${CONFIG_FILE:+--config ${CONFIG_FILE}}"
  echo "Full log: ${LOG_FILE}"
  hr
}

on_error() {
  local rc=$1 line=$2 cmd=$3
  trap - ERR; set +e
  echo
  echo -e "${C_RED}[ascent-install] ERROR:${C_OFF} command failed (exit ${rc}) in phase '${CURRENT_PHASE}' at line ${line}:"
  echo "    ${cmd}"
  print_failure_context
  exit "${rc}"
}
on_interrupt() {
  echo; warn "interrupted during phase '${CURRENT_PHASE}'. Re-run the same command to resume; phases are idempotent."
  echo "Log: ${LOG_FILE}"; exit 130
}
arm_traps()    { trap 'on_error $? ${LINENO} "${BASH_COMMAND}"' ERR; trap on_interrupt INT TERM; }
disarm_traps() { trap - ERR; }
arm_traps

# ---------------------------------------------------------------------------
# confirmation prompts go straight to the terminal: stdout/stderr pass through the line-based
# redaction filter, which would hold back a prompt that has no trailing newline
# ---------------------------------------------------------------------------
confirm() { # confirm <prompt> <accepted-answer-regex>
  [[ "${ASSUME_YES}" == "true" ]] && return 0
  if [[ ! -t 0 || ! -w /dev/tty ]]; then die "this command needs confirmation — re-run with --yes when not running interactively"; fi
  printf '%s' "$1" > /dev/tty
  local ans; IFS= read -r ans < /dev/tty
  echo "  confirmation answer: ${ans}"
  [[ "${ans}" =~ $2 ]]
}

# ---------------------------------------------------------------------------
# preflight framework: every check records a result; nothing aborts early
# ---------------------------------------------------------------------------
PF_PASS=0; PF_FAILS=(); PF_WARNS=(); PF_SECTION=""
section() { PF_SECTION="$1"; echo; echo -e "${C_BLU}== $1 ==${C_OFF}"; }
ok()   { PF_PASS=$((PF_PASS+1)); echo -e "  [${C_GRN} OK ${C_OFF}] $*"; }
fail() { PF_FAILS+=("[${PF_SECTION}] $*"); echo -e "  [${C_RED}FAIL${C_OFF}] $*"; }
wrn()  { PF_WARNS+=("[${PF_SECTION}] $*"); echo -e "  [${C_YEL}WARN${C_OFF}] $*"; }
http_code() { curl -sIL -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 25 "$1" 2>/dev/null || echo 000; }
fs_free_gb() { # free GB of the filesystem that holds (or will hold) the path
  local p="$1"; while [[ ! -e "${p}" && "${p}" != "/" ]]; do p="$(dirname "${p}")"; done
  df -BG --output=avail "${p}" 2>/dev/null | tail -n1 | tr -dc '0-9'
}
listening_ports() { sudo -n ss -Hltn 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -un; }
port_owner() { sudo -n ss -Hltnp 2>/dev/null | awk -v p=":$1$" '$4 ~ p {print $6; exit}' | sed 's/users:((//; s/,.*//'; }

# ---- config-file hygiene -------------------------------------------------
check_config_file() {
  section "config file"
  if [[ -z "${CONFIG_FILE}" ]]; then wrn "no --config given; running with built-in defaults only"; return; fi
  ok "loaded ${CONFIG_FILE}"
  ok "config is parsed as KEY=value, never sourced (no shell expansion of values)"
  [[ ${#CONFIG_UNKNOWN[@]} -eq 0 ]] && ok "all variable names recognised" || wrn "unrecognised variable(s) in config (typo?): ${CONFIG_UNKNOWN[*]}"
  if [[ -n "${SECRETS_FILE}" ]]; then
    ok "secrets loaded from ${SECRETS_FILE}"
    [[ "$(file_mode "${SECRETS_FILE}")" =~ ^[4-7]00$ ]] || wrn "${SECRETS_FILE} is readable by others (mode $(file_mode "${SECRETS_FILE}")); chmod 600 it"
  fi
  [[ ${#CONFIG_SECRETS_IN_MAIN[@]} -eq 0 ]] || wrn "secrets (${CONFIG_SECRETS_IN_MAIN[*]}) are in the main config — move them to ascent-secrets.conf (mode 600) or ASCENT_<VAR> environment variables"
  [[ "$(file_mode "${CONFIG_FILE}")" =~ ^[4-7][0-4][0-4]$ ]] || { [[ ${#CONFIG_SECRETS_IN_MAIN[@]} -gt 0 ]] && wrn "${CONFIG_FILE} holds secrets but is mode $(file_mode "${CONFIG_FILE}")"; }
  [[ "${ADOPT_EXISTING_CLUSTER}" =~ ^(true|false)$ ]] || fail "ADOPT_EXISTING_CLUSTER must be true|false"
  [[ "${SKIP_CHECKSUM_VERIFY}" =~ ^(true|false)$ ]] || fail "SKIP_CHECKSUM_VERIFY must be true|false"
  # placeholder values left from the example
  local ph=""
  [[ "${DOMAIN}" == "ascent.example.com" ]] && ph="${ph} DOMAIN"
  [[ "${ADMIN_PASSWORD}" == "change-me" ]] && ph="${ph} ADMIN_PASSWORD"
  [[ "${PG_PASSWORD}" == "change-me-too" ]] && ph="${ph} PG_PASSWORD"
  [[ "${ADMIN_EMAIL}" == "ops@example.com" ]] && ph="${ph} ADMIN_EMAIL"
  [[ "${S3_BUCKET}" == "my-ascent-bucket" ]] && ph="${ph} S3_BUCKET"
  [[ "${TLS_CERT_FILE}" == "/path/to/tls.crt" ]] && ph="${ph} TLS_CERT_FILE"
  [[ -z "${ph}" ]] && ok "no example placeholders left" || fail "example placeholder values still set:${ph}"
}

# ---- host ------------------------------------------------------------------
check_host() {
  section "host"
  local arch; arch="$(uname -m)"
  [[ "${arch}" == "x86_64" ]] && ok "architecture x86_64" || fail "only x86_64 is supported (got ${arch})"

  local os_id="" os_ver="" pretty=""
  # shellcheck disable=SC1091
  [[ -f /etc/os-release ]] && { os_id="$(. /etc/os-release; echo "${ID:-}")"; os_ver="$(. /etc/os-release; echo "${VERSION_ID:-}")"; pretty="$(. /etc/os-release; echo "${PRETTY_NAME:-}")"; }
  case "${os_id}" in
    ubuntu) [[ "${os_ver%%.*}" -ge 22 ]] && ok "OS: ${pretty}" || wrn "OS: ${pretty} — Ubuntu 22.04+ recommended" ;;
    debian) [[ "${os_ver%%.*}" -ge 11 ]] && ok "OS: ${pretty}" || wrn "OS: ${pretty} — Debian 11+ recommended" ;;
    amzn)   [[ "${os_ver}" == 2023 ]] && ok "OS: ${pretty}" || wrn "OS: ${pretty} — Amazon Linux 2023 recommended (Amazon Linux 2 is end of life)" ;;
    rhel|rocky|almalinux|centos|ol) ok "OS: ${pretty} (RHEL family — firewall/SELinux notes below)" ;;
    *) wrn "OS: ${pretty:-unknown} — untested distribution" ;;
  esac
  [[ "$(uname -r | cut -d. -f1)" -ge 5 ]] && ok "kernel $(uname -r)" || wrn "kernel $(uname -r) is old; 5.x+ recommended"

  if [[ ${EUID} -eq 0 ]]; then ok "running as root"
  elif sudo -n true 2>/dev/null; then ok "passwordless sudo works"
  else fail "passwordless sudo is required (sudo -n true failed)"; fi

  local missing="" cmd
  for cmd in curl tar iptables awk ss openssl ip base64 getent; do
    command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  if [[ -z "${missing}" ]]; then ok "required commands present"
  elif command -v dnf >/dev/null 2>&1; then fail "missing commands:${missing} — dnf install -y curl tar iptables-nft gawk iproute openssl"
  else fail "missing commands:${missing} — apt install -y curl tar iptables gawk iproute2 openssl"; fi
  local cv; cv="$(curl --version 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ -n "${cv}" ]]; then
    if [[ "$(printf '%s\n' "7.75.0" "${cv}" | sort -V | head -n1)" == "7.75.0" ]]; then ok "curl ${cv} (supports --aws-sigv4)"
    else wrn "curl ${cv} is older than 7.75 — S3 credential test will fall back to python3/boto3 if available"; fi
  fi

  local cpus ram_mib
  cpus="$(nproc)"; ram_mib="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  if   [[ "${cpus}" -lt "${MIN_CPU}" ]]; then fail "${cpus} CPUs — minimum ${MIN_CPU} (workload requests ~4 cores)"
  elif [[ "${cpus}" -lt "${REC_CPU}" ]]; then wrn "${cpus} CPUs — ${REC_CPU}+ recommended"
  else ok "${cpus} CPUs"; fi
  if   [[ "${ram_mib}" -lt "${MIN_RAM_MIB}" ]]; then fail "$((ram_mib/1024)) GiB RAM — minimum $((MIN_RAM_MIB/1024)) GiB (pod requests total ~13-17 GiB; pods would stay Pending)"
  elif [[ "${ram_mib}" -lt "${REC_RAM_MIB}" ]]; then wrn "$((ram_mib/1024)) GiB RAM — 16 GB+ recommended"
  else ok "$((ram_mib/1024)) GiB RAM"; fi

  local d1 d2
  d1="$(fs_free_gb /var/lib/k0s)"; d2="$(fs_free_gb /var/openebs)"
  if   [[ "${d1:-0}" -lt "${MIN_DISK_GB}" ]]; then fail "${d1:-?} GB free for /var/lib/k0s — need ${MIN_DISK_GB}+ (container images alone use ~20 GB)"
  else ok "${d1} GB free for /var/lib/k0s (images/etcd)"; fi
  if   [[ "${d2:-0}" -lt "${MIN_DISK_GB}" ]]; then fail "${d2:-?} GB free for /var/openebs (persistent volumes) — need ${MIN_DISK_GB}+"
  elif [[ "${d2:-0}" -lt "${REC_DISK_GB}" ]]; then wrn "${d2} GB free for /var/openebs — the PVCs request ~280-360 GiB in total; hostpath does not enforce quotas, so a full disk will corrupt data"
  else ok "${d2} GB free for /var/openebs (persistent volumes)"; fi
  local dl; dl="$(fs_free_gb "${INSTALL_DIR}")"
  [[ "${dl:-0}" -ge 2 ]] && ok "${dl} GB free in ${INSTALL_DIR} (downloads)" || fail "less than 2 GB free in ${INSTALL_DIR} for downloads"

  if [[ -n "$(swapon --noheadings --show 2>/dev/null)" ]]; then
    fail "swap is enabled — kubelet refuses to start with swap on (sudo swapoff -a; remove the swap line from /etc/fstab)"
  else ok "swap disabled"; fi

  local mods="br_netfilter overlay ip_tables nf_conntrack" m badm=""
  network_fixes_enabled && mods="${mods} ipip"
  for m in ${mods}; do
    lsmod | grep -q "^${m}\b" || sudo -n modprobe -n "${m}" >/dev/null 2>&1 || badm="${badm} ${m}"
  done
  [[ -z "${badm}" ]] && ok "kernel modules available (${mods// /, })" || fail "kernel modules unavailable:${badm}"
  [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" =~ cgroup2fs|tmpfs ]] && ok "cgroups mounted ($(stat -fc %T /sys/fs/cgroup))" || wrn "cannot detect cgroup filesystem"

  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
    wrn "SELinux is Enforcing — k0s works but requires container-selinux; set permissive if pods fail to start"
  else ok "SELinux not enforcing"; fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    fail "firewalld is active — it overrides the installer's iptables rules and breaks pod networking (disable it or open 6443,9443,8132,10250,179,80,443 + pod/service CIDRs)"
  elif command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q "^Status: active"; then
    fail "ufw is active — disable it (sudo ufw disable) or allow the k8s ports and pod/service CIDRs"
  else ok "no host firewall manager active (firewalld/ufw)"; fi
  if ! command -v netfilter-persistent >/dev/null 2>&1 && ! systemctl list-unit-files iptables.service 2>/dev/null | grep -q iptables; then
    wrn "no iptables persistence service (iptables-persistent on Debian/Ubuntu, iptables-services on RHEL/Amazon Linux) — the installer's chain is re-created on every run but not across reboots"
  fi
  if systemctl is-active --quiet docker 2>/dev/null; then
    wrn "docker is running — it sets the iptables FORWARD policy to DROP on restart, which breaks pod traffic"
  fi
  local other=""
  for cmd in k3s microk8s kubeadm minikube; do command -v "${cmd}" >/dev/null 2>&1 && other="${other} ${cmd}"; done
  [[ -d /etc/kubernetes/manifests ]] && other="${other} kubeadm-manifests"
  [[ -z "${other}" ]] && ok "no other Kubernetes distribution detected" || wrn "other Kubernetes tooling present:${other} — conflicts with k0s are likely"

  local px=""
  for v in http_proxy https_proxy HTTP_PROXY HTTPS_PROXY; do [[ -n "${!v:-}" ]] && px="${px} ${v}"; done
  [[ -z "${px}" ]] && ok "no proxy environment variables" || wrn "proxy variables set (${px# }) — containerd image pulls ignore them; configure a containerd proxy drop-in"

  local sync; sync="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)"
  case "${sync}" in
    yes) ok "system clock is NTP-synchronised" ;;
    no)  wrn "system clock is NOT NTP-synchronised — TLS and S3 request signing fail with clock skew (enable chrony/systemd-timesyncd)" ;;
    *)   wrn "cannot determine time sync status (timedatectl unavailable)" ;;
  esac

  local hn; hn="$(hostname)"
  [[ "${hn}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$ ]] \
    && ok "hostname '${hn}' is a valid lowercase node name" \
    || wrn "hostname '${hn}' has uppercase/invalid characters — k0s will lowercase it as the node name"
  if getent ahostsv4 "${hn}" 2>/dev/null | awk '{print $1}' | grep -qx "${PRIVATE_IP}"; then ok "hostname resolves to ${PRIVATE_IP}"
  elif getent ahostsv4 "${hn}" >/dev/null 2>&1; then wrn "hostname '${hn}' resolves to $(getent ahostsv4 "${hn}" | awk '{print $1}' | sort -u | tr '\n' ' ')— not ${PRIVATE_IP} (check /etc/hosts)"
  else wrn "hostname '${hn}' does not resolve — add '${PRIVATE_IP} ${hn}' to /etc/hosts"; fi

  # existing installations
  if command -v k0s >/dev/null 2>&1; then
    if k0s_running; then
      local role single; role="$(sudo -n k0s status 2>/dev/null | awk '/^Role:/{print $2}')"; single="$(sudo -n k0s status 2>/dev/null | awk '/^SingleNode:/{print $2}')"
      if cluster_known; then ok "k0s $(k0s version 2>/dev/null) already running (role=${role}, single=${single}) — cluster $(marked created.k0s-cluster && echo created || echo adopted) by this installer, will be reused"
      elif [[ "${ADOPT_EXISTING_CLUSTER}" == "true" ]]; then ok "k0s $(k0s version 2>/dev/null) already running (role=${role}, single=${single}) — NOT created by this installer; ADOPT_EXISTING_CLUSTER=true so it will be adopted (cleanup will never reset it)"
      else fail "a running k0s cluster exists that this installer did not create (cluster id $(cluster_uid | cut -c1-8)…) — set ADOPT_EXISTING_CLUSTER=\"true\" to use it, or reset it first"; fi
      if is_multi_node && [[ "${single}" == "true" ]]; then
        fail "existing k0s runs in --single mode; workers cannot join — reset it (sudo k0s stop; sudo k0s reset) before a multi-node install"
      fi
      if [[ "$(k0s version 2>/dev/null)" != "${K0S_VERSION}" ]]; then wrn "running k0s $(k0s version 2>/dev/null) differs from K0S_VERSION=${K0S_VERSION}; the installer never upgrades k0s"; fi
    else
      case "$(k0s_unit)" in
        controller)
          ok "k0s controller service exists but is stopped — the k0s phase will start it (config left untouched)"
          is_multi_node && k0s_unit_is_single && fail "the stopped k0s controller was installed with --single; workers cannot join — reset it (sudo k0s reset) first" ;;
        worker) fail "this host already has a k0s WORKER service — it cannot become the controller (sudo k0s stop; sudo k0s reset)" ;;
        *) ok "k0s binary present, no service installed — will be installed" ;;
      esac
    fi
  else ok "k0s not installed — will download ${K0S_VERSION}"; fi
  if command -v helm >/dev/null 2>&1; then
    local hv; hv="$(helm version --template '{{.Version}}' 2>/dev/null)"
    [[ "${hv}" == v4* ]] && fail "helm ${hv} is installed — Helm 4 is not supported by the chart; remove it so the installer can install ${HELM_VERSION}" || ok "helm ${hv} present"
  else ok "helm not installed — will download ${HELM_VERSION}"; fi
  command -v kubectl >/dev/null 2>&1 && ok "kubectl $(kubectl version --client 2>/dev/null | awk '/Client/{print $3}') present" || ok "kubectl not installed — will download ${KUBECTL_VERSION}"

  # ports
  local listen; listen="$(listening_ports)"
  local app_ports="80 443 9999 8081 14250 20514 14268" k8s_ports="6443 9443 8132 8133 10250 10249 10248 10256 2379 2380 179 7946"
  local busy="" p
  for p in ${app_ports}; do grep -qx "${p}" <<<"${listen}" && busy="${busy} ${p}($(port_owner "${p}"))"; done
  [[ -z "${busy}" ]] && ok "ingress ports free (${app_ports// /,})" || fail "ports needed by the Ascent LoadBalancer are in use:${busy}"
  if ! k0s_running && [[ -z "$(k0s_unit)" ]]; then
    busy=""
    for p in ${k8s_ports}; do grep -qx "${p}" <<<"${listen}" && busy="${busy} ${p}($(port_owner "${p}"))"; done
    [[ -z "${busy}" ]] && ok "kubernetes ports free" || fail "ports needed by k0s are in use:${busy}"
  fi
}

# ---- existing cluster (CLUSTER_MODE=existing) ---------------------------------------
CL_CPU_TOTAL=0; CL_MEM_GIB_TOTAL=0; CL_CPU_MAX=0; CL_MEM_GIB_MAX=0
cluster_capacity() { # allocatable CPU (cores) and memory (GiB): totals and largest node
  local cpu mem c m
  CL_CPU_TOTAL=0; CL_MEM_GIB_TOTAL=0; CL_CPU_MAX=0; CL_MEM_GIB_MAX=0
  while read -r cpu mem; do
    [[ -n "${cpu}" ]] || continue
    if [[ "${cpu}" == *m ]]; then c=$(( ${cpu%m} / 1000 )); else c=${cpu}; fi
    case "${mem}" in *Ki) m=$(( ${mem%Ki} / 1024 / 1024 )) ;; *Mi) m=$(( ${mem%Mi} / 1024 )) ;; *Gi) m=${mem%Gi} ;; *) m=$(( mem / 1024 / 1024 / 1024 )) ;; esac
    CL_CPU_TOTAL=$(( CL_CPU_TOTAL + c )); CL_MEM_GIB_TOTAL=$(( CL_MEM_GIB_TOTAL + m ))
    (( c > CL_CPU_MAX )) && CL_CPU_MAX=${c}; (( m > CL_MEM_GIB_MAX )) && CL_MEM_GIB_MAX=${m}
  done < <(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu} {.status.allocatable.memory}{"\n"}{end}' 2>/dev/null)
}
check_cluster() {
  section "existing cluster"
  local missing="" cmd
  for cmd in curl kubectl helm openssl awk; do command -v "${cmd}" >/dev/null 2>&1 || missing="${missing} ${cmd}"; done
  [[ -z "${missing}" ]] && ok "required commands present" || { fail "missing commands:${missing} (existing-cluster mode does not install kubectl/helm)"; return; }
  local hv; hv="$(helm version --template '{{.Version}}' 2>/dev/null)"
  [[ "${hv}" == v4* ]] && fail "helm ${hv}: Helm 4 is not supported by the chart" || ok "helm ${hv}"
  local ctx; ctx="$(kubectl config current-context 2>/dev/null || true)"
  if kubectl get --raw /readyz >/dev/null 2>&1; then ok "kubectl context '${ctx}' reachable ($(kubectl version 2>/dev/null | awk '/Server Version/{print $3}'))"
  else fail "kubectl cannot reach a cluster (context '${ctx:-none}') — set KUBECONFIG"; return; fi
  local total ready; total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"; ready="$(kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready || true)"
  [[ "${total}" -gt 0 && "${ready}" == "${total}" ]] && ok "${ready}/${total} nodes Ready" || fail "${ready}/${total} nodes Ready"
  cluster_capacity; ok "allocatable: ${CL_CPU_TOTAL} CPU, ${CL_MEM_GIB_TOTAL} GiB total; largest node ${CL_CPU_MAX} CPU / ${CL_MEM_GIB_MAX} GiB"
  kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 && ok "storage class ${STORAGE_CLASS} exists" \
    || fail "storage class ${STORAGE_CLASS} not found (available: $(kubectl get sc -o name 2>/dev/null | sed 's|storageclass.storage.k8s.io/||' | tr '\n' ' '))"
  if kubectl get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer" && $5!="<pending>"' | grep -q . \
     || kubectl get deploy -A --no-headers 2>/dev/null | grep -qE 'aws-load-balancer-controller|metallb-controller|cloud-controller-manager'; then
    ok "a LoadBalancer implementation is present"
  else wrn "no LoadBalancer implementation detected — the Envoy service will stay <pending> until one exists (cloud LB controller, MetalLB, ...)"; fi
  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 && ok "Gateway API CRDs present" || ok "Gateway API CRDs will be installed with Envoy Gateway"
  kubectl auth can-i create namespace >/dev/null 2>&1 && ok "cluster-admin level permissions" || fail "the kubectl identity cannot create namespaces — cluster-admin is required for the install"
  [[ "${CLOUD_PROVIDER}" =~ ^(none|aws|oci)$ ]] && ok "CLOUD_PROVIDER ${CLOUD_PROVIDER}" || fail "CLOUD_PROVIDER must be none|aws|oci"
  [[ -z "${WORKERS}" ]] || fail "WORKERS is only used in CLUSTER_MODE=k0s"
  [[ -z "${LB_IP}" ]] || ok "LB_IP ${LB_IP} will be used for probes"
}

# ---- network -----------------------------------------------------------------
check_network() {
  section "network"
  if ip -o -4 addr show 2>/dev/null | grep -q " ${PRIVATE_IP}/"; then ok "PRIVATE_IP ${PRIVATE_IP} is on interface ${PRIMARY_IF}"
  else
    local detected; detected="$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([^ ]*\).*/\1/p' || true)"
    fail "PRIVATE_IP ${PRIVATE_IP} is not assigned to any interface on this host (its primary address is ${detected:-unknown}) — the config was written for another machine; remove or comment PRIVATE_IP, PUBLIC_IP and LB_IP so they are auto-detected"
  fi
  is_ipv4 "${PRIVATE_IP}" || fail "PRIVATE_IP '${PRIVATE_IP}' is not an IPv4 address"
  is_cidr "${NODE_SUBNET}" && ok "node subnet ${NODE_SUBNET}" || fail "NODE_SUBNET '${NODE_SUBNET}' is not a valid CIDR"
  is_cidr "${POD_CIDR}"     && ok "pod CIDR ${POD_CIDR}"        || fail "POD_CIDR '${POD_CIDR}' is not a valid CIDR"
  is_cidr "${SERVICE_CIDR}" && ok "service CIDR ${SERVICE_CIDR}" || fail "SERVICE_CIDR '${SERVICE_CIDR}' is not a valid CIDR"
  if is_cidr "${NODE_SUBNET}" && is_cidr "${POD_CIDR}" && is_cidr "${SERVICE_CIDR}"; then
    cidrs_overlap "${POD_CIDR}" "${SERVICE_CIDR}" && fail "POD_CIDR and SERVICE_CIDR overlap" || ok "pod/service CIDRs do not overlap"
    cidrs_overlap "${POD_CIDR}" "${NODE_SUBNET}" && fail "POD_CIDR ${POD_CIDR} overlaps the node subnet ${NODE_SUBNET} — choose another POD_CIDR" || ok "pod CIDR does not overlap the node subnet"
    cidrs_overlap "${SERVICE_CIDR}" "${NODE_SUBNET}" && fail "SERVICE_CIDR ${SERVICE_CIDR} overlaps the node subnet ${NODE_SUBNET} — choose another SERVICE_CIDR" || ok "service CIDR does not overlap the node subnet"
    # other local routes colliding with the pod/service CIDRs
    local r; while read -r r; do
      [[ -z "${r}" || "${r}" == default ]] && continue
      is_cidr "${r}" || continue
      [[ "${r}" == "${NODE_SUBNET}" ]] && continue
      if grep -q "^${POD_CIDR%%/*}" <<<"${r}" || grep -q "^${SERVICE_CIDR%%/*}" <<<"${r}"; then :; fi
      if cidrs_overlap "${r}" "${POD_CIDR}" && ! k0s_running; then wrn "existing route ${r} overlaps POD_CIDR"; fi
    done < <(ip -o -4 route show 2>/dev/null | awk '{print $1}')
  fi
  if is_ipv4 "${LB_IP}"; then
    if [[ "${LB_IP}" == "${PRIVATE_IP}" ]]; then ok "LB_IP ${LB_IP} (controller IP; MetalLB L2 announces it)"
    else
      cidr_contains "${NODE_SUBNET}" "${LB_IP}" && ok "LB_IP ${LB_IP} is inside ${NODE_SUBNET}" || fail "LB_IP ${LB_IP} is outside the node subnet ${NODE_SUBNET} — L2 announcement will not work"
      if ping -c1 -W1 "${LB_IP}" >/dev/null 2>&1 && ! have_kubectl; then fail "LB_IP ${LB_IP} already answers to ping — it must be an unused address"; else ok "LB_IP ${LB_IP} not in use"; fi
    fi
  else fail "LB_IP '${LB_IP}' is not an IPv4 address"; fi
  if [[ -z "${PUBLIC_IP}" ]]; then ok "PUBLIC_IP <unset>"
  elif is_ipv4 "${PUBLIC_IP}"; then ok "PUBLIC_IP ${PUBLIC_IP}"
  else fail "PUBLIC_IP '${PUBLIC_IP}' is not an IPv4 address"; fi
  [[ "${APPLY_NETWORK_FIXES}" =~ ^(auto|true|false)$ ]] && ok "APPLY_NETWORK_FIXES=${APPLY_NETWORK_FIXES} → cloud source/destination-check fixes $(network_fixes_enabled && echo ENABLED || echo disabled)$(cloud_name | sed 's/.\+/ (& detected)/')" \
    || fail "APPLY_NETWORK_FIXES must be auto|true|false"

  if [[ -n "$(resolve4 github.com)" ]]; then ok "DNS resolution works"; else fail "DNS resolution failed (github.com) — check /etc/resolv.conf"; fi
  # downloads only needed when the binary is missing
  local c
  if ! command -v k0s >/dev/null 2>&1; then
    c="$(http_code "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION/+/%2B}/k0s-${K0S_VERSION}-amd64")"
    [[ "${c}" == 200 ]] && ok "k0s ${K0S_VERSION} download reachable" || fail "cannot download k0s ${K0S_VERSION} from github.com (HTTP ${c}) — wrong version or no internet"
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    c="$(http_code "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl")"
    [[ "${c}" == 200 ]] && ok "kubectl ${KUBECTL_VERSION} download reachable" || fail "cannot download kubectl ${KUBECTL_VERSION} (HTTP ${c})"
  fi
  if ! command -v helm >/dev/null 2>&1; then
    c="$(http_code "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz")"
    [[ "${c}" == 200 ]] && ok "helm ${HELM_VERSION} download reachable" || fail "cannot download helm ${HELM_VERSION} (HTTP ${c})"
  fi
  for u in "https://openebs.github.io/charts/index.yaml" "https://metallb.github.io/metallb/index.yaml"; do
    c="$(http_code "${u}")"; [[ "${c}" == 200 ]] && ok "chart repo reachable: ${u%/index.yaml}" || fail "chart repo unreachable (HTTP ${c}): ${u}"
  done
  if [[ "${DB_ENGINE}" == "cnpg" ]]; then
    c="$(http_code "https://cloudnative-pg.github.io/charts/index.yaml")"; [[ "${c}" == 200 ]] && ok "cloudnative-pg chart repo reachable" || fail "cloudnative-pg chart repo unreachable (HTTP ${c})"
  fi
  if [[ "${CHART_SOURCE}" == "repo" ]]; then
    local idx; idx="$(curl -fsSL --max-time 25 "${CHART_REPO_URL}/index.yaml" 2>/dev/null || true)"
    if [[ -z "${idx}" ]]; then fail "cannot fetch ${CHART_REPO_URL}/index.yaml"
    elif grep -qE "^    version: ${CHART_VERSION}\$" <<<"${idx}"; then ok "chart apica-ascent ${CHART_VERSION} is published at ${CHART_REPO_URL}"
    else fail "chart version ${CHART_VERSION} not found in ${CHART_REPO_URL} (available: $(grep -E '^    version: [0-9]' <<<"${idx}" | awk '{print $2}' | sort -V | tail -n5 | tr '\n' ' ' | sed 's/ $//'))"; fi
  elif [[ "${CHART_SOURCE}" == "path" ]]; then
    [[ -f "${CHART_PATH}/Chart.yaml" ]] && ok "local chart at ${CHART_PATH}" || fail "CHART_PATH '${CHART_PATH}' has no Chart.yaml"
  else fail "CHART_SOURCE must be repo|path"; fi
  # container registries (any HTTP answer = reachable; 401 is expected)
  for u in "https://registry-1.docker.io/v2/" "https://quay.io/v2/"; do
    c="$(http_code "${u}")"; [[ "${c}" != 000 ]] && ok "registry reachable: ${u} (HTTP ${c})" || fail "registry unreachable: ${u} — image pulls will fail"
  done
  if [[ "${DB_ENGINE}" == "cnpg" ]]; then
    c="$(http_code "https://ghcr.io/v2/")"; [[ "${c}" != 000 ]] && ok "registry reachable: ghcr.io" || fail "registry unreachable: ghcr.io (CloudNativePG images)"
  fi
  local hc; hc="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 25 "https://auth.docker.io/token?service=registry.docker.io&scope=repository:logiqai/flash:pull" 2>/dev/null || echo 000)"
  [[ "${hc}" == 200 ]] && ok "docker hub token service OK (note: anonymous pulls are rate-limited to 100/6h per IP)" || wrn "docker hub token service returned HTTP ${hc}"
  if [[ -z "${PUBLIC_IP}" ]]; then
    local det; det="$(curl -s --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')"
    if is_ipv4 "${det}" && [[ "${det}" != "${PRIVATE_IP}" ]]; then DETECTED_PUBLIC_IP="${det}"; ok "egress public IP appears to be ${det} (informational; set PUBLIC_IP to add it to the API SANs)"; fi
  fi
}
DETECTED_PUBLIC_IP=""

# ---- application config -----------------------------------------------------------
check_app_config() {
  section "application settings"
  if [[ -z "${DOMAIN}" ]]; then fail "DOMAIN is required"
  elif is_ipv4 "${DOMAIN}"; then fail "DOMAIN must be a hostname, not an IP address (Gateway API hostnames and TLS certs need a name)"
  elif [[ ! "${DOMAIN}" =~ ^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?(\.[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?)*$ ]]; then fail "DOMAIN '${DOMAIN}' is not a valid lowercase DNS name"
  else
    ok "DOMAIN ${DOMAIN}"
    [[ "${DOMAIN}" == *.* ]] || wrn "DOMAIN has no dot — browsers and certificates expect a fully-qualified name"
    local res; res="$(resolve4 "${DOMAIN}" | tr '\n' ' ' | sed 's/ $//')"
    if [[ -z "${res}" ]]; then wrn "DOMAIN does not resolve yet — create a DNS A record → ${PUBLIC_IP:-${DETECTED_PUBLIC_IP:-${LB_IP:-the gateway address reported after install}}} before users log in"
    elif existing_cluster || grep -qw -e "${LB_IP:-__}" -e "${PUBLIC_IP:-__}" -e "${DETECTED_PUBLIC_IP:-__}" <<<"${res}"; then ok "DOMAIN resolves to ${res}"
    else wrn "DOMAIN resolves to ${res}— expected ${LB_IP}${PUBLIC_IP:+ or ${PUBLIC_IP}}${DETECTED_PUBLIC_IP:+ or ${DETECTED_PUBLIC_IP}} (fine if a NAT/LB sits in front)"; fi
  fi

  [[ -n "${ADMIN_NAME}" && ! "${ADMIN_NAME}" =~ [[:space:]] ]] && ok "ADMIN_NAME ${ADMIN_NAME}" || fail "ADMIN_NAME must be set and contain no spaces"
  [[ -n "${ADMIN_ORG}" ]] && ok "ADMIN_ORG ${ADMIN_ORG}" || fail "ADMIN_ORG is required"
  [[ "${ADMIN_EMAIL}" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] && ok "ADMIN_EMAIL ${ADMIN_EMAIL}" || fail "ADMIN_EMAIL '${ADMIN_EMAIL}' is not a valid email address"

  if [[ -z "${ADMIN_PASSWORD}" ]]; then fail "ADMIN_PASSWORD is required"
  else
    local why=""
    [[ ${#ADMIN_PASSWORD} -ge 12 ]]            || why="${why} <12-chars"
    [[ "${ADMIN_PASSWORD}" =~ [A-Z] ]]         || why="${why} no-uppercase"
    [[ "${ADMIN_PASSWORD}" =~ [a-z] ]]         || why="${why} no-lowercase"
    [[ "${ADMIN_PASSWORD}" =~ [0-9] ]]         || why="${why} no-digit"
    [[ "${ADMIN_PASSWORD}" =~ [^A-Za-z0-9] ]]  || why="${why} no-special-char"
    [[ -z "${why}" ]] && ok "ADMIN_PASSWORD meets the policy (12+ chars, upper, lower, digit, special)" \
      || fail "ADMIN_PASSWORD violates the Ascent policy:${why} (needs 12+ chars with uppercase, lowercase, digit and special character)"
    [[ "${ADMIN_PASSWORD}" =~ ^[[:space:]]|[[:space:]]$ ]] && wrn "ADMIN_PASSWORD has leading/trailing whitespace"
  fi
  if [[ -z "${PG_PASSWORD}" ]]; then fail "PG_PASSWORD is required"
  elif [[ ! "${PG_PASSWORD}" =~ ^[A-Za-z0-9._~-]+$ ]]; then fail "PG_PASSWORD may only contain [A-Za-z0-9 . _ ~ -] — it is embedded unescaped in postgresql:// connection URLs by the chart"
  elif [[ ${#PG_PASSWORD} -lt 8 ]]; then fail "PG_PASSWORD must be at least 8 characters"
  else ok "PG_PASSWORD is URL-safe (${#PG_PASSWORD} chars)"; [[ ${#PG_PASSWORD} -lt 16 ]] && wrn "PG_PASSWORD is shorter than 16 characters"; fi

  [[ "${DB_ENGINE}" =~ ^(bitnami|cnpg)$ ]] && ok "DB_ENGINE ${DB_ENGINE}" || fail "DB_ENGINE must be bitnami|cnpg (got '${DB_ENGINE}')"
  [[ "${UPLOAD_DASHBOARD}" =~ ^(true|false)$ ]] && ok "UPLOAD_DASHBOARD ${UPLOAD_DASHBOARD}" || fail "UPLOAD_DASHBOARD must be true|false"
  [[ "${TLS_SELF_SIGNED}" =~ ^(true|false)$ ]] || fail "TLS_SELF_SIGNED must be true|false"
  [[ "${RELEASE_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] && ok "release ${RELEASE_NAME} in namespace ${NAMESPACE}" || fail "RELEASE_NAME/NAMESPACE must be lowercase DNS labels"
  # chart 3.1.x: the Thanos sidecar reads <namespace>-thanos-objstore-secret while the Thanos subchart creates
  # <release>-thanos-objstore-secret; the names only coincide when release and namespace are equal
  [[ "${RELEASE_NAME}" == "${NAMESPACE}" ]] || fail "RELEASE_NAME (${RELEASE_NAME}) must equal NAMESPACE (${NAMESPACE}) with chart 3.1.x: the Prometheus Thanos sidecar looks for <namespace>-thanos-objstore-secret but the chart creates <release>-thanos-objstore-secret"
  if [[ -n "${EXTRA_VALUES_FILE}" ]]; then [[ -f "${EXTRA_VALUES_FILE}" ]] && ok "extra values file ${EXTRA_VALUES_FILE}" || fail "EXTRA_VALUES_FILE not found: ${EXTRA_VALUES_FILE}"; fi
  if have_kubectl; then
    local st; st="$(helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null | awk '/^STATUS:/{print $2}')"
    [[ -n "${st}" ]] && wrn "release ${RELEASE_NAME} already exists in ${NAMESPACE} (status ${st}) — 'deploy' will upgrade it in place"
  fi
}

# ---- sizing ------------------------------------------------------------------------
check_sizing() {
  section "sizing (Apica capacity planning guide)"
  if [[ -z "${INGEST_GB_PER_DAY}" ]]; then
    wrn "INGEST_GB_PER_DAY not set — the chart's default flash rate limit applies (346729 B/s ≈ 30 GB/day in chart 3.1.5, 745654 B/s ≈ 64 GB/day in newer charts); set the expected daily volume so replicas, resources, disk and the rate limit are derived from it"
    return
  fi
  [[ "${INGEST_GB_PER_DAY}" =~ ^[0-9]+$ ]] || { fail "INGEST_GB_PER_DAY must be a whole number of GB (got '${INGEST_GB_PER_DAY}')"; return; }
  [[ "${INGEST_MODE}" =~ ^(lake|flow)$ ]] || { fail "INGEST_MODE must be lake|flow"; return; }
  [[ "${WORKLOAD_TIER}" =~ ^[1-5]$ ]] || { fail "WORKLOAD_TIER must be 1-5"; return; }
  [[ "${INGEST_DESTINATIONS}" =~ ^[0-9]+$ && "${PEAK_MULTIPLIER}" =~ ^[0-9]+$ ]] || { fail "INGEST_DESTINATIONS and PEAK_MULTIPLIER must be whole numbers"; return; }
  [[ "${SZ_ENABLED}" == "true" ]] || { fail "sizing could not be computed"; return; }
  ok "sizing plan:"; sizing_summary | sed 's/^/        /'
  (( INGEST_GB_PER_DAY > 10000 )) && wrn "deployments above 10 TB/day require an architecture review with Apica engineering"
  local cpus=0 ram_gib=0
  if ! existing_cluster; then cpus="$(nproc)"; ram_gib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 / 1024 )); fi
  if existing_cluster; then
    cluster_capacity
    (( SZ_POD_CPU <= CL_CPU_MAX )) || fail "a flash pod needs ${SZ_POD_CPU} CPU but the largest node offers ${CL_CPU_MAX} allocatable"
    (( SZ_POD_MEM_GI <= CL_MEM_GIB_MAX )) || fail "a flash pod needs ${SZ_POD_MEM_GI} GiB but the largest node offers ${CL_MEM_GIB_MAX} GiB allocatable"
    (( SZ_TOTAL_VCPU <= CL_CPU_TOTAL )) || wrn "guide total ${SZ_TOTAL_VCPU} vCPU exceeds the cluster's ${CL_CPU_TOTAL} allocatable CPU"
    (( SZ_TOTAL_RAM_GB <= CL_MEM_GIB_TOTAL )) || wrn "guide total ${SZ_TOTAL_RAM_GB} GB RAM exceeds the cluster's ${CL_MEM_GIB_TOTAL} GiB allocatable"
  elif ! is_multi_node; then
    (( SZ_POD_CPU <= cpus - 2 )) || fail "a flash pod needs ${SZ_POD_CPU} CPU but this node has ${cpus} (2 reserved) — it would never schedule; max for this node ≈ $(( (cpus - 2) * 50 / PEAK_MULTIPLIER )) GB/day in lake mode"
    (( SZ_POD_MEM_GI <= ram_gib - 6 )) || fail "a flash pod needs ${SZ_POD_MEM_GI} GiB but this node has ${ram_gib} GiB (6 reserved for core services)"
    (( SZ_TOTAL_VCPU <= cpus )) || wrn "guide total ${SZ_TOTAL_VCPU} vCPU (ingest + 10 core) exceeds this node's ${cpus} CPUs — acceptable for a sandbox, undersized for production"
    (( SZ_TOTAL_RAM_GB <= ram_gib )) || wrn "guide total ${SZ_TOTAL_RAM_GB} GB RAM exceeds this node's ${ram_gib} GiB"
    local free; free="$(fs_free_gb /var/openebs)"
    (( SZ_TOTAL_DISK_GB <= ${free:-0} )) || wrn "guide total ${SZ_TOTAL_DISK_GB} GB disk exceeds the ${free:-?} GB free under /var/openebs"
  else
    ok "multi-node: ${SZ_PODS} flash pod(s) will be spread over the 'ingest' pool; each ingest node needs ≥ $(( SZ_POD_CPU + 1 )) CPU and $(( SZ_POD_MEM_GI + 2 )) GiB"
  fi
}

# ---- TLS -------------------------------------------------------------------------
check_tls() {
  section "TLS certificate"
  if [[ -z "${TLS_CERT_FILE}" && -z "${TLS_KEY_FILE}" ]]; then
    if [[ "${TLS_SELF_SIGNED}" == "true" ]]; then wrn "no certificate configured — a self-signed cert for ${DOMAIN} will be generated (browsers will warn; agents need TLS verification disabled)"
    else fail "no TLS certificate: set TLS_CERT_FILE + TLS_KEY_FILE, or TLS_SELF_SIGNED=true for a test install"; fi
    return
  fi
  [[ -f "${TLS_CERT_FILE}" ]] || { fail "TLS_CERT_FILE not found: ${TLS_CERT_FILE}"; return; }
  [[ -f "${TLS_KEY_FILE}"  ]] || { fail "TLS_KEY_FILE not found: ${TLS_KEY_FILE}"; return; }
  if ! openssl x509 -in "${TLS_CERT_FILE}" -noout >/dev/null 2>&1; then fail "TLS_CERT_FILE is not a PEM certificate"; return; fi
  if grep -q "ENCRYPTED" "${TLS_KEY_FILE}"; then fail "TLS_KEY_FILE is passphrase-protected — Kubernetes TLS secrets need an unencrypted key (openssl pkey -in key -out key.plain)"; return; fi
  if ! openssl pkey -in "${TLS_KEY_FILE}" -noout >/dev/null 2>&1; then fail "TLS_KEY_FILE is not a readable PEM private key"; return; fi
  local cm km; cm="$(openssl x509 -in "${TLS_CERT_FILE}" -noout -pubkey 2>/dev/null | openssl md5)"; km="$(openssl pkey -in "${TLS_KEY_FILE}" -pubout 2>/dev/null | openssl md5)"
  [[ "${cm}" == "${km}" ]] && ok "certificate and private key match" || fail "TLS_KEY_FILE does not match TLS_CERT_FILE (public key mismatch)"
  local subj; subj="$(openssl x509 -in "${TLS_CERT_FILE}" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  if openssl x509 -in "${TLS_CERT_FILE}" -noout -checkend 0 >/dev/null 2>&1; then
    openssl x509 -in "${TLS_CERT_FILE}" -noout -checkend 2592000 >/dev/null 2>&1 && ok "certificate valid until $(openssl x509 -in "${TLS_CERT_FILE}" -noout -enddate | cut -d= -f2)" \
      || wrn "certificate expires within 30 days ($(openssl x509 -in "${TLS_CERT_FILE}" -noout -enddate | cut -d= -f2))"
  else fail "certificate has EXPIRED ($(openssl x509 -in "${TLS_CERT_FILE}" -noout -enddate | cut -d= -f2))"; fi
  if [[ -n "${DOMAIN}" ]]; then
    if openssl x509 -in "${TLS_CERT_FILE}" -noout -checkhost "${DOMAIN}" 2>/dev/null | grep -q "does match"; then ok "certificate covers ${DOMAIN} (${subj})"
    else fail "certificate does not cover DOMAIN ${DOMAIN} — subject ${subj}; SAN: $(openssl x509 -in "${TLS_CERT_FILE}" -noout -ext subjectAltName 2>/dev/null | tail -n1 | tr -d ' ')"; fi
  fi
  local n iss; n="$(grep -c 'BEGIN CERTIFICATE' "${TLS_CERT_FILE}")"; iss="$(openssl x509 -in "${TLS_CERT_FILE}" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  if [[ "${n}" -ge 2 ]]; then ok "certificate file contains a chain (${n} certificates)"
  elif [[ "${subj}" == "${iss}" ]]; then wrn "certificate is self-signed"
  elif [[ -n "${TLS_CA_FILE}" ]]; then ok "leaf certificate only; intermediates supplied via TLS_CA_FILE"
  else wrn "certificate file has no intermediate chain (issuer: ${iss}) — append the intermediate CA certs or set TLS_CA_FILE, otherwise clients may see an incomplete chain"; fi
  if [[ -n "${TLS_CA_FILE}" ]]; then
    [[ -f "${TLS_CA_FILE}" ]] || { fail "TLS_CA_FILE not found: ${TLS_CA_FILE}"; return; }
    openssl x509 -in "${TLS_CA_FILE}" -noout >/dev/null 2>&1 && ok "TLS_CA_FILE is PEM" || fail "TLS_CA_FILE is not a PEM certificate"
    if openssl verify -untrusted "${TLS_CA_FILE}" "${TLS_CERT_FILE}" >/dev/null 2>&1; then ok "certificate chain verifies against the system trust store"
    else wrn "chain does not verify against system roots (private CA?) — browsers/agents must trust that CA"; fi
  fi
}

# ---- S3 --------------------------------------------------------------------------
S3_HTTP=""; S3_BODY=""; S3_RC=0
s3_req() { # s3_req <METHOD> <path-and-query> [curl args...]
  local method="$1" path="$2"; shift 2
  local out; out="$(mktemp)"
  local -a ca=(); [[ -n "${S3_CA_FILE}" ]] && ca=(--cacert "${S3_CA_FILE}")
  S3_HTTP="$(curl -s -o "${out}" -w '%{http_code}' --connect-timeout 10 --max-time 45 "${ca[@]}" \
      --aws-sigv4 "aws:amz:${S3_REGION}:s3" --user "${S3_ACCESS}:${S3_SECRET}" \
      -X "${method}" "$@" "${S3_URL}/${S3_BUCKET}${path}" 2>/dev/null)"; S3_RC=$?
  S3_BODY="$(head -c 700 "${out}" 2>/dev/null | tr -d '\n')"; rm -f "${out}"
}
s3_code() { sed -n 's/.*<Code>\([^<]*\)<\/Code>.*/\1/p' <<<"${S3_BODY}"; }
s3_msg()  { sed -n 's/.*<Message>\([^<]*\)<\/Message>.*/\1/p' <<<"${S3_BODY}" | cut -c1-200; }

check_s3() {
  section "S3 object storage"
  local missing="" v
  for v in S3_URL S3_BUCKET S3_REGION S3_ACCESS S3_SECRET; do [[ -n "${!v}" ]] || missing="${missing} ${v}"; done
  [[ -z "${missing}" ]] || { fail "required S3 settings missing:${missing}"; return; }
  S3_URL="${S3_URL%/}"
  if [[ ! "${S3_URL}" =~ ^https?://[^/]+$ ]]; then
    if [[ "${S3_URL}" =~ ^https?://[^/]+/.+ ]]; then fail "S3_URL must be the bare endpoint without a bucket or path (got ${S3_URL})"
    else fail "S3_URL must start with http:// or https:// (got '${S3_URL}')"; fi; return
  fi
  [[ "${S3_URL}" == http://* ]] && wrn "S3_URL uses plain HTTP — credentials and data travel unencrypted"
  ok "S3_URL ${S3_URL}"
  [[ "${S3_BUCKET}" =~ ^[a-z0-9]([a-z0-9.-]{1,61}[a-z0-9])?$ ]] && ok "bucket name ${S3_BUCKET}" || wrn "bucket name '${S3_BUCKET}' does not follow S3 naming rules (lowercase, digits, . and -)"
  # region consistency with the endpoint hostname
  local host="${S3_URL#*://}" ep_region=""
  if   [[ "${host}" =~ objectstorage\.([a-z0-9-]+)\.oraclecloud\.com$ ]]; then ep_region="${BASH_REMATCH[1]}"
  elif [[ "${host}" =~ ^s3[.-]([a-z0-9-]+)\.amazonaws\.com$ ]]; then ep_region="${BASH_REMATCH[1]}"; fi
  if [[ -n "${ep_region}" && "${ep_region}" != "${S3_REGION}" && "${ep_region}" != "external-1" ]]; then
    fail "S3_REGION '${S3_REGION}' does not match the region in the endpoint hostname ('${ep_region}') — request signing will be rejected"
  else ok "S3_REGION ${S3_REGION}"; fi
  # swapped-credential heuristic (OCI: access key = 40 hex chars, secret = base64 with +/=)
  local swapped=""
  if [[ "${S3_ACCESS}" =~ [+/=] && "${S3_SECRET}" =~ ^[0-9a-f]{40}$ ]]; then swapped="yes"
    wrn "S3_ACCESS looks like a secret key and S3_SECRET like an OCI access key — are they swapped?"
  elif [[ "${S3_ACCESS}" =~ [[:space:]] || "${S3_SECRET}" =~ [[:space:]] ]]; then wrn "S3 credentials contain whitespace"; fi
  if [[ -n "${S3_CA_FILE}" ]]; then
    [[ -f "${S3_CA_FILE}" ]] && openssl x509 -in "${S3_CA_FILE}" -noout >/dev/null 2>&1 && ok "S3_CA_FILE is PEM (s3_custom_ca will be configured)" \
      || { fail "S3_CA_FILE missing or not PEM: ${S3_CA_FILE}"; return; }
  fi

  # connectivity + clock skew from the Date header
  local -a ca=(); [[ -n "${S3_CA_FILE}" ]] && ca=(--cacert "${S3_CA_FILE}")
  local hdrs rc; hdrs="$(curl -sI --connect-timeout 10 --max-time 25 "${ca[@]}" "${S3_URL}/" 2>&1)"; rc=$?
  case ${rc} in
    0)  ok "endpoint ${host} reachable over TLS" ;;
    6)  fail "cannot resolve S3 host ${host} (DNS)"; return ;;
    7)  fail "connection to ${S3_URL} refused"; return ;;
    28) fail "connection to ${S3_URL} timed out — firewall/proxy/egress rules?"; return ;;
    60) fail "TLS certificate of ${host} is not trusted by this host — for a private CA set S3_CA_FILE=/path/to/ca.pem (the installer then configures s3_custom_ca)"; return ;;
    35|51) fail "TLS handshake with ${host} failed (curl exit ${rc})"; return ;;
    *)  fail "cannot reach ${S3_URL} (curl exit ${rc})"; return ;;
  esac
  local rdate; rdate="$(grep -i '^date:' <<<"${hdrs}" | head -n1 | cut -d' ' -f2- | tr -d '\r')"
  if [[ -n "${rdate}" ]]; then
    local skew; skew=$(( $(date +%s) - $(date -d "${rdate}" +%s 2>/dev/null || date +%s) )); skew=${skew#-}
    [[ ${skew} -le 300 ]] && ok "clock skew vs S3 endpoint ${skew}s" || fail "clock skew vs S3 endpoint is ${skew}s — request signing rejects >900s and TLS breaks; fix NTP"
  fi

  local cv; cv="$(curl --version 2>/dev/null | awk 'NR==1{print $2}')"
  if [[ "$(printf '%s\n' "7.75.0" "${cv}" | sort -V | head -n1)" != "7.75.0" ]]; then
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import boto3' 2>/dev/null; then
      if S3_URL="${S3_URL}" S3_BUCKET="${S3_BUCKET}" S3_REGION="${S3_REGION}" S3_ACCESS="${S3_ACCESS}" S3_SECRET="${S3_SECRET}" S3_CA_FILE="${S3_CA_FILE}" python3 - <<'PYEOF'
import os, sys, boto3, botocore
s3 = boto3.client("s3", endpoint_url=os.environ["S3_URL"], aws_access_key_id=os.environ["S3_ACCESS"],
    aws_secret_access_key=os.environ["S3_SECRET"], region_name=os.environ["S3_REGION"],
    verify=(os.environ.get("S3_CA_FILE") or True),
    config=botocore.config.Config(s3={"addressing_style": "path"}, connect_timeout=10, retries={"max_attempts": 1}))
try:
    s3.list_objects_v2(Bucket=os.environ["S3_BUCKET"], MaxKeys=1)
    k = "ascent-preflight-probe.txt"; s3.put_object(Bucket=os.environ["S3_BUCKET"], Key=k, Body=b"ok"); s3.delete_object(Bucket=os.environ["S3_BUCKET"], Key=k)
except Exception as e:
    print(f"  {e}", file=sys.stderr); sys.exit(1)
PYEOF
      then ok "credentials valid; list/put/delete on bucket ${S3_BUCKET} succeeded (boto3)"; else fail "S3 credential test failed (boto3) — see message above"; fi
    else wrn "curl ${cv} lacks --aws-sigv4 and boto3 is unavailable — S3 credentials could NOT be verified"; fi
    return
  fi

  s3_req GET "/?list-type=2&max-keys=1"
  case "${S3_HTTP}" in
    200) ok "credentials valid: ListObjects on ${S3_BUCKET} succeeded" ;;
    403) fail "S3 returned 403 $(s3_code): $(s3_msg)${swapped:+ — S3_ACCESS/S3_SECRET are probably swapped}" ;;
    404) fail "bucket '${S3_BUCKET}' not found (404 $(s3_code)): $(s3_msg)" ;;
    400) fail "S3 returned 400 $(s3_code): $(s3_msg) (wrong region for this endpoint?)" ;;
    301|307) fail "S3 redirected (${S3_HTTP}) — the bucket lives in another region/endpoint: $(s3_msg)" ;;
    000) fail "no HTTP response from ${S3_URL} (curl exit ${S3_RC})" ;;
    *)   fail "unexpected HTTP ${S3_HTTP} from ListObjects: $(s3_code) $(s3_msg)" ;;
  esac
  [[ "${S3_HTTP}" == 200 ]] || return
  local key tmp; key="ascent-preflight-probe-$(hostname)-$(date +%s)-${RANDOM}${RANDOM}.txt"; tmp="$(mktemp)"; echo "ascent preflight $(date -u +%FT%TZ)" > "${tmp}"
  s3_req PUT "/${key}" -T "${tmp}" -H "Content-Type: text/plain"
  rm -f "${tmp}"
  if [[ "${S3_HTTP}" == 200 ]]; then
    ok "write permission: PutObject succeeded"
    s3_req GET "/${key}"; [[ "${S3_HTTP}" == 200 ]] && ok "read-back: GetObject succeeded" || fail "GetObject of the probe object failed (HTTP ${S3_HTTP} $(s3_code))"
    s3_req DELETE "/${key}"; [[ "${S3_HTTP}" =~ ^20[04]$ ]] && ok "cleanup: DeleteObject succeeded" || wrn "could not delete probe object ${key} (HTTP ${S3_HTTP}) — delete permission is needed for retention"
  else fail "write permission: PutObject failed (HTTP ${S3_HTTP} $(s3_code): $(s3_msg)) — Ascent needs read/write/delete on the bucket"; fi
}

# ---- multi-node workers -----------------------------------------------------------
check_workers() {
  is_multi_node || { section "topology"; ok "single node (WORKERS empty) — k0s --single, node-pool selectors disabled"; return; }
  section "workers (multi-node)"
  local entries=() e ip pool ips="" hostnames="" ssh_ok="true"
  read -r -a entries <<<"${WORKERS}"
  ok "topology: 1 controller + ${#entries[@]} worker(s)"
  if [[ -z "${SSH_KEY}" ]]; then fail "SSH_KEY is required for multi-node installs"; ssh_ok="false"
  elif [[ ! -f "${SSH_KEY}" ]]; then fail "SSH_KEY not found: ${SSH_KEY}"; ssh_ok="false"
  elif [[ ! "$(file_mode "${SSH_KEY}")" =~ ^[4-7]00$ ]]; then wrn "SSH_KEY permissions are $(file_mode "${SSH_KEY}"); ssh requires 600"; fi
  local have_ingest=0 have_base=0 have_common=0
  case "${CONTROLLER_POOL}" in
    "") ;; ingest) have_ingest=1 ;; base) have_base=1 ;; common) have_common=1 ;;
    *) fail "CONTROLLER_POOL must be ingest|base|common (got '${CONTROLLER_POOL}')" ;;
  esac
  # --- static validation of every entry (no ssh needed) ---
  local valid=()
  for e in "${entries[@]}"; do
    ip="${e%%:*}"; pool="${e##*:}"
    if [[ "${e}" != *:* ]] || ! is_ipv4 "${ip}"; then fail "WORKERS entry '${e}' must be <ipv4>:<pool>"; continue; fi
    if [[ ! "${pool}" =~ ^(ingest|base|common)$ ]]; then fail "worker ${ip}: pool '${pool}' invalid (ingest|base|common)"; continue; fi
    case "${pool}" in ingest) have_ingest=1;; base) have_base=1;; common) have_common=1;; esac
    if grep -qw "${ip}" <<<"${ips}"; then fail "worker ${ip} is listed twice"; continue; fi
    ips="${ips} ${ip}"
    if [[ "${ip}" == "${PRIVATE_IP}" ]]; then fail "worker ${ip} is the controller itself — use CONTROLLER_POOL to give the controller a pool"; continue; fi
    cidr_contains "${NODE_SUBNET}" "${ip}" || wrn "worker ${ip} is outside the controller subnet ${NODE_SUBNET} — set NODE_SUBNET to a range covering all nodes"
    valid+=("${ip}:${pool}")
  done
  [[ ${have_ingest} -eq 1 ]] || fail "no node in pool 'ingest' (logiq-flash would stay Pending) — assign a worker or CONTROLLER_POOL=ingest"
  [[ ${have_base}   -eq 1 ]] || fail "no node in pool 'base' (prometheus/thanos/coffee would stay Pending)"
  [[ ${have_common} -eq 1 ]] || fail "no node in pool 'common' (postgres/redis would stay Pending)"
  [[ "${ssh_ok}" == "true" && ${#valid[@]} -gt 0 ]] || return
  # --- one ssh round-trip per worker collecting facts ---
  for e in "${valid[@]}"; do
    ip="${e%%:*}"; pool="${e##*:}"
    local facts
    if ! facts="$(ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo -n true || { echo SUDO=fail; exit 0; }
echo SUDO=ok; echo ARCH=\$(uname -m); echo HOST=\$(hostname); echo CPU=\$(nproc); echo MEM=\$(awk '/MemTotal/{printf \"%d\", \$2/1024}' /proc/meminfo)
echo DISK=\$(df -BG --output=avail /var 2>/dev/null | tail -n1 | tr -dc 0-9); echo SWAP=\$(swapon --noheadings --show 2>/dev/null | wc -l)
echo K0S=\$(sudo -n k0s status >/dev/null 2>&1 && echo running || echo no); echo NTP=\$(timedatectl show -p NTPSynchronized --value 2>/dev/null || echo unknown)
echo OS=\$(. /etc/os-release 2>/dev/null; echo \"\${PRETTY_NAME:-unknown}\" | tr ' ' '_'); echo NET=\$(curl -sI -o /dev/null -w '%{http_code}' --max-time 10 https://github.com/ 2>/dev/null || echo 000)
echo BUSY=\$(ss -Hltn 2>/dev/null | awk '{print \$4}' | sed 's/.*://' | sort -un | grep -xE '6443|9443|8132|10250|179|80|443|9999|8081|14250|20514|14268' | tr '\n' ',')
echo FW=\$( (systemctl is-active --quiet firewalld 2>/dev/null && echo firewalld) ; (sudo -n ufw status 2>/dev/null | grep -q '^Status: active' && echo ufw) )
echo IPOK=\$(ip -o -4 addr show 2>/dev/null | grep -q ' ${ip}/' && echo yes || echo no)" 2>&1)"; then
      fail "worker ${ip}: ssh failed as ${SSH_USER} with ${SSH_KEY}: $(tail -n1 <<<"${facts}")"; continue
    fi
    declare -A W=(); while IFS='=' read -r k v; do [[ -n "${k}" ]] && W["${k}"]="${v}"; done <<<"${facts}"
    [[ "${W[SUDO]:-}" == ok ]] || { fail "worker ${ip}: passwordless sudo failed for ${SSH_USER}"; unset W; continue; }
    [[ "${W[ARCH]:-}" == x86_64 ]] && ok "worker ${ip} (${pool}): ${W[HOST]:-?}, ${W[OS]:-?}, ${W[CPU]:-?} CPU, $(( ${W[MEM]:-0} / 1024 )) GiB RAM, ${W[DISK]:-?} GB free" || fail "worker ${ip}: architecture ${W[ARCH]:-?} unsupported"
    [[ "${W[IPOK]:-no}" == yes ]] || wrn "worker ${ip}: that address is not on the worker's interfaces (NAT?) — k0s will use the interface IP"
    [[ ${W[CPU]:-0} -ge ${MIN_CPU} ]] || fail "worker ${ip}: ${W[CPU]:-?} CPUs < ${MIN_CPU}"
    [[ ${W[MEM]:-0} -ge ${MIN_RAM_MIB} ]] || fail "worker ${ip}: $(( ${W[MEM]:-0} / 1024 )) GiB RAM < $((MIN_RAM_MIB/1024)) GiB"
    [[ ${W[DISK]:-0} -ge ${MIN_DISK_GB} ]] || fail "worker ${ip}: ${W[DISK]:-?} GB free on /var < ${MIN_DISK_GB} GB"
    [[ "${W[SWAP]:-0}" == 0 ]] || fail "worker ${ip}: swap is enabled"
    [[ "${W[NTP]:-}" == yes ]] || wrn "worker ${ip}: clock not NTP-synchronised (${W[NTP]:-unknown})"
    [[ "${W[NET]:-000}" != 000 ]] || fail "worker ${ip}: no internet access (github.com unreachable) — cannot download k0s or pull images"
    [[ -z "${W[BUSY]:-}" || "${W[K0S]:-}" == running ]] || fail "worker ${ip}: ports in use: ${W[BUSY]}"
    [[ -z "${W[FW]:-}" ]] || fail "worker ${ip}: host firewall active (${W[FW]}) — disable it or open the k8s ports"
    [[ "${W[K0S]:-}" == running ]] && wrn "worker ${ip}: k0s already running — join will be skipped"
    local h="${W[HOST]:-}"
    if [[ -n "${h}" ]]; then
      [[ "${h,,}" == "$(hostname | tr '[:upper:]' '[:lower:]')" ]] && fail "worker ${ip}: hostname '${h}' equals the controller hostname — node names must be unique"
      grep -qw "${h,,}" <<<"${hostnames}" && fail "worker ${ip}: duplicate hostname '${h}' (cloned VM?) — node names must be unique"
      hostnames="${hostnames} ${h,,}"
    fi
    unset W
  done
}

phase_preflight() {
  CURRENT_PHASE="preflight"
  if existing_cluster; then log "preflight: installer v${INSTALLER_VERSION}, existing cluster (context $(kubectl config current-context 2>/dev/null || echo none))"
  else log "preflight: installer v${INSTALLER_VERSION}, controller ${PRIVATE_IP} on ${PRIMARY_IF}, subnet ${NODE_SUBNET}"; fi
  disarm_traps; set +e
  check_config_file
  if existing_cluster; then check_cluster; else check_host; check_network; fi
  check_app_config
  check_sizing
  check_tls
  check_s3
  existing_cluster || check_workers
  set -e; arm_traps
  echo; hr
  echo "Preflight summary: ${PF_PASS} passed, ${#PF_WARNS[@]} warning(s), ${#PF_FAILS[@]} failure(s)"
  if [[ ${#PF_WARNS[@]} -gt 0 ]]; then echo; echo -e "${C_YEL}Warnings:${C_OFF}"; printf '  - %s\n' "${PF_WARNS[@]}"; fi
  if [[ ${#PF_FAILS[@]} -gt 0 ]]; then
    echo; echo -e "${C_RED}Failures (fix all of these, then re-run preflight):${C_OFF}"; printf '  - %s\n' "${PF_FAILS[@]}"
    hr; echo "Log: ${LOG_FILE}"; return 1
  fi
  hr; log "preflight OK"
}

# ---------------------------------------------------------------------------
# phase: network (host firewall + optional OCI fixes) — controller only;
# workers get the same treatment during the 'workers' phase.
# ---------------------------------------------------------------------------
# Firewall rules live in dedicated chains (ASCENT-INSTALLER, ASCENT-INSTALLER-NAT) hooked at the top of
# INPUT, FORWARD and nat POSTROUTING. Global policies and foreign rules are not modified; removal is
# unhook, flush, delete. The same script runs on the controller and on workers.
fw_script() { # fw_script <apply|remove> <tcp-ports> <oci-fixes:true|false> <remove-legacy-v0.2-rules:true|false>
  cat <<EOF
set -euo pipefail
${REMOTE_PRELUDE}
C=ASCENT-INSTALLER; N=ASCENT-INSTALLER-NAT
IF=\$(ip -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p'); IF=\${IF:-eth0}
ipt() { sudo -n iptables "\$@"; }
unhook() { ipt -t "\$1" -D "\$2" -j "\$3" 2>/dev/null || true; ipt -t "\$1" -F "\$3" 2>/dev/null || true; ipt -t "\$1" -X "\$3" 2>/dev/null || true; }
if [ "$4" = true ]; then   # rules the v0.2.0 installer inserted directly into INPUT/POSTROUTING
  ipt -D INPUT -s ${NODE_SUBNET} -j ACCEPT 2>/dev/null || true
  ipt -D INPUT -s ${POD_CIDR} -j ACCEPT 2>/dev/null || true
  ipt -D INPUT -s ${SERVICE_CIDR} -j ACCEPT 2>/dev/null || true
  ipt -D INPUT -p tcp -m multiport --dports $2 -j ACCEPT 2>/dev/null || true
  ipt -D INPUT -p tcp -m multiport --dports 80,443,6443,8132,9443,10250 -j ACCEPT 2>/dev/null || true
  ipt -t nat -D POSTROUTING -s ${POD_CIDR} -d ${NODE_SUBNET} -o "\$IF" -j MASQUERADE 2>/dev/null || true
fi
if [ "$1" = remove ]; then
  unhook filter INPUT "\$C"; unhook filter FORWARD "\$C"; unhook nat POSTROUTING "\$N"
else
  ipt -t filter -N "\$C" 2>/dev/null || true
  ipt -t filter -F "\$C"
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -s ${NODE_SUBNET} -j ACCEPT
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -s ${POD_CIDR} -j ACCEPT
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -d ${POD_CIDR} -j ACCEPT
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -s ${SERVICE_CIDR} -j ACCEPT
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -d ${SERVICE_CIDR} -j ACCEPT
  ipt -t filter -A "\$C" -m comment --comment ascent-installer -p tcp -m multiport --dports $2 -j ACCEPT
  [ "$3" = true ] && ipt -t filter -A "\$C" -m comment --comment ascent-installer -p 4 -j ACCEPT   # IPIP overlay
  ipt -C INPUT -j "\$C" 2>/dev/null || ipt -I INPUT 1 -j "\$C"
  ipt -C FORWARD -j "\$C" 2>/dev/null || ipt -I FORWARD 1 -j "\$C"
  if [ "$3" = true ]; then
    # pod->node traffic must be SNATed: kube-router's masquerade rule excludes node-IP
    # destinations and OCI VCN drops pod-sourced packets (src/dst checks)
    ipt -t nat -N "\$N" 2>/dev/null || true; ipt -t nat -F "\$N"
    ipt -t nat -A "\$N" -m comment --comment ascent-installer -s ${POD_CIDR} -d ${NODE_SUBNET} -o "\$IF" -j MASQUERADE
    ipt -t nat -C POSTROUTING -j "\$N" 2>/dev/null || ipt -t nat -I POSTROUTING 1 -j "\$N"
  else
    unhook nat POSTROUTING "\$N"
  fi
fi
if command -v netfilter-persistent >/dev/null 2>&1; then sudo -n netfilter-persistent save >/dev/null 2>&1 || true
elif systemctl is-enabled iptables.service >/dev/null 2>&1; then sudo -n sh -c 'iptables-save > /etc/sysconfig/iptables' 2>/dev/null || true; fi
EOF
}
CONTROLLER_PORTS="80,443,6443,8132,9443,10250"
WORKER_PORTS="80,443,10250"

phase_network() {
  CURRENT_PHASE="network"
  if existing_cluster; then log "network: skipped (CLUSTER_MODE=existing)"; return 0; fi
  local fixes="false"; network_fixes_enabled && fixes="true"
  local legacy="false"; marked applied.iptables && ! marked firewall.chain.created && legacy="true"
  log "network: owned iptables chain ASCENT-INSTALLER on the controller (subnet ${NODE_SUBNET}, cloud fixes: ${fixes})"
  [[ -n "$(state_get firewall.forward_policy_before)" ]] || state_set firewall.forward_policy_before "$(sudo -n iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/{print $3}')"
  bash -c "$(fw_script apply "${CONTROLLER_PORTS}" "${fixes}" "${legacy}")"
  mark firewall.chain.created; state_del applied.iptables
  if ! command -v netfilter-persistent >/dev/null 2>&1 && ! systemctl is-enabled iptables.service >/dev/null 2>&1; then
    info "no iptables persistence service — rules are re-created by every run but not across reboots (iptables-persistent / iptables-services)"
  fi
  log "network OK"
}

# ---------------------------------------------------------------------------
# phase: k0s (controller)
# ---------------------------------------------------------------------------
write_k0s_config() {
  local sans="    - ${PRIVATE_IP}"
  [[ -n "${PUBLIC_IP}" ]] && sans="${sans}
    - ${PUBLIC_IP}"

  local kuberouter_extra=""
  if network_fixes_enabled; then   # IPIP overlay: inter-node pod traffic is encapsulated with node-IP sources
    kuberouter_extra="
      ipMasq: true
      extraArgs:
        overlay-type: full"
  fi

  sudo mkdir -p /etc/k0s
  if [[ -f /etc/k0s/k0s.yaml ]]; then sudo cp /etc/k0s/k0s.yaml "/etc/k0s/k0s.yaml.bak-$(date +%Y%m%d-%H%M%S)"; fi
  mark wrote.k0s-config
  sudo tee /etc/k0s/k0s.yaml > /dev/null <<EOF
apiVersion: k0s.k0sproject.io/v1beta1
kind: ClusterConfig
metadata:
  name: k0s
  namespace: kube-system
spec:
  api:
    address: ${PRIVATE_IP}
    port: 6443
    k0sApiPort: 9443
    sans:
${sans}
  extensions:
    helm:
      concurrencyLevel: 5
      repositories:
      - name: openebs-internal
        url: https://openebs.github.io/charts
      - name: metallb
        url: https://metallb.github.io/metallb
      charts:
      - name: openebs
        chartname: openebs-internal/openebs
        version: "${OPENEBS_CHART_VERSION}"
        namespace: openebs
        order: 1
        values: |
          localprovisioner:
            hostpathClass:
              enabled: true
              isDefaultClass: true
      - name: metallb
        chartname: metallb/metallb
        version: "${METALLB_CHART_VERSION}"
        namespace: metallb
  network:
    clusterDomain: cluster.local
    podCIDR: ${POD_CIDR}
    serviceCIDR: ${SERVICE_CIDR}
    provider: kuberouter
    kuberouter:
      autoMTU: true
      hairpin: Enabled
      metricsPort: 8080${kuberouter_extra}
  telemetry:
    enabled: false
EOF
}

verify_sha256() { # verify_sha256 <file> <expected-sha256> <name>
  local file="$1" expected="$2" name="$3" actual
  if [[ -z "${expected}" ]]; then
    [[ "${SKIP_CHECKSUM_VERIFY}" == "true" ]] || die "no pinned SHA-256 for ${name} (version overridden?) — set ${name^^}_SHA256 or SKIP_CHECKSUM_VERIFY=true"
    warn "${name}: checksum verification skipped"; return 0
  fi
  actual="$(sha256sum "${file}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]] || { rm -f "${file}"; die "${name}: SHA-256 mismatch (expected ${expected}, got ${actual}) — download corrupted or tampered"; }
  log "${name}: SHA-256 verified"
}
download_to() { # download_to <url> <dest> [expected-sha256] [name] — retries, verifies size and checksum
  local url="$1" dest="$2" sha="${3:-}" i
  local name="${4:-$(basename "${dest}")}"
  mkdir -p "$(dirname "${dest}")"; chmod 700 "$(dirname "${dest}")"
  for i in 1 2 3; do
    if curl -fL --retry 2 --connect-timeout 15 -o "${dest}.part" "${url}"; then
      [[ -s "${dest}.part" ]] && { mv "${dest}.part" "${dest}"; verify_sha256 "${dest}" "${sha}" "${name}"; return 0; }
    fi
    warn "download attempt ${i} failed: ${url}"; sleep 3
  done
  die "could not download ${url}"
}

download_k0s() {
  if [[ ! -x /usr/local/bin/k0s ]]; then
    log "downloading k0s ${K0S_VERSION}"
    download_to "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION/+/%2B}/k0s-${K0S_VERSION}-amd64" "${INSTALL_DIR}/downloads/k0s" "${K0S_SHA256}" k0s
    chmod +x "${INSTALL_DIR}/downloads/k0s" && sudo install -m 0755 "${INSTALL_DIR}/downloads/k0s" /usr/local/bin/k0s
    mark installed.k0s-binary
  fi
}

phase_k0s() {
  CURRENT_PHASE="k0s"
  if existing_cluster; then
    have_kubectl || die "kubectl cannot reach the cluster (context '$(kubectl config current-context 2>/dev/null)')"
    [[ -n "$(state_get cluster.uid)" ]] || { state_set cluster.uid "$(cluster_uid)"; state_set cluster.adopted true; }
    log "k0s: skipped (CLUSTER_MODE=existing); using context '$(kubectl config current-context 2>/dev/null)', cluster $(cluster_uid | cut -c1-8)…"
    return 0
  fi
  download_k0s

  if k0s_running; then
    if cluster_known; then log "k0s already running; cluster known to this installer, leaving /etc/k0s/k0s.yaml untouched"
    elif [[ "${ADOPT_EXISTING_CLUSTER}" == "true" ]]; then
      state_set cluster.uid "$(cluster_uid)"; state_set cluster.adopted true
      warn "adopting the existing k0s cluster $(cluster_uid | cut -c1-8)… (ADOPT_EXISTING_CLUSTER=true); cleanup will never reset it"
    else die "a running k0s cluster exists that this installer did not create — set ADOPT_EXISTING_CLUSTER=true to use it"; fi
  else
    case "$(k0s_unit)" in
      controller)
        is_multi_node && k0s_unit_is_single && die "existing k0s controller service was installed with --single; run 'sudo k0s stop; sudo k0s reset' before a multi-node install"
        warn "k0s controller service exists but is stopped — starting it (existing config and data are kept)"
        sudo k0s start ;;
      worker) die "this host runs a k0s WORKER service; it cannot become the controller (sudo k0s stop; sudo k0s reset)" ;;
      *)
        write_k0s_config
        if is_multi_node; then
          log "installing k0s controller (multi-node: --enable-worker --no-taints)"
          sudo k0s install controller --enable-worker --no-taints -c /etc/k0s/k0s.yaml
        else
          log "installing k0s controller (single node)"
          sudo k0s install controller --single -c /etc/k0s/k0s.yaml
        fi
        mark created.k0s-cluster
        sudo k0s start ;;
    esac
  fi

  log "waiting for the API server (up to 5m)"
  local i
  for i in $(seq 1 60); do
    sudo k0s status >/dev/null 2>&1 && sudo k0s kubectl get nodes >/dev/null 2>&1 && break
    sleep 5
  done
  sudo k0s kubectl get nodes >/dev/null 2>&1 || die "k0s API did not come up within 5 minutes"

  # CLI tools
  if [[ ! -x /usr/local/bin/kubectl ]] && ! command -v kubectl >/dev/null 2>&1; then
    log "installing kubectl ${KUBECTL_VERSION}"
    download_to "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "${INSTALL_DIR}/downloads/kubectl" "${KUBECTL_SHA256}" kubectl
    sudo install -m 0755 "${INSTALL_DIR}/downloads/kubectl" /usr/local/bin/kubectl
    mark installed.kubectl-binary
  fi
  if [[ ! -x /usr/local/bin/helm ]] && ! command -v helm >/dev/null 2>&1; then
    log "installing helm ${HELM_VERSION}"
    download_to "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "${INSTALL_DIR}/downloads/helm.tgz" "${HELM_SHA256}" helm
    tar xzf "${INSTALL_DIR}/downloads/helm.tgz" -C "${INSTALL_DIR}/downloads" linux-amd64/helm
    sudo install -m 0755 "${INSTALL_DIR}/downloads/linux-amd64/helm" /usr/local/bin/helm
    mark installed.helm-binary
  fi
  hash -r

  mkdir -p "${HOME}/.kube"
  local newcfg; newcfg="$(sudo k0s kubeconfig admin)"
  if [[ ! -f "${HOME}/.kube/config" ]]; then
    echo "${newcfg}" > "${HOME}/.kube/config"; mark wrote.kubeconfig
  elif ! diff -q <(echo "${newcfg}") "${HOME}/.kube/config" >/dev/null 2>&1; then
    cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak-$(date +%Y%m%d-%H%M%S)"
    info "existing ~/.kube/config differed — backed up and replaced"
    echo "${newcfg}" > "${HOME}/.kube/config"; mark wrote.kubeconfig
  else
    info "${HOME}/.kube/config already points at this cluster"
  fi
  chmod 600 "${HOME}/.kube/config"
  export KUBECONFIG="${HOME}/.kube/config"

  kubectl wait --for=condition=Ready node --all --timeout=600s
  [[ -n "$(state_get cluster.uid)" ]] || state_set cluster.uid "$(cluster_uid)"
  log "k0s OK: $(kubectl get nodes --no-headers | wc -l | tr -d ' ') node(s) Ready (cluster $(cluster_uid | cut -c1-8)…)"
}

# ---------------------------------------------------------------------------
# phase: workers (multi-node only)
# ---------------------------------------------------------------------------
FAILED_WORKER=""; WORKER_TOKEN_IDS=""
phase_workers() {
  CURRENT_PHASE="workers"
  if existing_cluster; then log "workers: skipped (CLUSTER_MODE=existing)"; return 0; fi
  if ! is_multi_node; then
    log "workers: single-node install, skipping"
    if [[ -n "${CONTROLLER_POOL}" ]]; then
      kubectl label node "$(hostname | tr '[:upper:]' '[:lower:]')" "${NODE_POOL_LABEL}=${CONTROLLER_POOL}" --overwrite
    fi
    return 0
  fi

  local worker_prep
  worker_prep=$(cat <<EOF
set -euo pipefail
${REMOTE_PRELUDE}
if [ ! -x /usr/local/bin/k0s ]; then
  curl -fsSL --retry 3 -o /tmp/k0s "https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION/+/%2B}/k0s-${K0S_VERSION}-amd64"
  if [ -n "${K0S_SHA256}" ] && [ "${SKIP_CHECKSUM_VERIFY}" != true ]; then
    echo "${K0S_SHA256}  /tmp/k0s" | sha256sum -c --quiet - || { echo "k0s checksum mismatch on worker"; rm -f /tmp/k0s; exit 4; }
  fi
  chmod +x /tmp/k0s && sudo mv /tmp/k0s /usr/local/bin/k0s
  echo "ASCENT_INSTALLED_K0S_BINARY=1"
fi
sudo mkdir -p /etc/k0s
# the worker must reach the controller's API, join API and konnectivity ports
for p in 6443 9443 8132; do
  timeout 5 bash -c "</dev/tcp/${PRIVATE_IP}/\$p" 2>/dev/null || { echo "cannot reach controller ${PRIVATE_IP}:\$p from this worker — check security lists / firewalls"; exit 3; }
done
EOF
)

  local need_snat="false"
  network_fixes_enabled && need_snat="true"

  local entry ip pool legacy
  for entry in ${WORKERS}; do
    ip="${entry%%:*}"; pool="${entry##*:}"; FAILED_WORKER="${ip}"
    log "worker ${ip}: firewall chain + k0s binary + connectivity check"
    legacy="false"; marked "applied.iptables.worker.${ip}" && ! marked "firewall.worker.${ip}.chain.created" && legacy="true"
    ssh_worker "${ip}" "bash -s" <<<"$(fw_script apply "${WORKER_PORTS}" "${need_snat}" "${legacy}")"
    mark "firewall.worker.${ip}.chain.created"; state_del "applied.iptables.worker.${ip}"
    local prep_out; prep_out="$(ssh_worker "${ip}" "bash -s" <<<"${worker_prep}")"
    [[ -n "${prep_out}" ]] && echo "${prep_out}" | grep -v ASCENT_INSTALLED_K0S_BINARY | sed 's/^/  /' || true
    grep -q ASCENT_INSTALLED_K0S_BINARY <<<"${prep_out}" && mark "installed.k0s-binary.worker.${ip}"

    if ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo -n k0s status >/dev/null 2>&1"; then
      log "worker ${ip}: k0s already running, skipping join"
    else
      log "worker ${ip}: joining cluster"
      # join token: 15 min expiry, transferred on the ssh channel (not argv), stored 0600,
      # invalidated on the controller and deleted from the worker after the join
      local token token_id
      token="$(sudo k0s token create --role=worker --expiry 15m)"
      token_id="$(printf '%s' "${token}" | base64 -d 2>/dev/null | gunzip -c 2>/dev/null | grep -oE 'token: [a-z0-9]+\.' | head -n1 | sed 's/token: //; s/\.$//' || true)"
      printf '%s' "${token}" | ssh_worker "${ip}" "${REMOTE_PRELUDE}; set -e; umask 077; t=\$(mktemp); cat > \"\$t\"; [ -s \"\$t\" ] || { echo 'empty join token received'; exit 5; }
sudo install -m 0600 -o root -g root \"\$t\" /etc/k0s/token; rm -f \"\$t\"; sudo k0s install worker --token-file /etc/k0s/token && sudo k0s start"
      unset token
      [[ -n "${token_id}" ]] && WORKER_TOKEN_IDS="${WORKER_TOKEN_IDS:-} ${token_id}"
      mark "joined.worker.${ip}"
    fi
  done
  FAILED_WORKER=""

  log "waiting for all nodes to be Ready (up to 10m)"
  local expected=$(( $(echo "${WORKERS}" | wc -w) + 1 )) i
  for i in $(seq 1 120); do
    [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge ${expected} ]] && break; sleep 5
  done
  [[ "$(kubectl get nodes --no-headers 2>/dev/null | wc -l)" -ge ${expected} ]] || die "only $(kubectl get nodes --no-headers | wc -l)/${expected} nodes registered after 10m"
  kubectl wait --for=condition=Ready node --all --timeout=600s

  for entry in ${WORKERS}; do
    ip="${entry%%:*}"; pool="${entry##*:}"
    local node; node="$(ssh_worker "${ip}" hostname | tr '[:upper:]' '[:lower:]')"
    log "labeling node ${node}: ${NODE_POOL_LABEL}=${pool}"
    kubectl label node "${node}" "${NODE_POOL_LABEL}=${pool}" --overwrite
    # the token file is read only during the first bootstrap; once kubelet.conf exists it is not needed
    if ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo test -s /var/lib/k0s/kubelet.conf" 2>/dev/null; then
      ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo rm -f /etc/k0s/token" && log "worker ${ip}: join token removed from disk"
    else
      warn "worker ${ip}: kubelet config not found yet — leaving /etc/k0s/token in place (remove it once the node is Ready)"
    fi
  done
  local tid
  for tid in ${WORKER_TOKEN_IDS:-}; do sudo k0s token invalidate "${tid}" >/dev/null 2>&1 && log "join token ${tid} invalidated on the controller" || true; done
  WORKER_TOKEN_IDS=""
  if [[ -n "${CONTROLLER_POOL}" ]]; then
    kubectl label node "$(hostname | tr '[:upper:]' '[:lower:]')" "${NODE_POOL_LABEL}=${CONTROLLER_POOL}" --overwrite
  fi
  log "workers OK"
}

# ---------------------------------------------------------------------------
# phase: addons (wait for extensions, metallb pool)
# ---------------------------------------------------------------------------
phase_addons() {
  CURRENT_PHASE="addons"
  if existing_cluster; then log "addons: skipped (CLUSTER_MODE=existing)"; return 0; fi
  log "waiting for openebs + metallb (k0s helm extensions, up to 10m)"
  local i
  for i in $(seq 1 120); do
    kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 \
      && kubectl get deploy -n metallb metallb-controller >/dev/null 2>&1 && break
    sleep 5
  done
  kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 || die "storage class ${STORAGE_CLASS} never appeared (openebs extension did not install)"
  kubectl -n metallb rollout status deploy/metallb-controller --timeout=300s
  kubectl -n metallb wait --for=condition=Ready pod -l app.kubernetes.io/component=speaker --timeout=300s >/dev/null 2>&1 || true

  log "applying metallb address pool (${LB_IP}/32)"
  kubectl get ipaddresspool ascent-pool -n metallb >/dev/null 2>&1 || mark applied.metallb-pool
  for i in 1 2 3 4 5 6; do   # the webhook needs a moment after the controller is up
    kubectl apply -f - <<EOF && break
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ascent-pool
  namespace: metallb
spec:
  addresses:
  - ${LB_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: ascent-l2
  namespace: metallb
EOF
    [[ ${i} -eq 6 ]] && die "could not apply the MetalLB IPAddressPool (webhook not ready?)"
    sleep 10
  done
  log "addons OK"
}

# ---------------------------------------------------------------------------
# An interrupted helm --wait leaves a release in pending-* (locked) or failed state;
# roll back to the last good revision before upgrading.
# ---------------------------------------------------------------------------
unstick_release() { # unstick_release <release> <namespace>
  local st; st="$(helm status "$1" -n "$2" 2>/dev/null | awk '/^STATUS:/{print $2}' || true)"
  case "${st}" in
    pending-install|pending-upgrade|pending-rollback)
      local good; good="$(helm history "$1" -n "$2" --max 50 2>/dev/null | awk '$7=="deployed"||$7=="superseded"{r=$1} END{print r}')"
      if [[ -n "${good}" ]]; then warn "release $1 is stuck in '${st}' (interrupted run) — rolling back to revision ${good} before continuing"; helm rollback "$1" "${good}" -n "$2" --wait --timeout 5m || true
      else warn "release $1 is stuck in '${st}' with no good revision — uninstalling it so it can be reinstalled"; helm uninstall "$1" -n "$2" --wait --timeout 5m || true; fi ;;
    failed) info "release $1 is in 'failed' state (interrupted or failed upgrade) — the upgrade below repairs it" ;;
  esac
}

# ---------------------------------------------------------------------------
# phase: envoy
# ---------------------------------------------------------------------------
phase_envoy() {
  CURRENT_PHASE="envoy"
  unstick_release eg envoy-gateway-system
  log "installing envoy gateway ${ENVOY_GATEWAY_VERSION}"
  helm status eg -n envoy-gateway-system >/dev/null 2>&1 || mark installed.envoy-release
  helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "${ENVOY_GATEWAY_VERSION}" \
    -n envoy-gateway-system --create-namespace --wait --timeout 10m
  log "envoy OK"
}

# ---------------------------------------------------------------------------
# phase: cnpg (CloudNativePG operator; DB_ENGINE=cnpg only)
# ---------------------------------------------------------------------------
phase_cnpg() {
  CURRENT_PHASE="cnpg"
  [[ "${DB_ENGINE}" == "cnpg" ]] || { log "cnpg: DB_ENGINE=${DB_ENGINE}, skipping operator install"; return 0; }
  unstick_release cnpg-operator cnpg-system
  log "installing CloudNativePG operator (chart ${CNPG_OPERATOR_CHART_VERSION})"
  helm repo list 2>/dev/null | grep -q '^cnpg\s' || { helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null; mark added.helm-repo.cnpg; }
  helm repo update cnpg >/dev/null
  helm status cnpg-operator -n cnpg-system >/dev/null 2>&1 || mark installed.cnpg-operator-release
  helm upgrade --install cnpg-operator cnpg/cloudnative-pg \
    --version "${CNPG_OPERATOR_CHART_VERSION}" \
    -n cnpg-system --create-namespace --wait --timeout 10m
  kubectl wait --for=condition=Established crd/clusters.postgresql.cnpg.io --timeout=120s
  log "cnpg OK"
}

require_config_complete() { # the application phases must never run on empty settings
  local missing="" v
  for v in DOMAIN S3_URL S3_BUCKET S3_REGION S3_ACCESS S3_SECRET ADMIN_EMAIL ADMIN_PASSWORD PG_PASSWORD; do [[ -n "${!v}" ]] || missing="${missing} ${v}"; done
  [[ -z "${missing}" ]] || die "configuration incomplete —${missing} not set (config ${CONFIG_FILE:-none}, secrets ${SECRETS_FILE:-none}); run 'preflight' first"
}

# ---------------------------------------------------------------------------
# phase: values (generate helm override file)
# ---------------------------------------------------------------------------
ensure_tls_material() { # generates a self-signed cert when requested and nothing is configured
  if [[ -z "${TLS_CERT_FILE}" && "${TLS_SELF_SIGNED}" == "true" ]]; then
    local dir="${INSTALL_DIR}/tls"; mkdir -p "${dir}"; chmod 700 "${dir}"
    TLS_CERT_FILE="${dir}/tls.crt"; TLS_KEY_FILE="${dir}/tls.key"
    if [[ ! -s "${TLS_CERT_FILE}" ]] || ! openssl x509 -in "${TLS_CERT_FILE}" -noout -checkhost "${DOMAIN}" 2>/dev/null | grep -q "does match"; then
      # 397 days: the maximum browsers accept; RSA 2048 kept for compatibility with older syslog/agent TLS stacks
      log "generating a self-signed certificate for ${DOMAIN} (397 days) in ${dir}"
      openssl req -x509 -newkey rsa:2048 -nodes -days 397 -keyout "${TLS_KEY_FILE}" -out "${TLS_CERT_FILE}" \
        -subj "/CN=${DOMAIN}/O=${ADMIN_ORG}" -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
      chmod 600 "${TLS_KEY_FILE}"
    fi
  fi
}

phase_values() {
  CURRENT_PHASE="values"
  require_config_complete
  mkdir -p "${INSTALL_DIR}"
  local values_file="${INSTALL_DIR}/values.yaml"
  ensure_tls_material

  local cert_b64=""
  [[ -n "${TLS_CERT_FILE}" ]] && cert_b64="$(b64_file "${TLS_CERT_FILE}")"
  local nodeselectors_enabled="true"; is_multi_node || nodeselectors_enabled="false"
  # StatefulSet volume claim sizes are immutable: keep the size of an existing flash volume on upgrades
  FLASH_PVC_SIZE="${SZ_POD_DISK_GI}Gi"
  if [[ "${SZ_ENABLED}" == "true" ]] && have_kubectl; then
    local existing; existing="$(kubectl get pvc data-logiq-flash-0 -n "${NAMESPACE}" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || true)"
    if [[ -n "${existing}" && "${existing}" != "${FLASH_PVC_SIZE}" ]]; then
      warn "existing flash volume is ${existing}; sizing suggests ${FLASH_PVC_SIZE} but a StatefulSet volume size cannot be changed in place — keeping ${existing} (recreate the release to apply the new size)"
      FLASH_PVC_SIZE="${existing}"
    fi
  fi
  local bitnami_pg="true"; [[ "${DB_ENGINE}" == "cnpg" ]] && bitnami_pg="false"

  {
    echo "# Generated by ascent-install.sh v${INSTALLER_VERSION} on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Helm OVERRIDES ONLY — everything else comes from the chart's default values."
    echo "# Topology: $(is_multi_node && echo multi-node || echo single-node); database: ${DB_ENGINE}"
    echo "# Contains NO credentials: passwords, S3 keys and the TLS private key are passed to helm at"
    echo "# deploy time from ${SECRETS_FILE:-the secrets file/environment} via a temporary file. Do not add them here."
    echo "global:"
    echo "  domain: $(yq_str "${DOMAIN}")"
    [[ -n "${IMAGE_REGISTRY}" ]] && echo "  imageRegistry: $(yq_str "${IMAGE_REGISTRY}")"
    echo "  nodeSelectors:"
    echo "    enabled: ${nodeselectors_enabled}"
    echo "  nodePort:"
    echo "    enabled: false"
    echo "  persistence:"
    echo "    storageClass: $(yq_str "${STORAGE_CLASS}")"
    echo "  chart:"
    echo "    postgres: ${bitnami_pg}"
    echo "  environment:"
    echo "    s3_url: $(yq_str "${S3_URL}")"
    echo "    s3_bucket: $(yq_str "${S3_BUCKET}")"
    echo "    s3_region: $(yq_str "${S3_REGION}")"
    echo "    awsServiceEndpoint: $(yq_str "${S3_URL}")"
    if [[ -n "${S3_CA_FILE}" ]]; then
      echo "    s3_custom_ca:"
      echo "      enabled: true"
      echo "      map_name: ascent-s3-ca"
    fi
    [[ "${DB_ENGINE}" == "cnpg" ]] && echo "    postgres_host: $(yq_str "${RELEASE_NAME}-cnpg-rw")"
    echo "    admin_name: $(yq_str "${ADMIN_NAME}")"
    echo "    admin_org: $(yq_str "${ADMIN_ORG}")"
    echo "    admin_email: $(yq_str "${ADMIN_EMAIL}")"
    echo "    upload_dashboard: ${UPLOAD_DASHBOARD}"
    echo "    external_cert_crt: $(yq_str "${cert_b64}")"
    if [[ -n "${RATE_LIMIT_FLAGS}" ]]; then echo "    rate_limit_flags: $(yq_str "${RATE_LIMIT_FLAGS}")"
    elif [[ "${SZ_ENABLED}" == "true" && "${INGEST_MODE}" == "lake" ]]; then echo "    rate_limit_flags: $(yq_str "-max_bytes_per_sec=${SZ_BYTES_PER_SEC}")   # ${INGEST_GB_PER_DAY} GB/day"; fi
    echo
    if [[ "${DB_ENGINE}" == "cnpg" ]]; then
      echo "# --- CloudNativePG (operator installed by the 'cnpg' phase) ---"
      echo "cnpg:"
      echo "  enabled: true"
      echo "  mode: standalone"
      echo "  superuserSecret:"
      echo "    name: ascent-db-superuser"
      echo "    username: postgres"
      echo "  cluster:"
      echo "    instances: $(is_multi_node && echo 2 || echo 1)"
      echo "    storage:"
      echo "      size: 50Gi"
      if ! is_multi_node; then
        echo "    resources:"
        echo "      requests:"
        echo "        cpu: 500m"
        echo "        memory: 2000Mi"
        echo "      limits:"
        echo "        memory: 8000Mi"
      fi
      echo "  backups:"
      echo "    enabled: false"
    else
      echo "# --- Bitnami single-instance Postgres ---"
      echo "postgres:"
      echo "  enabled: true"
      if ! is_multi_node; then
        echo "  resources:"
        echo "    limits:"
        echo "      memory: 8000Mi"
      fi
      echo
      echo "# Newer charts bundle a CloudNativePG subchart enabled by default; keep it off."
      echo "cnpg:"
      echo "  enabled: false"
    fi
    echo
    echo "logiq-flash:"
    echo "  kafka_client:"
    echo "    enabled: false   # requires an ascent-kafka-cert secret; enable only with Kafka+certs"
    echo "  secrets_name: ascent-ingest   # created by the 'deploy' phase from the TLS material"
    if [[ "${SZ_ENABLED}" == "true" ]]; then
      echo "  # --- sizing from the capacity planning guide: ${INGEST_GB_PER_DAY} GB/day, ${INGEST_MODE}, tier ${WORKLOAD_TIER} ---"
      echo "  replicaCount: ${SZ_PODS}"
      echo "  resources:"
      echo "    ingest:"
      echo "      requests:"
      echo "        cpu: ${SZ_POD_CPU}"
      echo "        memory: ${SZ_POD_MEM_GI}Gi"
      echo "      limits:"
      echo "        memory: $(( SZ_POD_MEM_GI * 5 / 4 ))Gi"
      echo "  persistence:"
      echo "    size: ${FLASH_PVC_SIZE}"
      if [[ "${INGEST_MODE}" == "flow" ]]; then
        echo "  logflow_only:"
        echo "    enabled: true"
        echo "    args: $(yq_str "-object_writers=1 -max_bytes_per_sec=${SZ_BYTES_PER_SEC}")"
      fi
    elif ! is_multi_node; then
      echo "  replicaCount: 1"
    fi
    if ! is_multi_node; then
      echo "  replicaCountMl: 1"
      echo "  replicaCountSync: 1"
    fi
    echo
    echo "envoyGateway:"
    echo "  envoyProxy:"
    echo "    provider:"
    echo "      deployment:"
    echo "        replicaCount: $(is_multi_node && echo 2 || echo 1)"
    echo "      service:"
    case "${CLOUD_PROVIDER}" in
      aws)
        echo "        annotations:"
        echo "          service.beta.kubernetes.io/aws-load-balancer-type: external"
        echo "          service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: ip"
        echo "          service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing" ;;
      oci) echo "        {}   # OCI: chart default LoadBalancer annotations apply (an empty map keeps the defaults)" ;;
      *)   echo "        annotations: null   # no cloud LoadBalancer annotations" ;;
    esac
    echo
    echo "prometheus:"
    echo "  prometheus:"
    echo "    replicaCount: 1   # chart default is 2 x 15Gi"
    if ! is_multi_node; then
      echo "    resources:"
      echo "      requests:"
      echo "        memory: 2Gi"
      echo "        cpu: 300m"
      echo "      limits:"
      echo "        memory: 4Gi"
    fi
    if ! is_multi_node; then
      echo
      echo "# --- single-node sizing ---"
      echo "flash-discovery:"
      echo "  replicaCountDiscovery: 1"
      echo "flash-coffee:"
      echo "  coffee:"
      echo "    replicaCount: 1"
      echo "  coffee_worker:"
      echo "    replicaCount: 1"
      echo "redis:"
      echo "  master:"
      echo "    resources:"
      echo "      limits:"
      echo "        memory: 2000Mi"
    fi
    if [[ -n "${S3_CA_FILE}" ]]; then
      echo
      echo "# --- private-CA S3 endpoint: trust the CA in every Thanos component ---"
      echo "thanos:"
      local c
      for c in receive query bucketweb compactor storegateway ruler; do
        echo "  ${c}:"
        echo "    extraVolumes:"
        echo "      - name: s3-custom-ca"
        echo "        configMap:"
        echo "          name: ascent-s3-ca"
        echo "    extraVolumeMounts:"
        echo "      - name: s3-custom-ca"
        echo "        mountPath: /opt/bitnami/thanos/certs"
        echo "        readOnly: true"
        echo "    extraEnvVars:"
        echo "      - name: SSL_CERT_FILE"
        echo "        value: /opt/bitnami/thanos/certs/ca.crt"
      done
    fi
  } > "${values_file}.tmp"
  chmod 600 "${values_file}.tmp"; mv "${values_file}.tmp" "${values_file}"
  log "values written to ${values_file} (no credentials; those are supplied at deploy time)"
  if [[ "${SZ_ENABLED}" == "true" ]]; then info "sizing applied:"; sizing_summary; fi
}

write_secret_values() { # write_secret_values <file>: the credentials half of the values, never persisted
  local f="$1" key_b64=""
  [[ -n "${TLS_KEY_FILE}" ]] && key_b64="$(b64_file "${TLS_KEY_FILE}")"
  {
    echo "global:"
    echo "  environment:"
    echo "    s3_access: $(yq_str "${S3_ACCESS}")"
    echo "    s3_secret: $(yq_str "${S3_SECRET}")"
    echo "    AWS_ACCESS_KEY_ID: $(yq_str "${S3_ACCESS}")"
    echo "    AWS_SECRET_ACCESS_KEY: $(yq_str "${S3_SECRET}")"
    echo "    postgres_password: $(yq_str "${PG_PASSWORD}")"
    echo "    admin_password: $(yq_str "${ADMIN_PASSWORD}")"
    echo "    external_cert_key: $(yq_str "${key_b64}")"
    if [[ "${DB_ENGINE}" == "cnpg" ]]; then
      echo "cnpg:"; echo "  superuserSecret:"; echo "    password: $(yq_str "${PG_PASSWORD}")"
    else
      echo "postgres:"; echo "  postgresqlPassword: $(yq_str "${PG_PASSWORD}")"; echo "  postgresqlPostgresPassword: $(yq_str "${PG_PASSWORD}")"
    fi
  } > "${f}"
  chmod 600 "${f}"
}

# ---------------------------------------------------------------------------
# phase: deploy
# ---------------------------------------------------------------------------
create_ingest_secret() { # TLS material for syslog/relp ingest over TLS (docs: my-ascent-ingest)
  [[ -n "${TLS_CERT_FILE}" ]] || return 0
  local ca_file="${TLS_CA_FILE}" tmp=""
  if [[ -z "${ca_file}" ]]; then
    if [[ "$(grep -c 'BEGIN CERTIFICATE' "${TLS_CERT_FILE}" || true)" -ge 2 ]]; then
      tmp="$(mktemp)"; awk 'BEGIN{n=0} /BEGIN CERTIFICATE/{n++} n>=2' "${TLS_CERT_FILE}" > "${tmp}"; ca_file="${tmp}"
    else ca_file="${TLS_CERT_FILE}"; fi
  fi
  kubectl -n "${NAMESPACE}" create secret generic ascent-ingest \
    --from-file=syslog.crt="${TLS_CERT_FILE}" --from-file=syslog.key="${TLS_KEY_FILE}" --from-file=ca.crt="${ca_file}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  [[ -n "${tmp}" ]] && rm -f "${tmp}"
  log "ingest TLS secret ascent-ingest applied"
}

reconcile_release_state() { # recover from interrupted/failed first installs
  local st rev
  helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || return 0
  st="$(helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null | awk '/^STATUS:/{print $2}' || true)"
  rev="$(helm status "${RELEASE_NAME}" -n "${NAMESPACE}" 2>/dev/null | awk '/^REVISION:/{print $2}' || true)"
  [[ -n "${st}" ]] || return 0
  case "${st}" in
    deployed) info "release ${RELEASE_NAME} exists (revision ${rev}) — upgrading in place" ;;
    pending-*) [[ "${rev}" == "1" ]] || { unstick_release "${RELEASE_NAME}" "${NAMESPACE}"; return 0; } ;&
    failed|pending-install|pending-upgrade|pending-rollback|uninstalling)
      if [[ "${rev}" == "1" ]]; then
        warn "release ${RELEASE_NAME} is '${st}' at revision 1 (broken first install) — uninstalling it before installing again (volumes are kept)"
        gateway_api_pre_uninstall
        helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 5m || true
        clear_stale_gatewayclass
      elif [[ "${st}" == pending-* ]]; then
        warn "release ${RELEASE_NAME} is stuck in '${st}' — rolling back to the previous revision first"
        helm rollback "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 5m || true
      else info "release ${RELEASE_NAME} is '${st}' (revision ${rev}) — upgrading"; fi ;;
    *) info "release ${RELEASE_NAME} status '${st}'" ;;
  esac
}

phase_deploy() {
  CURRENT_PHASE="deploy"
  require_config_complete
  local values_file="${INSTALL_DIR}/values.yaml"
  [[ -f "${values_file}" ]] || die "values file missing — run the 'values' phase first"
  grep -q "^  domain: $(yq_str "${DOMAIN}")" "${values_file}" || die "values file was generated for another configuration — run the 'values' phase first"
  ensure_tls_material

  kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  create_ingest_secret
  if [[ -n "${S3_CA_FILE}" ]]; then
    kubectl -n "${NAMESPACE}" create configmap ascent-s3-ca --from-file=ca.crt="${S3_CA_FILE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    log "S3 CA configmap ascent-s3-ca applied"
  fi
  reconcile_release_state
  clear_stale_gatewayclass

  local secrets_values="${TMP_DIR}/secrets.values.yaml"
  write_secret_values "${secrets_values}"
  local -a extra=(-f "${secrets_values}"); [[ -n "${EXTRA_VALUES_FILE}" ]] && extra+=(-f "${EXTRA_VALUES_FILE}")
  local chart_ref
  if [[ "${CHART_SOURCE}" == "path" ]]; then
    [[ -d "${CHART_PATH}" ]] || die "CHART_PATH not found: ${CHART_PATH}"
    chart_ref="${CHART_PATH}"
    log "deploying apica-ascent from local path ${CHART_PATH}"
    helm upgrade --install "${RELEASE_NAME}" "${chart_ref}" \
      -n "${NAMESPACE}" --create-namespace -f "${values_file}" "${extra[@]}" --timeout 20m
  else
    helm repo list 2>/dev/null | grep -q '^apica-repo\s' || { helm repo add apica-repo "${CHART_REPO_URL}" >/dev/null; mark added.helm-repo.apica-repo; }
    helm repo update apica-repo > /dev/null
    [[ "${UPLOAD_DASHBOARD}" == "true" ]] && warn "UPLOAD_DASHBOARD=true: helm blocks until the chart's dashboard-upload hook succeeds (up to 20m); it fails with 401 on some chart/app versions"
    log "deploying apica-ascent ${CHART_VERSION} from ${CHART_REPO_URL}"
    helm upgrade --install "${RELEASE_NAME}" apica-repo/apica-ascent \
      --version "${CHART_VERSION}" \
      -n "${NAMESPACE}" --create-namespace -f "${values_file}" "${extra[@]}" --timeout 20m
  fi
  rm -f "${secrets_values}"
  state_set app.chart_version "${CHART_VERSION}"; state_set app.db_engine "${DB_ENGINE}"; state_set app.ingest_gb_per_day "${INGEST_GB_PER_DAY:-unset}"
  log "deploy OK (release ${RELEASE_NAME} in ${NAMESPACE})"
}

# ---------------------------------------------------------------------------
# phase: verify
# ---------------------------------------------------------------------------
PROBE_IP=""
gateway_probe_ip() { # IP to reach the gateway: its reported address (IP or hostname), else LB_IP
  local addr; addr="$(kubectl get gateway -n "${NAMESPACE}" -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)"
  if is_ipv4 "${addr}"; then PROBE_IP="${addr}"
  elif [[ -n "${addr}" ]]; then PROBE_IP="$(resolve4 "${addr}" | head -n1)"
  else PROBE_IP="${LB_IP}"; fi
  GATEWAY_ADDR="${addr:-${LB_IP}}"
}
GATEWAY_ADDR=""
verify_admin_login() { # coffee bootstraps the admin account 1-3 minutes after it starts; a successful login redirects away from /login and /setup
  local i code target
  for i in $(seq 1 30); do
    # read returns 1 at EOF without a trailing newline; keep that from triggering set -e
    read -r code target < <(curl -k -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --connect-timeout 10 --max-time 20 \
        --resolve "${DOMAIN}:443:${PROBE_IP}" -X POST "https://${DOMAIN}/login" \
        --data-urlencode "email=${ADMIN_EMAIL}" --data-urlencode "password=${ADMIN_PASSWORD}" 2>/dev/null || echo "000") || true
    code="${code:-000}"; target="${target:-}"
    if [[ "${code}" == 302 && "${target}" != *"/setup"* && "${target}" != *"/login"* ]]; then
      log "admin login accepted for ${ADMIN_EMAIL} (UI redirects to ${target})"; return 0
    fi
    (( i % 6 == 0 )) && info "waiting for the admin account to be bootstrapped (last: HTTP ${code} → ${target:-no redirect})"
    sleep 10
  done
  warn "admin login was not accepted after 5 minutes (last HTTP ${code} → ${target:-no redirect}) — coffee may still be initialising; check: kubectl logs -n ${NAMESPACE} coffee-server-0"
}

phase_verify() {
  CURRENT_PHASE="verify"
  require_config_complete
  have_kubectl || die "kubectl cannot reach the cluster — run the 'k0s' phase first"
  [[ "$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)" -gt 0 ]] \
    || die "no pods found in namespace ${NAMESPACE} — was the 'deploy' phase run with this config?"
  log "verify: waiting for all pods in ${NAMESPACE} to be healthy (up to 15m)"
  local i bad=""
  for i in $(seq 1 90); do
    bad="$(pods_unhealthy "${NAMESPACE}")"
    [[ -z "${bad}" ]] && break
    (( i % 6 == 0 )) && info "still waiting on: $(awk '{print $1"("$2")"}' <<<"${bad}" | tr '\n' ' ')"
    sleep 10
  done
  if [[ -n "${bad}" ]]; then
    echo "${bad}" | sed 's/^/  not healthy: /'
    die "some pods did not become healthy within 15 minutes"
  fi
  log "all pods Running/Completed"

  local gw_prog; gw_prog="$(kubectl get gateway -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null || true)"
  local gw_addr; gw_addr="$(kubectl get gateway -n "${NAMESPACE}" -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null || true)"
  [[ "${gw_prog}" == "True" ]] && log "gateway programmed, address ${gw_addr:-<none>}" || warn "gateway not programmed yet (status '${gw_prog:-unknown}')"
  [[ -z "${LB_IP}" || -z "${gw_addr}" || "${gw_addr}" == "${LB_IP}" ]] || warn "gateway address ${gw_addr} differs from LB_IP ${LB_IP}"

  local i; for i in 1 2 3 4 5 6; do gateway_probe_ip; [[ -n "${PROBE_IP}" ]] && break; sleep 10; done
  [[ -n "${PROBE_IP}" ]] || die "the gateway has no address yet (LoadBalancer pending?) — check: kubectl get svc -n ${NAMESPACE}"
  local code
  code="$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 --resolve "${DOMAIN}:443:${PROBE_IP}" "https://${DOMAIN}/" || echo 000)"
  [[ "${code}" =~ ^(200|30[0-9])$ ]] && log "HTTPS probe via ${GATEWAY_ADDR} (SNI ${DOMAIN}): HTTP ${code}" || warn "HTTPS probe via ${GATEWAY_ADDR} returned HTTP ${code} — the UI may still be starting; retry in a minute"
  if [[ -n "${PUBLIC_IP}" ]]; then
    code="$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 20 --resolve "${DOMAIN}:443:${PUBLIC_IP}" "https://${DOMAIN}/" || echo 000)"
    [[ "${code}" =~ ^(200|30[0-9])$ ]] && log "HTTPS probe via public IP ${PUBLIC_IP}: HTTP ${code}" || warn "HTTPS probe via public IP ${PUBLIC_IP} returned HTTP ${code} — check the cloud security list / NAT for 443"
  fi

  verify_admin_login

  cat <<EOF

============================================================
 Apica Ascent installed  ($(elapsed) total)
   URL:        https://${DOMAIN}   (DNS: point ${DOMAIN} at ${PUBLIC_IP:-${GATEWAY_ADDR}})
   Login:      ${ADMIN_NAME} / (ADMIN_PASSWORD from your config)
   Ingest:     ${GATEWAY_ADDR} ports 9999 (flash), 8081, 14250/14268 (jaeger), 20514 (syslog TLS)
   Namespace:  ${NAMESPACE}   release: ${RELEASE_NAME}   database: ${DB_ENGINE}
   Sizing:     $([[ "${SZ_ENABLED}" == true ]] && echo "${INGEST_GB_PER_DAY} GB/day ${INGEST_MODE} → ${SZ_PODS} flash pod(s) × ${SZ_POD_CPU} CPU/${SZ_POD_MEM_GI} GiB, limit ${SZ_BYTES_PER_SEC} B/s" || echo "chart defaults (set INGEST_GB_PER_DAY; the chart's default rate limit applies)")
   Values:     ${INSTALL_DIR}/values.yaml
   Log:        ${LOG_FILE}
   Status:     ${BASH_SOURCE[0]} status ${CONFIG_FILE:+--config ${CONFIG_FILE}}
   Upgrade:    edit CHART_VERSION, then ${BASH_SOURCE[0]} app upgrade ${CONFIG_FILE:+--config ${CONFIG_FILE}}
   Support:    ${BASH_SOURCE[0]} diagnose ${CONFIG_FILE:+--config ${CONFIG_FILE}}
 Next: configure outbound mail (Settings → Mail) before using password reset.
============================================================
EOF
}

# ---------------------------------------------------------------------------
# Gateway API cleanup. The chart runs its envoy-gateway controller inside the release namespace and
# helm deletes that Deployment before the Gateway/GatewayClass objects, leaving their finalizers
# unprocessed. Delete those objects first, while the controller is still running.
# ---------------------------------------------------------------------------
release_gatewayclass() { echo "${RELEASE_NAME}-gateway-class-local"; }

clear_stale_gatewayclass() { # Terminating GatewayClass with no Gateways left: nobody will ever free it
  have_kubectl || return 0
  local gc del refs; gc="$(release_gatewayclass)"
  kubectl get gatewayclass "${gc}" >/dev/null 2>&1 || return 0
  del="$(kubectl get gatewayclass "${gc}" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)"
  refs="$(kubectl get gateway -A -o jsonpath="{.items[?(@.spec.gatewayClassName==\"${gc}\")].metadata.name}" 2>/dev/null)"
  if [[ -n "${del}" && -z "${refs}" ]]; then
    warn "GatewayClass ${gc} has been stuck in Terminating since ${del} with no Gateway referencing it — clearing its finalizer"
    kubectl patch gatewayclass "${gc}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
    kubectl delete gatewayclass "${gc}" --ignore-not-found --timeout=30s >/dev/null 2>&1 || true
  fi
}

gateway_api_pre_uninstall() {
  have_kubectl || return 0
  kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || { clear_stale_gatewayclass; return 0; }
  log "removing Gateway API objects first (their finalizers need the in-namespace envoy-gateway controller alive)"
  kubectl delete httproute,tcproute --all -n "${NAMESPACE}" --ignore-not-found --timeout=90s 2>&1 | sed 's/^/  /' || true
  kubectl delete gateway --all -n "${NAMESPACE}" --ignore-not-found --timeout=120s 2>&1 | sed 's/^/  /' || true
  kubectl delete gatewayclass "$(release_gatewayclass)" --ignore-not-found --timeout=90s 2>&1 | sed 's/^/  /' || true
  clear_stale_gatewayclass
}

# ---------------------------------------------------------------------------
# phase: uninstall (application only; the cluster stays)
# ---------------------------------------------------------------------------
phase_uninstall() {
  CURRENT_PHASE="uninstall"
  have_kubectl || die "kubectl cannot reach the cluster"
  echo "This removes the helm release '${RELEASE_NAME}' AND deletes namespace '${NAMESPACE}' including all"
  echo "persistent volumes (log data, metrics, Postgres). The k0s cluster, MetalLB, OpenEBS and Envoy stay."
  confirm "Type the release name (${RELEASE_NAME}) to confirm: " "^${RELEASE_NAME}\$" || die "aborted (answer did not match the release name)"
  gateway_api_pre_uninstall
  if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
    log "helm uninstall ${RELEASE_NAME}"
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 5m 2>&1 | sed 's/^/  /' || warn "helm uninstall reported an error; continuing with namespace deletion"
  else info "release ${RELEASE_NAME} not found in ${NAMESPACE}"; fi
  log "deleting namespace ${NAMESPACE} (waits for volumes to be released)"
  kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait --timeout=10m
  clear_stale_gatewayclass
  local left; left="$(kubectl get pv --no-headers 2>/dev/null | awk -v ns="${NAMESPACE}/" '$6 ~ "^"ns {print $1}' | tr '\n' ' ')"
  # shellcheck disable=SC2086
  [[ -z "${left}" ]] || { warn "deleting leftover PVs: ${left}"; kubectl delete pv ${left} --wait=false || true; }
  log "uninstall OK — the application and its data are gone; run 'all' or 'deploy' to reinstall"
}

# ---------------------------------------------------------------------------
# phase: cleanup (everything this script created, in reverse order, nothing else)
# ---------------------------------------------------------------------------
phase_cleanup() {
  CURRENT_PHASE="cleanup"
  disarm_traps; set +e
  local plan=() ip
  plan+=("helm release ${RELEASE_NAME} + namespace ${NAMESPACE} (all Ascent data)")
  marked installed.cnpg-operator-release && plan+=("helm release cnpg-operator + namespace cnpg-system")
  marked installed.envoy-release         && plan+=("helm release eg (Envoy Gateway) + namespace envoy-gateway-system")
  marked applied.metallb-pool            && plan+=("MetalLB IPAddressPool/L2Advertisement ascent-pool/ascent-l2")
  for k in $(state_keys "joined.worker."); do plan+=("worker ${k#joined.worker.}: k0s stop + reset (node leaves the cluster, data wiped)"); done
  marked created.k0s-cluster             && plan+=("k0s cluster on this controller: k0s stop + reset (ALL cluster data wiped)")
  { marked firewall.chain.created || marked applied.iptables; } && plan+=("iptables chains ASCENT-INSTALLER / ASCENT-INSTALLER-NAT (customer rules and policies untouched)")
  for k in $(state_keys "firewall.worker."); do plan+=("worker ${k#firewall.worker.}: iptables chains added by the installer"); done
  marked wrote.k0s-config                && plan+=("/etc/k0s/k0s.yaml (backup restored if one exists)")
  marked wrote.kubeconfig                && plan+=("${HOME}/.kube/config (backup restored if one exists)")
  for b in k0s kubectl helm; do marked "installed.${b}-binary" && plan+=("/usr/local/bin/${b}"); done
  for k in $(state_keys "installed.k0s-binary.worker."); do plan+=("worker ${k#installed.k0s-binary.worker.}: /usr/local/bin/k0s"); done
  for r in apica-repo cnpg; do marked "added.helm-repo.${r}" && plan+=("helm repo entry ${r}"); done
  plan+=("${INSTALL_DIR}/{values.yaml,tls,downloads,state} (logs are kept)")

  echo "cleanup will remove ONLY what this installer created (tracked in ${STATE_FILE}):"
  printf '  - %s\n' "${plan[@]}"
  marked created.k0s-cluster || echo "  (the k0s cluster existed before this installer or was adopted — it is left alone)"
  confirm "Type 'cleanup' to confirm: " '^cleanup$' || { echo "aborted"; exit 1; }

  if have_kubectl; then
    log "removing helm release ${RELEASE_NAME} and namespace ${NAMESPACE}"
    gateway_api_pre_uninstall
    helm uninstall "${RELEASE_NAME}" -n "${NAMESPACE}" --wait --timeout 5m 2>&1 | sed 's/^/  /'
    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait --timeout=10m 2>&1 | sed 's/^/  /'
    clear_stale_gatewayclass
    kubectl get pv --no-headers 2>/dev/null | awk -v ns="${NAMESPACE}/" '$6 ~ "^"ns {print $1}' | xargs -r kubectl delete pv --wait=false 2>/dev/null
    if marked installed.cnpg-operator-release; then
      log "removing cnpg-operator"; helm uninstall cnpg-operator -n cnpg-system --wait --timeout 5m 2>&1 | grep -vE "resource policy|CustomResourceDefinition|^\s*$" | sed 's/^/  /'
      kubectl delete namespace cnpg-system --ignore-not-found --wait --timeout=5m 2>&1 | sed 's/^/  /'
      # the operator chart keeps its CRDs; drop them only when no CNPG cluster is left anywhere
      if [[ -z "$(kubectl get clusters.postgresql.cnpg.io -A --no-headers 2>/dev/null)" ]]; then
        log "removing CloudNativePG CRDs (no clusters left)"
        kubectl get crd -o name 2>/dev/null | grep '\.cnpg\.io$' | xargs -r kubectl delete --timeout=60s 2>&1 | sed 's/^/  /'
      else warn "CNPG clusters exist outside this release — keeping the CloudNativePG CRDs"; fi
    fi
    if marked installed.envoy-release; then
      log "removing envoy gateway"; helm uninstall eg -n envoy-gateway-system --wait --timeout 5m 2>&1 | sed 's/^/  /'
      kubectl delete namespace envoy-gateway-system --ignore-not-found --wait --timeout=5m 2>&1 | sed 's/^/  /'
    fi
    if marked applied.metallb-pool && ! marked created.k0s-cluster; then
      log "removing metallb address pool"; kubectl delete ipaddresspool ascent-pool l2advertisement ascent-l2 -n metallb --ignore-not-found 2>&1 | sed 's/^/  /'
    fi
  else
    warn "cluster not reachable via kubectl — skipping in-cluster removals"
  fi

  local k
  for k in $(state_keys "joined.worker."); do
    ip="${k#joined.worker.}"
    log "worker ${ip}: k0s stop + reset"
    ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo k0s stop 2>/dev/null; sudo k0s reset 2>&1 | tail -n 3; sudo rm -f /etc/k0s/token" | sed 's/^/  /' || warn "worker ${ip}: reset failed (unreachable?)"
    if marked "firewall.worker.${ip}.chain.created" || marked "applied.iptables.worker.${ip}"; then
      local wl="false"; marked "applied.iptables.worker.${ip}" && wl="true"
      ssh_worker "${ip}" "bash -s" <<<"$(fw_script remove "${WORKER_PORTS}" false "${wl}")" || true
    fi
    marked "installed.k0s-binary.worker.${ip}" && ssh_worker "${ip}" "${REMOTE_PRELUDE}; sudo rm -f /usr/local/bin/k0s" || true
  done

  if marked created.k0s-cluster; then
    log "stopping and resetting k0s on the controller (this wipes all cluster state)"
    sudo k0s stop 2>&1 | sed 's/^/  /'
    sudo k0s reset 2>&1 | tail -n 5 | sed 's/^/  /'
  fi
  if marked firewall.chain.created || marked applied.iptables; then
    log "removing the installer's iptables chains"
    local ll="false"; marked applied.iptables && ll="true"
    bash -c "$(fw_script remove "${CONTROLLER_PORTS}" false "${ll}")" || true
  fi
  if marked wrote.k0s-config; then
    local bak; bak="$(ls -1t /etc/k0s/k0s.yaml.bak-* 2>/dev/null | head -n1)"
    if [[ -n "${bak}" ]]; then sudo mv "${bak}" /etc/k0s/k0s.yaml; log "restored /etc/k0s/k0s.yaml from ${bak##*/}"
    else sudo rm -f /etc/k0s/k0s.yaml; sudo rmdir /etc/k0s 2>/dev/null; fi
  fi
  if marked wrote.kubeconfig; then
    local kb; kb="$(ls -1t "${HOME}"/.kube/config.bak-* 2>/dev/null | head -n1)"
    if [[ -n "${kb}" ]]; then mv "${kb}" "${HOME}/.kube/config"; log "restored ~/.kube/config from ${kb##*/}"
    else rm -f "${HOME}/.kube/config"; fi
  fi
  for r in apica-repo cnpg; do marked "added.helm-repo.${r}" && helm repo remove "${r}" >/dev/null 2>&1; done
  for b in k0s kubectl helm; do marked "installed.${b}-binary" && { sudo rm -f "/usr/local/bin/${b}"; log "removed /usr/local/bin/${b}"; }; done
  rm -rf "${INSTALL_DIR}/values.yaml" "${INSTALL_DIR}/tls" "${INSTALL_DIR}/downloads" "${STATE_DIR}"
  set -e; arm_traps
  log "cleanup OK ($(elapsed)). Logs kept in ${INSTALL_DIR}/logs."
  marked_reboot_hint
}
marked_reboot_hint() { command -v k0s >/dev/null 2>&1 || echo "  A reboot is recommended after 'k0s reset' to clear leftover network interfaces and mounts."; }

# ---------------------------------------------------------------------------
# orchestration
# ---------------------------------------------------------------------------
phase_done() { state_set installer.last_completed_phase "$1"; state_set "phase.$1.completed_at" "$(date -u +%FT%TZ)"; state_set installer.version "${INSTALLER_VERSION}"; }
run_phase() { "phase_$1"; phase_done "$1"; }
resume_plan() {
  local last; last="$(state_get installer.last_completed_phase)"
  [[ -n "${last}" ]] && info "state: last completed phase was '${last}' ($(state_get "phase.${last}.completed_at")); earlier phases are re-verified, not skipped"
  return 0
}
require_platform() {
  local hint="run: ${BASH_SOURCE[0]} platform install ${CONFIG_FILE:+--config ${CONFIG_FILE}}"
  have_kubectl || die "the platform is not installed or kubectl cannot reach it — ${hint}"
  local missing=""
  kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 || missing="${missing} storage-class:${STORAGE_CLASS}"
  existing_cluster || kubectl get ipaddresspool -n metallb >/dev/null 2>&1 || missing="${missing} metallb"
  kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 || missing="${missing} envoy-gateway"
  [[ "${DB_ENGINE}" != "cnpg" ]] || kubectl get crd clusters.postgresql.cnpg.io >/dev/null 2>&1 || missing="${missing} cnpg-operator"
  [[ -z "${missing}" ]] || die "platform components missing:${missing} — ${hint}"
}
require_release()  { helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1 || die "release ${RELEASE_NAME} does not exist in ${NAMESPACE} — use 'app install'"; }
run_platform_install() { for ph in network k0s workers addons envoy cnpg; do run_phase "${ph}"; done; state_set platform.installed true; }
run_app_install()      { require_platform; for ph in values deploy verify; do run_phase "${ph}"; done; state_set app.installed true; }

cmd_app_rollback() {
  CURRENT_PHASE="app-rollback"; require_platform; require_release
  echo "helm history of ${RELEASE_NAME}:"; helm history "${RELEASE_NAME}" -n "${NAMESPACE}" | sed 's/^/  /'
  local prev; prev="$(helm history "${RELEASE_NAME}" -n "${NAMESPACE}" --max 50 2>/dev/null | awk '$7=="superseded"{r=$1} END{print r}')"
  [[ -n "${prev}" ]] || die "no previous revision to roll back to"
  confirm "Roll back to revision ${prev}? [y/N] " '^[Yy]$' || { echo "aborted"; exit 1; }
  log "rolling back ${RELEASE_NAME} to revision ${prev}"
  helm rollback "${RELEASE_NAME}" "${prev}" -n "${NAMESPACE}" --wait --timeout 15m
  run_phase verify
}

cmd_status() {
  CURRENT_PHASE="status"; disarm_traps; set +e
  echo "== installer state (${STATE_FILE}) =="
  echo "  installer version: $(state_get installer.version) | last completed phase: $(state_get installer.last_completed_phase)"
  echo "  cluster: $(marked created.k0s-cluster && echo 'created by installer' || { [[ "$(state_get cluster.adopted)" == true ]] && echo adopted || echo 'not recorded'; }) (id $(state_get cluster.uid | cut -c1-8))"
  echo "  platform installed: $(state_get platform.installed) | app installed: $(state_get app.installed) (chart $(state_get app.chart_version), db $(state_get app.db_engine))"
  echo "== host =="; echo "  $(hostname) ${PRIVATE_IP} $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-}") | $(nproc) CPU, $(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo) GiB"
  echo "== platform =="
  if existing_cluster; then echo "  mode: existing cluster, context $(kubectl config current-context 2>/dev/null || echo '?')"
  elif k0s_running; then echo "  k0s: running $(k0s version 2>/dev/null) ($(sudo -n k0s status 2>/dev/null | awk '/^Role:/{print $2}'))"
  elif [[ -n "$(k0s_unit)" ]]; then echo "  k0s: service installed but STOPPED"; else echo "  k0s: not installed"; fi
  if have_kubectl; then
    kubectl get nodes -o wide --no-headers 2>/dev/null | awk '{print "  node: "$1" "$2" "$5" "$6}'
    echo "  releases: $(helm ls -A --no-headers 2>/dev/null | awk '{printf "%s(%s) ", $1, $8}')"
    echo "  storage class ${STORAGE_CLASS}: $(kubectl get sc "${STORAGE_CLASS}" >/dev/null 2>&1 && echo present || echo MISSING) | metallb pool: $(kubectl get ipaddresspool -n metallb -o jsonpath='{.items[*].spec.addresses[*]}' 2>/dev/null)"
    echo "== application =="
    if helm status "${RELEASE_NAME}" -n "${NAMESPACE}" >/dev/null 2>&1; then
      echo "  release: $(helm ls -n "${NAMESPACE}" --no-headers 2>/dev/null | awk -v r="${RELEASE_NAME}" '$1==r{print $8" revision "$3" "$9}')"
      local total bad; total="$(kubectl get pods -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)"; bad="$(pods_unhealthy "${NAMESPACE}")"
      echo "  pods: $(( total - $(grep -c . <<<"${bad}") ))/${total} healthy"; [[ -z "${bad}" ]] || echo "${bad}" | sed 's/^/    not healthy: /'
      echo "  gateway: programmed=$(kubectl get gateway -n "${NAMESPACE}" -o jsonpath='{.items[0].status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null) address=$(kubectl get gateway -n "${NAMESPACE}" -o jsonpath='{.items[0].status.addresses[0].value}' 2>/dev/null)"
      [[ "${DB_ENGINE}" == "cnpg" ]] && echo "  cnpg: $(kubectl get cluster -n "${NAMESPACE}" -o jsonpath='{.items[0].status.phase} ({.items[0].status.readyInstances}/{.items[0].spec.instances} ready)' 2>/dev/null)"
      gateway_probe_ip
      echo "  https: HTTP $(curl -k -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "${DOMAIN}:443:${PROBE_IP:-127.0.0.1}" "https://${DOMAIN}/" 2>/dev/null) via ${GATEWAY_ADDR:-<no address>}"
      local code target; read -r code target < <(curl -k -s -o /dev/null -w '%{http_code} %{redirect_url}\n' --max-time 15 --resolve "${DOMAIN}:443:${PROBE_IP:-127.0.0.1}" -X POST "https://${DOMAIN}/login" --data-urlencode "email=${ADMIN_EMAIL}" --data-urlencode "password=${ADMIN_PASSWORD}" 2>/dev/null || echo 000) || true
      if [[ "${code:-}" == 302 && "${target:-}" != *"/setup"* && "${target:-}" != *"/login"* ]]; then echo "  admin login: accepted"; else echo "  admin login: NOT accepted (HTTP ${code:-000} → ${target:-none})"; fi
    else echo "  release ${RELEASE_NAME}: not installed"; fi
  fi
  set -e; arm_traps
}

cmd_diagnose() {
  CURRENT_PHASE="diagnose"; disarm_traps; set +e
  local ts d out; ts="$(date +%Y%m%d-%H%M%S)"; d="${TMP_DIR}/ascent-diagnostics-${ts}"; mkdir -p "${d}/host" "${d}/k0s" "${d}/kubernetes" "${d}/app" "${d}/installer"
  local ns="${NAMESPACE}"
  c() { local f="$1"; shift; { "$@"; } 2>&1 | redact > "${d}/${f}"; }   # every file is redacted
  log "collecting host information"
  c host/os-release.txt cat /etc/os-release; c host/uname.txt uname -a; c host/cpu-mem.txt sh -c 'nproc; free -m'; c host/disk.txt df -h
  c host/ip-addr.txt ip -o addr; c host/ip-route.txt ip route; c host/resolv.conf cat /etc/resolv.conf; c host/hosts.txt cat /etc/hosts
  c host/timedatectl.txt timedatectl; c host/listening.txt sudo -n ss -Hltnp; c host/iptables-filter.txt sudo -n iptables -S; c host/iptables-nat.txt sudo -n iptables -t nat -S
  c host/firewalld.txt systemctl is-active firewalld; c host/ufw.txt sudo -n ufw status; c host/swap.txt swapon --show; c host/dmi.txt cat /sys/class/dmi/id/chassis_asset_tag /sys/class/dmi/id/sys_vendor
  log "collecting k0s information"
  c k0s/status.txt sudo -n k0s status; c k0s/version.txt k0s version; c k0s/config.yaml sudo -n cat /etc/k0s/k0s.yaml
  c k0s/journal.txt sudo -n journalctl -u k0scontroller -u k0sworker --no-pager -n 800
  if have_kubectl; then
    log "collecting kubernetes information"
    c kubernetes/nodes.txt kubectl get nodes -o wide; c kubernetes/nodes-describe.txt kubectl describe nodes
    c kubernetes/pods-all.txt kubectl get pods -A -o wide; c kubernetes/events-all.txt kubectl get events -A --sort-by=.lastTimestamp
    c kubernetes/pv-pvc.txt sh -c 'kubectl get pv; kubectl get pvc -A'; c kubernetes/storageclass.txt kubectl get sc
    c kubernetes/helm-releases.txt helm ls -A; c kubernetes/metallb.txt kubectl get ipaddresspool,l2advertisement -A -o yaml
    c kubernetes/gateway.txt sh -c "kubectl get gatewayclass -o yaml; kubectl get gateway,httproute,tcproute -A -o yaml"
    c kubernetes/k0s-charts.txt kubectl get charts.helm.k0sproject.io -n kube-system -o yaml
    c kubernetes/kube-system-pods.txt kubectl get pods -n kube-system -o wide
    log "collecting application information (${ns})"
    c app/helm-status.txt helm status "${RELEASE_NAME}" -n "${ns}"; c app/helm-history.txt helm history "${RELEASE_NAME}" -n "${ns}"
    c app/pods.txt kubectl get pods -n "${ns}" -o wide; c app/describe-pods.txt kubectl describe pods -n "${ns}"
    c app/events.txt kubectl get events -n "${ns}" --sort-by=.lastTimestamp; c app/services.txt kubectl get svc,endpoints -n "${ns}" -o wide
    c app/jobs.txt kubectl get jobs -n "${ns}" -o wide; c app/cnpg.txt kubectl describe cluster -n "${ns}"
    c app/statefulsets-deployments.txt kubectl get sts,deploy -n "${ns}" -o wide
    local pod; mkdir -p "${d}/app/logs"
    for pod in $(kubectl get pods -n "${ns}" -o name 2>/dev/null); do
      c "app/logs/${pod#pod/}.log" kubectl logs -n "${ns}" "${pod}" --all-containers --tail=300 --timestamps
      c "app/logs/${pod#pod/}.previous.log" kubectl logs -n "${ns}" "${pod}" --all-containers --tail=100 --previous
    done
    c app/https-probe.txt curl -k -sv -o /dev/null --max-time 10 --resolve "${DOMAIN}:443:${LB_IP}" "https://${DOMAIN}/"
  fi
  log "collecting installer information"
  c installer/state.txt cat "${STATE_FILE}"; c installer/config.txt cat "${CONFIG_FILE:-/dev/null}"
  c installer/values.yaml cat "${INSTALL_DIR}/values.yaml"; c installer/version.txt echo "ascent-install v${INSTALLER_VERSION}"
  mkdir -p "${d}/installer/logs"; cp "${INSTALL_DIR}"/logs/*.log "${d}/installer/logs/" 2>/dev/null
  find "${d}" -type f -size 0 -delete
  mkdir -p "${INSTALL_DIR}/diagnostics"; out="${INSTALL_DIR}/diagnostics/ascent-diagnostics-${ts}.tar.gz"
  tar -C "${TMP_DIR}" -czf "${out}" "ascent-diagnostics-${ts}"; chmod 600 "${out}"
  set -e; arm_traps
  log "support bundle written: ${out} ($(du -h "${out}" | cut -f1)) — passwords, keys and tokens are redacted; review before sharing"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
banner
info "command '${PHASE//-/ }' — log ${LOG_FILE}"
[[ -z "${CLI_SECRET_FLAGS}" ]] || warn "secrets passed as command-line options (${CLI_SECRET_FLAGS# }) are visible in shell history and process lists — prefer the prompt, ASCENT_<VAR> variables or ascent-secrets.conf"
case "${PHASE}" in
  preflight) phase_preflight || exit 1 ;;
  network|k0s|workers|addons|envoy|cnpg|values|deploy|verify) run_phase "${PHASE}" ;;
  uninstall|app-uninstall)   phase_uninstall ;;
  cleanup|platform-uninstall) phase_cleanup ;;
  status|platform-status|app-status) cmd_status ;;
  diagnose) cmd_diagnose ;;
  platform-install) phase_preflight || exit 1; resume_plan; run_platform_install; log "platform install OK ($(elapsed))" ;;
  app-install)  run_app_install ;;
  app-upgrade)  require_platform; require_release; run_app_install ;;
  app-rollback) cmd_app_rollback ;;
  worker-join)  require_platform; WORKERS="${WORKER_JOIN_ARG}"; run_phase workers ;;
  all)
    phase_preflight || exit 1
    resume_plan
    run_platform_install
    run_app_install
    ;;
esac
}

main "$@"
