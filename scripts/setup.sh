#!/usr/bin/env bash
set -euo pipefail

# AWS Community Day Romania 2026 — Workshop Prerequisites
# Installs Terraform, AWS CLI v2, kubectl, Helm, jq, git
# Platforms: macOS (Homebrew), Linux (direct download to ~/.local/bin)
# Usage: ./setup.sh [--check] [--help]

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(dirname "$SCRIPT_DIR")"

CHECK_ONLY=false

# Minimum acceptable versions; installs latest if below these
readonly TERRAFORM_VERSION="1.12.0"
readonly KUBECTL_VERSION="1.35.0"  # should track EKS cluster version ±1 minor
readonly HELM_VERSION="3.17.0"

readonly LOCAL_BIN="$HOME/.local/bin"

# Parallel arrays (bash 3.2 compat, no associative arrays)
RESULT_TOOLS=()
RESULT_STATUS=()

# ─── Usage ───────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install workshop prerequisites: Terraform, AWS CLI v2, kubectl, Helm, jq, git.

Options:
  --check    Verify all tools are installed without installing anything
  --help     Show this help message

Examples:
  $(basename "$0")           # Install missing tools
  $(basename "$0") --check   # Pre-workshop readiness check
EOF
}

# ─── Argument parsing ────────────────────────────────────

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)  CHECK_ONLY=true; shift ;;
      --help|-h) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

# ─── Logging ─────────────────────────────────────────────

info()  { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*"; }

# ─── Helpers ─────────────────────────────────────────────

command_exists() { command -v "$1" &>/dev/null; }

# Returns 0 if $1 >= $2 (semver, handles optional 'v' prefix)
version_gte() {
  local have="${1#v}" need="${2#v}"
  local first
  first="$(printf '%s\n%s\n' "$need" "$have" | sort -V | head -1)"
  [[ "$first" == "$need" ]]
}

record_result() { RESULT_TOOLS+=("$1"); RESULT_STATUS+=("$2"); }

get_result() {
  local tool="$1"
  for i in "${!RESULT_TOOLS[@]}"; do
    [[ "${RESULT_TOOLS[$i]}" == "$tool" ]] && echo "${RESULT_STATUS[$i]}" && return
  done
  echo "unknown"
}

# Sets globals: OS (darwin|linux), ARCH (amd64|arm64)
detect_platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)        ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) err "Unsupported architecture: $ARCH"; exit 1 ;;
  esac
  info "Detected platform: ${OS}/${ARCH}"
}

check_prerequisites() {
  local missing=()
  for cmd in curl unzip; do
    command_exists "$cmd" || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Required commands not found: ${missing[*]}"
    [[ "$OS" == "linux" ]] && err "Try: sudo apt-get install -y ${missing[*]}"
    exit 1
  fi
}

ensure_local_bin() {
  mkdir -p "$LOCAL_BIN"
  if [[ ":$PATH:" != *":$LOCAL_BIN:"* ]]; then
    export PATH="$LOCAL_BIN:$PATH"
    warn "$LOCAL_BIN was not on PATH — added for this session."
    warn "Add 'export PATH=\"\$HOME/.local/bin:\$PATH\"' to your shell profile."
  fi
}

# ─── Checksum ────────────────────────────────────────────

# Cross-platform SHA-256 (Linux: sha256sum, macOS: shasum)
compute_sha256() {
  local file="$1"
  if command_exists sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif command_exists shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

verify_checksum() {
  local file="$1" expected="$2"
  if [[ -z "$expected" ]]; then
    warn "No checksum available — skipping verification"
    return 0
  fi
  local actual
  actual="$(compute_sha256 "$file")"
  if [[ -z "$actual" ]]; then
    warn "No checksum tool found — skipping verification"
    return 0
  fi
  if [[ "$actual" != "$expected" ]]; then
    err "Checksum mismatch for $(basename "$file")"
    err "  expected: $expected"
    err "  actual:   $actual"
    return 1
  fi
  info "Checksum verified for $(basename "$file")"
}

fetch_terraform_checksum() {
  local version="$1" zip_filename="$2"
  curl -fsSL "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_SHA256SUMS" \
    | grep "$zip_filename" | awk '{print $1}' || true
}

make_tempdir() { mktemp -d; }

# Runs tool's version command post-install to confirm it works
verify_tool() {
  local tool="$1" cmd="$2"
  shift 2
  local output
  if output="$("$cmd" "$@" 2>&1)"; then
    ok "Verified: $tool → $output"
  else
    err "Verification failed: '$cmd $*'"
    return 1
  fi
}

brew_install() {
  if ! command_exists brew; then
    err "Homebrew not installed. See https://brew.sh"
    return 1
  fi
  info "Installing $1 via Homebrew..."
  brew install "$1"
}

# ─── Version extractors ─────────────────────────────────

get_terraform_version() {
  terraform version -json 2>/dev/null \
    | grep '"terraform_version"' \
    | sed 's/.*: *"\([^"]*\)".*/\1/'
}

get_kubectl_version() {
  kubectl version --client -o json 2>/dev/null \
    | grep gitVersion | head -1 | tr -d ' ",' | cut -d: -f2
}

# ─── Terraform ───────────────────────────────────────────

install_terraform() {
  if command_exists terraform; then
    local current
    current="$(get_terraform_version || true)"
    if version_gte "$current" "$TERRAFORM_VERSION"; then
      ok "terraform $current already installed (>= $TERRAFORM_VERSION)"
      record_result terraform "ok ($current)"
      return
    fi
    warn "terraform $current found but >= $TERRAFORM_VERSION required"
    if $CHECK_ONLY; then
      record_result terraform "TOO OLD ($current)"
      return
    fi
  elif $CHECK_ONLY; then
    record_result terraform "MISSING"
    return
  fi

  local install_version
  install_version="$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | grep -o '"current_version":"[^"]*"' | cut -d'"' -f4)" || true
  if [[ -z "$install_version" ]]; then
    install_version="$TERRAFORM_VERSION"
    warn "Could not resolve latest terraform version, falling back to $TERRAFORM_VERSION"
  fi

  local os_name
  case "$OS" in
    darwin) os_name="darwin" ;;
    linux)  os_name="linux" ;;
  esac

  info "Installing terraform $install_version..."
  local zip_filename="terraform_${install_version}_${os_name}_${ARCH}.zip"
  local url="https://releases.hashicorp.com/terraform/${install_version}/${zip_filename}"
  local tmp
  tmp="$(make_tempdir)"
  trap "rm -rf '$tmp'" RETURN

  local expected_checksum
  expected_checksum="$(fetch_terraform_checksum "$install_version" "$zip_filename")"

  curl -fsSL "$url" -o "$tmp/terraform.zip"
  verify_checksum "$tmp/terraform.zip" "$expected_checksum"
  unzip -oq "$tmp/terraform.zip" -d "$tmp"
  mv "$tmp/terraform" "$LOCAL_BIN/terraform"
  chmod +x "$LOCAL_BIN/terraform"

  verify_tool terraform terraform version || { record_result terraform "FAILED (verify)"; return; }
  record_result terraform "installed ($install_version)"
}

# ─── AWS CLI v2 ──────────────────────────────────────────

install_awscli() {
  if command_exists aws; then
    ok "aws CLI already installed ($(aws --version 2>&1 | awk '{print $1}'))"
    record_result aws-cli "ok"
    return
  elif $CHECK_ONLY; then
    record_result aws-cli "MISSING"
    return
  fi

  info "Installing AWS CLI v2..."
  case "$OS" in
    darwin)
      brew_install awscli || { record_result aws-cli "FAILED"; return; }
      ;;
    linux)
      local tmp
      tmp="$(make_tempdir)"
      trap "rm -rf '$tmp'" RETURN
      local arch_suffix="x86_64"
      [[ "$ARCH" == "arm64" ]] && arch_suffix="aarch64"
      curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch_suffix}.zip" -o "$tmp/awscliv2.zip"
      unzip -oq "$tmp/awscliv2.zip" -d "$tmp"
      "$tmp/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$LOCAL_BIN" --update
      ;;
  esac

  verify_tool aws-cli aws --version || { record_result aws-cli "FAILED (verify)"; return; }
  record_result aws-cli "installed"
}

# ─── kubectl ─────────────────────────────────────────────

install_kubectl() {
  if command_exists kubectl; then
    local current
    current="$(get_kubectl_version || true)"
    if version_gte "${current#v}" "$KUBECTL_VERSION"; then
      ok "kubectl $current already installed (>= $KUBECTL_VERSION)"
      record_result kubectl "ok ($current)"
      return
    fi
    warn "kubectl $current found but >= $KUBECTL_VERSION required"
    if $CHECK_ONLY; then
      record_result kubectl "TOO OLD ($current)"
      return
    fi
  elif $CHECK_ONLY; then
    record_result kubectl "MISSING"
    return
  fi

  local install_version
  install_version="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" || true
  if [[ -z "$install_version" ]]; then
    install_version="v${KUBECTL_VERSION}"
    warn "Could not resolve latest kubectl version, falling back to $install_version"
  fi

  info "Installing kubectl ${install_version}..."
  local os_name
  case "$OS" in
    darwin) os_name="darwin" ;;
    linux)  os_name="linux" ;;
  esac

  local tmp
  tmp="$(make_tempdir)"
  trap "rm -rf '$tmp'" RETURN
  curl -fsSL "https://dl.k8s.io/release/${install_version}/bin/${os_name}/${ARCH}/kubectl" -o "$tmp/kubectl"
  local expected_checksum
  expected_checksum="$(curl -fsSL "https://dl.k8s.io/release/${install_version}/bin/${os_name}/${ARCH}/kubectl.sha256" || true)"
  if [[ -n "$expected_checksum" ]]; then
    verify_checksum "$tmp/kubectl" "$expected_checksum"
  fi
  mv "$tmp/kubectl" "$LOCAL_BIN/kubectl"
  chmod +x "$LOCAL_BIN/kubectl"

  verify_tool kubectl kubectl version --client || { record_result kubectl "FAILED (verify)"; return; }
  record_result kubectl "installed (${install_version})"
}

# ─── Helm ────────────────────────────────────────────────

install_helm() {
  if command_exists helm; then
    local current
    current="$(helm version --short 2>/dev/null | sed 's/+.*//')"
    if version_gte "${current#v}" "$HELM_VERSION"; then
      ok "helm $current already installed (>= $HELM_VERSION)"
      record_result helm "ok ($current)"
      return
    fi
    warn "helm $current found but >= $HELM_VERSION required"
    if $CHECK_ONLY; then
      record_result helm "TOO OLD ($current)"
      return
    fi
  elif $CHECK_ONLY; then
    record_result helm "MISSING"
    return
  fi

  local install_version
  install_version="$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest \
    | grep '"tag_name"' | head -1 | cut -d'"' -f4)" || true
  if [[ -z "$install_version" ]]; then
    install_version="v${HELM_VERSION}"
    warn "Could not resolve latest helm version, falling back to $install_version"
  fi

  info "Installing helm ${install_version}..."
  local os_name
  case "$OS" in
    darwin) os_name="darwin" ;;
    linux)  os_name="linux" ;;
  esac

  local tmp
  tmp="$(make_tempdir)"
  trap "rm -rf '$tmp'" RETURN
  local helm_url="https://get.helm.sh/helm-${install_version}-${os_name}-${ARCH}.tar.gz"
  local helm_checksum_url="${helm_url}.sha256sum"

  curl -fsSL "$helm_url" -o "$tmp/helm.tar.gz"
  local expected_checksum
  expected_checksum="$(curl -fsSL "$helm_checksum_url" 2>/dev/null | awk '{print $1}')" || true
  if [[ -n "$expected_checksum" ]]; then
    verify_checksum "$tmp/helm.tar.gz" "$expected_checksum"
  fi
  tar -xzf "$tmp/helm.tar.gz" -C "$tmp"
  mv "$tmp/${os_name}-${ARCH}/helm" "$LOCAL_BIN/helm"
  chmod +x "$LOCAL_BIN/helm"

  verify_tool helm helm version --short || { record_result helm "FAILED (verify)"; return; }
  record_result helm "installed (${install_version})"
}

# ─── jq ──────────────────────────────────────────────────

install_jq() {
  if command_exists jq; then
    ok "jq already installed ($(jq --version 2>/dev/null))"
    record_result jq "ok"
    return
  elif $CHECK_ONLY; then
    record_result jq "MISSING"
    return
  fi

  info "Installing jq..."
  case "$OS" in
    darwin)
      brew_install jq || { record_result jq "FAILED"; return; }
      ;;
    linux)
      local jq_arch="amd64"
      [[ "$ARCH" == "arm64" ]] && jq_arch="arm64"
      local jq_url
      jq_url="$(curl -fsSL https://api.github.com/repos/jqlang/jq/releases/latest \
        | grep "browser_download_url.*jq-linux-${jq_arch}\"" \
        | head -1 | cut -d'"' -f4)" || true
      if [[ -z "$jq_url" ]]; then
        err "Could not determine jq download URL from GitHub API"
        record_result jq "FAILED"
        return
      fi
      local tmp
      tmp="$(make_tempdir)"
      trap "rm -rf '$tmp'" RETURN
      curl -fsSL "$jq_url" -o "$tmp/jq"

      local sha_url="${jq_url}.sha256"
      local expected_checksum
      expected_checksum="$(curl -fsSL "$sha_url" 2>/dev/null | awk '{print $1}')" || true
      if [[ -n "$expected_checksum" ]]; then
        verify_checksum "$tmp/jq" "$expected_checksum"
      fi
      mv "$tmp/jq" "$LOCAL_BIN/jq"
      chmod +x "$LOCAL_BIN/jq"
      ;;
  esac

  verify_tool jq jq --version || { record_result jq "FAILED (verify)"; return; }
  record_result jq "installed"
}

# ─── git ─────────────────────────────────────────────────

install_git() {
  if command_exists git; then
    ok "git already installed ($(git --version 2>/dev/null))"
    record_result git "ok"
    return
  elif $CHECK_ONLY; then
    record_result git "MISSING"
    return
  fi

  info "Installing git..."
  case "$OS" in
    darwin)
      brew_install git || { record_result git "FAILED"; return; }
      ;;
    linux)
      if command_exists apt-get; then
        sudo apt-get update -qq && sudo apt-get install -yqq git
      elif command_exists dnf; then
        sudo dnf install -y git
      elif command_exists yum; then
        sudo yum install -y git
      else
        err "No supported package manager found for git installation"
        record_result git "FAILED"
        return
      fi
      ;;
  esac

  verify_tool git git --version || { record_result git "FAILED (verify)"; return; }
  record_result git "installed"
}

# ─── Summary ─────────────────────────────────────────────

print_summary() {
  local tools=(terraform aws-cli kubectl helm jq git)
  local has_failure=false
  local has_missing=false

  echo ""
  echo "============================================"
  if $CHECK_ONLY; then
    echo "  Readiness Check"
  else
    echo "  Installation Summary"
  fi
  echo "============================================"
  printf "  %-14s %s\n" "Tool" "Status"
  echo "  ------------  --------------------------"
  for tool in "${tools[@]}"; do
    local status
    status="$(get_result "$tool")"
    printf "  %-14s %s\n" "$tool" "$status"
    if [[ "$status" == FAILED* ]]; then
      has_failure=true
    fi
    if [[ "$status" == "MISSING" || "$status" == "TOO OLD"* ]]; then
      has_missing=true
    fi
  done
  echo "============================================"
  echo ""

  if $CHECK_ONLY; then
    if $has_missing; then
      warn "Some tools are missing or wrong version. Run without --check to install."
      exit 1
    else
      ok "All tools ready. You're good to go!"
    fi
  else
    if $has_failure; then
      warn "Some tools failed to install. Please check the errors above."
      exit 1
    else
      ok "All tools installed and verified."
    fi
  fi
}

# ─── Main ────────────────────────────────────────────────

main() {
  parse_args "$@"

  echo ""
  echo "============================================"
  echo "  AWS Community Day Romania 2026"
  echo "  Workshop Prerequisites Setup"
  if $CHECK_ONLY; then
    echo "  Mode: CHECK ONLY (no changes)"
  fi
  echo "============================================"
  echo ""

  detect_platform

  if ! $CHECK_ONLY; then
    check_prerequisites
    ensure_local_bin
  fi

  install_terraform
  install_awscli
  install_kubectl
  install_helm
  install_jq
  install_git

  print_summary
}

main "$@"