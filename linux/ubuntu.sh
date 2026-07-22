#!/usr/bin/env bash

# Interactive Ubuntu bootstrap for a headless dotfiles/LunarVim workstation.
#
# Run from this repository:
#   bash linux/ubuntu.sh
#
# Run directly from GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/rafael-alani/dotserver/main/linux/ubuntu.sh)

set -Eeuo pipefail

readonly DEFAULT_DOTFILES_REPO="git@github.com:rafael-alani/dotfiles.git"
readonly NVIM_VERSION="0.9.5"
readonly LUNARVIM_BRANCH="release-1.4/neovim-0.9"
readonly LV_INSTALLER_URL="https://raw.githubusercontent.com/LunarVim/LunarVim/${LUNARVIM_BRANCH}/utils/installer/install.sh"
readonly BOB_INSTALLER_URL="https://raw.githubusercontent.com/MordechaiHadad/bob/master/scripts/install.sh"
readonly CHEZMOI_INSTALLER_URL="https://get.chezmoi.io"
readonly STARSHIP_INSTALLER_URL="https://starship.rs/install.sh"
readonly GITHUB_CLI_KEY_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"

# Published at https://docs.github.com/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
readonly GITHUB_ED25519_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"

PRIVATE_KEY_TMP=""
PUBLIC_KEY_TMP=""
TTY_STATE=""
DOTFILES_REPO="${DOTFILES_REPO:-$DEFAULT_DOTFILES_REPO}"

info() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m✓\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m!\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [[ -n "$TTY_STATE" ]] && [[ -e /dev/tty ]]; then
    stty "$TTY_STATE" </dev/tty 2>/dev/null || true
  fi
  [[ -z "$PRIVATE_KEY_TMP" ]] || rm -f -- "$PRIVATE_KEY_TMP"
  [[ -z "$PUBLIC_KEY_TMP" ]] || rm -f -- "$PUBLIC_KEY_TMP"
}

on_error() {
  local exit_code=$?
  local line_number=$1
  printf '\n\033[1;31mBootstrap stopped at line %s (exit %s).\033[0m\n' "$line_number" "$exit_code" >&2
  exit "$exit_code"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'on_error "$LINENO"' ERR

confirm() {
  local question=$1
  local default_answer=${2:-yes}
  local hint answer

  if [[ "$default_answer" == "yes" ]]; then
    hint="Y/n"
  else
    hint="y/N"
  fi

  while true; do
    printf '%s [%s] ' "$question" "$hint" >&3
    IFS= read -r answer <&3 || return 1
    case "$answer" in
      y|Y|yes|YES|Yes) return 0 ;;
      n|N|no|NO|No) return 1 ;;
      "") [[ "$default_answer" == "yes" ]] && return 0 || return 1 ;;
      *) printf 'Please answer yes or no.\n' >&3 ;;
    esac
  done
}

prompt_with_default() {
  local question=$1
  local default_value=$2
  local answer

  printf '%s [%s]: ' "$question" "$default_value" >&3
  IFS= read -r answer <&3
  printf '%s' "${answer:-$default_value}"
}

require_supported_host() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer only supports Ubuntu Linux."
  [[ -r /etc/os-release ]] || die "Cannot identify this Linux distribution."

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer requires Ubuntu (detected: ${PRETTY_NAME:-unknown})."
  [[ "${EUID:-$(id -u)}" -ne 0 ]] || die "Run this as your normal user, not as root. The script uses sudo when needed."
  command -v sudo >/dev/null 2>&1 || die "sudo is required."
  [[ -r /dev/tty && -w /dev/tty ]] || die "An interactive terminal is required."
}

ensure_local_path_for_process() {
  mkdir -p "$HOME/.local/bin" "$HOME/.cargo/bin"
  export PATH="$HOME/.local/bin:$HOME/.local/share/bob/nvim-bin:$HOME/.cargo/bin:$PATH"
  hash -r
}

install_apt_prerequisites() {
  info "Installing Ubuntu and LunarVim prerequisites"
  sudo -v
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    build-essential \
    ca-certificates \
    cargo \
    cmake \
    curl \
    fd-find \
    file \
    fish \
    git \
    gnupg \
    jq \
    make \
    nodejs \
    npm \
    openssh-client \
    pkg-config \
    python-is-python3 \
    python3 \
    python3-dev \
    python3-pip \
    python3-pynvim \
    ripgrep \
    tar \
    tmux \
    unzip \
    xz-utils

  if command -v fdfind >/dev/null 2>&1; then
    ln -sfn "$(command -v fdfind)" "$HOME/.local/bin/fd"
  fi
}

install_github_cli() {
  local key_tmp key_fingerprint repo_tmp architecture

  info "Installing GitHub CLI from GitHub's official apt repository"
  key_tmp=$(mktemp)
  repo_tmp=$(mktemp)
  curl -fsSL "$GITHUB_CLI_KEY_URL" -o "$key_tmp"

  key_fingerprint=$(
    gpg --batch --show-keys --with-colons "$key_tmp" 2>/dev/null |
      awk -F: '$1 == "pub" { next_is_primary = 1; next } next_is_primary && $1 == "fpr" { print $10; exit }'
  )
  case "$key_fingerprint" in
    2C6106201985B60E6C7AC87323F3D4EA75716059|7F38BBB59D064DBCB3D84D725612B36462313325) ;;
    *)
      rm -f -- "$key_tmp" "$repo_tmp"
      die "GitHub CLI repository key has an unexpected fingerprint: ${key_fingerprint:-unknown}"
      ;;
  esac

  architecture=$(dpkg --print-architecture)
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' "$architecture" >"$repo_tmp"
  sudo install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
  sudo install -m 0644 "$key_tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
  sudo install -m 0644 "$repo_tmp" /etc/apt/sources.list.d/github-cli.list
  rm -f -- "$key_tmp" "$repo_tmp"

  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y gh
}

capture_private_key() {
  local line saw_begin=0 saw_end=0

  PRIVATE_KEY_TMP=$(mktemp "$HOME/.ssh/.github-private.XXXXXX")
  chmod 0600 "$PRIVATE_KEY_TMP"
  TTY_STATE=$(stty -g <&3)
  stty -echo <&3

  printf '\nPaste the complete private key now. Input is hidden and stops at the END line.\n' >&3
  while IFS= read -r line <&3; do
    line=${line%$'\r'}
    if (( saw_begin == 0 )); then
      [[ -z "$line" ]] && continue
      if [[ ! "$line" =~ ^-----BEGIN[[:space:]].*PRIVATE[[:space:]]KEY-----$ ]]; then
        stty "$TTY_STATE" <&3
        TTY_STATE=""
        die "The private key did not start with a recognized BEGIN PRIVATE KEY line."
      fi
      saw_begin=1
    fi

    printf '%s\n' "$line" >>"$PRIVATE_KEY_TMP"
    if [[ "$line" =~ ^-----END[[:space:]].*PRIVATE[[:space:]]KEY-----$ ]]; then
      saw_end=1
      break
    fi
  done

  stty "$TTY_STATE" <&3
  TTY_STATE=""
  printf '\nPrivate key received.\n' >&3
  (( saw_begin == 1 && saw_end == 1 )) || die "The private key was incomplete."
}

capture_public_key() {
  local supplied_public derived_public supplied_pair derived_pair

  printf 'Paste the one-line public key, or press Enter to derive it from the private key: ' >&3
  IFS= read -r supplied_public <&3
  supplied_public=${supplied_public%$'\r'}

  printf 'Validating the private key (an encrypted key may ask for its passphrase)...\n' >&3
  derived_public=$(ssh-keygen -y -f "$PRIVATE_KEY_TMP") || die "Could not read the private key."
  [[ -n "$derived_public" ]] || die "The private key produced no public key."

  if [[ -z "$supplied_public" ]]; then
    supplied_public=$derived_public
  fi

  PUBLIC_KEY_TMP=$(mktemp "$HOME/.ssh/.github-public.XXXXXX")
  printf '%s\n' "$supplied_public" >"$PUBLIC_KEY_TMP"
  chmod 0644 "$PUBLIC_KEY_TMP"
  ssh-keygen -l -f "$PUBLIC_KEY_TMP" >/dev/null || die "The supplied public key is not valid."

  supplied_pair=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$PUBLIC_KEY_TMP")
  derived_pair=$(printf '%s\n' "$derived_public" | awk 'NF >= 2 { print $1 " " $2; exit }')
  [[ "$supplied_pair" == "$derived_pair" ]] || die "The public key does not match the private key."
}

backup_if_present() {
  local path=$1
  local backup
  [[ -e "$path" ]] || return 0

  backup="${path}.before-dotserver.$(date +%Y%m%d%H%M%S)"
  while [[ -e "$backup" ]]; do
    backup="${backup}.1"
  done
  mv -- "$path" "$backup"
  warn "Backed up $path to $backup"
}

install_pasted_github_key() {
  local key_path="$HOME/.ssh/github"
  local public_path="$HOME/.ssh/github.pub"

  capture_private_key
  capture_public_key
  backup_if_present "$key_path"
  backup_if_present "$public_path"
  install -m 0600 "$PRIVATE_KEY_TMP" "$key_path"
  install -m 0644 "$PUBLIC_KEY_TMP" "$public_path"
  rm -f -- "$PRIVATE_KEY_TMP" "$PUBLIC_KEY_TMP"
  PRIVATE_KEY_TMP=""
  PUBLIC_KEY_TMP=""
  success "Installed matching GitHub keys as ~/.ssh/github and ~/.ssh/github.pub"
}

validate_existing_github_key() {
  local key_path="$HOME/.ssh/github"
  local public_path="$HOME/.ssh/github.pub"
  local derived_public existing_pair derived_pair

  chmod 0600 "$key_path"
  derived_public=$(ssh-keygen -y -f "$key_path") || die "Existing $key_path is not a readable private key."
  if [[ ! -s "$public_path" ]]; then
    printf '%s\n' "$derived_public" >"$public_path"
    chmod 0644 "$public_path"
    success "Derived the missing ~/.ssh/github.pub file"
    return
  fi

  ssh-keygen -l -f "$public_path" >/dev/null || die "Existing $public_path is not a valid public key."
  existing_pair=$(awk 'NF >= 2 { print $1 " " $2; exit }' "$public_path")
  derived_pair=$(printf '%s\n' "$derived_public" | awk 'NF >= 2 { print $1 " " $2; exit }')
  [[ "$existing_pair" == "$derived_pair" ]] || die "Existing github and github.pub keys do not match."
  chmod 0644 "$public_path"
  success "Existing GitHub private/public key pair is valid"
}

ensure_github_ssh_config() {
  local config_path="$HOME/.ssh/config"
  local filtered_tmp configured_tmp

  filtered_tmp=$(mktemp "$HOME/.ssh/.config-filtered.XXXXXX")
  configured_tmp=$(mktemp "$HOME/.ssh/.config-new.XXXXXX")

  if [[ -f "$config_path" ]]; then
    if grep -Fqx '# BEGIN dotserver github' "$config_path" && grep -Fqx '# END dotserver github' "$config_path"; then
      awk '
        $0 == "# BEGIN dotserver github" { skipping = 1; next }
        $0 == "# END dotserver github" { skipping = 0; next }
        !skipping { print }
      ' "$config_path" >"$filtered_tmp"
    else
      cat "$config_path" >"$filtered_tmp"
    fi
  fi

  {
    cat "$filtered_tmp"
    printf '%s\n' \
      '' \
      '# BEGIN dotserver github' \
      'Host github.com' \
      '  HostName github.com' \
      '  User git' \
      '  IdentityFile ~/.ssh/github' \
      '  IdentitiesOnly yes' \
      '# END dotserver github' \
      ''
  } >"$configured_tmp"

  install -m 0600 "$configured_tmp" "$config_path"
  rm -f -- "$filtered_tmp" "$configured_tmp"

  touch "$HOME/.ssh/known_hosts"
  chmod 0600 "$HOME/.ssh/known_hosts"
  if ! grep -Fqx "$GITHUB_ED25519_HOST_KEY" "$HOME/.ssh/known_hosts"; then
    printf '%s\n' "$GITHUB_ED25519_HOST_KEY" >>"$HOME/.ssh/known_hosts"
  fi
}

configure_github_ssh() {
  info "Configuring the GitHub SSH key"
  mkdir -p "$HOME/.ssh"
  chmod 0700 "$HOME/.ssh"

  if [[ -s "$HOME/.ssh/github" ]]; then
    if confirm "~/.ssh/github already exists. Replace the private/public pair?" no; then
      install_pasted_github_key
    else
      validate_existing_github_key
    fi
  else
    install_pasted_github_key
  fi

  ensure_github_ssh_config
  success "Configured SSH to use ~/.ssh/github for github.com"
}

install_chezmoi() {
  if command -v chezmoi >/dev/null 2>&1; then
    success "chezmoi is already installed"
    return
  fi

  info "Installing chezmoi into ~/.local/bin"
  sh -c "$(curl -fsLS "$CHEZMOI_INSTALLER_URL")" -- -b "$HOME/.local/bin"
  hash -r
  command -v chezmoi >/dev/null 2>&1 || die "chezmoi was installed but is not on PATH."
}

write_headless_toml_profile() {
  local config_path=$1
  local updated_tmp
  updated_tmp=$(mktemp)

  if [[ -f "$config_path" ]]; then
    awk '
      BEGIN { in_data = 0; wrote_profile = 0 }
      /^\[[^]]+\][[:space:]]*$/ {
        if (in_data && !wrote_profile) {
          print "profile = \"headless\""
          wrote_profile = 1
        }
        in_data = ($0 ~ /^\[data\][[:space:]]*$/)
      }
      in_data && /^[[:space:]]*profile[[:space:]]*=/ {
        if (!wrote_profile) {
          print "profile = \"headless\""
          wrote_profile = 1
        }
        next
      }
      { print }
      END {
        if (!wrote_profile) {
          if (!in_data) {
            print ""
            print "[data]"
          }
          print "profile = \"headless\""
        }
      }
    ' "$config_path" >"$updated_tmp"
    cp -p -- "$config_path" "${config_path}.before-dotserver.$(date +%Y%m%d%H%M%S)"
  else
    printf '[data]\nprofile = "headless"\n' >"$updated_tmp"
  fi

  install -m 0600 "$updated_tmp" "$config_path"
  rm -f -- "$updated_tmp"
}

ensure_headless_chezmoi_profile() {
  local config_dir="$HOME/.config/chezmoi"
  local candidate config_path current_profile
  local -a configs=()

  mkdir -p "$config_dir"
  for candidate in \
    "$config_dir/chezmoi.toml" \
    "$config_dir/chezmoi.json" \
    "$config_dir/chezmoi.jsonc" \
    "$config_dir/chezmoi.yaml" \
    "$config_dir/chezmoi.yml"; do
    [[ ! -e "$candidate" ]] || configs+=("$candidate")
  done

  (( ${#configs[@]} <= 1 )) || die "Multiple chezmoi config formats exist in $config_dir; keep only one and rerun."
  if (( ${#configs[@]} == 0 )); then
    config_path="$config_dir/chezmoi.toml"
    write_headless_toml_profile "$config_path"
    success "Created chezmoi.toml with profile=headless"
    return
  fi

  config_path=${configs[0]}
  current_profile=$(chezmoi execute-template '{{ .profile }}' 2>/dev/null || true)
  if [[ "$current_profile" == "headless" ]]; then
    success "chezmoi already uses the headless profile"
    return
  fi

  [[ "$config_path" == *.toml ]] || die "The existing chezmoi config is not TOML and its profile is not headless: $config_path"
  if ! confirm "Existing chezmoi profile is '${current_profile:-unset}'. Change it to 'headless'?" yes; then
    die "The headless chezmoi profile is required for this bootstrap."
  fi
  write_headless_toml_profile "$config_path"
  success "Set chezmoi profile=headless"
}

apply_dotfiles() {
  info "Initializing and applying the headless chezmoi profile"
  if [[ -s "$HOME/.ssh/github" ]]; then
    GIT_SSH_COMMAND="ssh -i $HOME/.ssh/github -o IdentitiesOnly=yes" \
      chezmoi init --apply --verbose "$DOTFILES_REPO"
  else
    chezmoi init --apply --verbose "$DOTFILES_REPO"
  fi

  local applied_profile
  applied_profile=$(chezmoi execute-template '{{ .profile }}' 2>/dev/null || true)
  [[ "$applied_profile" == "headless" ]] || die "chezmoi applied, but .profile resolved to '${applied_profile:-unset}' instead of 'headless'."

  # A managed SSH config may have replaced the bootstrap block during apply.
  if [[ -s "$HOME/.ssh/github" ]]; then
    ensure_github_ssh_config
  fi
  success "Applied $DOTFILES_REPO with profile=headless"
}

configure_npm_prefix() {
  info "Configuring user-local npm installs (avoids global EACCES errors)"
  npm config set prefix "$HOME/.local"
  npm install --global neovim tree-sitter-cli
}

install_bob_and_neovim() {
  if ! command -v bob >/dev/null 2>&1; then
    info "Installing Bob, the Neovim version manager"
    curl -fsSL "$BOB_INSTALLER_URL" | bash
    ensure_local_path_for_process
  else
    success "Bob is already installed"
  fi

  command -v bob >/dev/null 2>&1 || die "Bob was installed but is not on PATH."
  info "Installing and selecting Neovim $NVIM_VERSION through Bob"
  bob use "$NVIM_VERSION"
  hash -r

  command -v nvim >/dev/null 2>&1 || die "Bob did not expose the nvim executable."
  nvim --version | sed -n '1p' | grep -F "NVIM v$NVIM_VERSION" >/dev/null ||
    die "Expected Neovim $NVIM_VERSION, but nvim reports: $(nvim --version | sed -n '1p')"
  success "Neovim $NVIM_VERSION is active through Bob"
}

install_lazygit() {
  local version architecture archive_tmp extract_dir

  if command -v lazygit >/dev/null 2>&1; then
    success "lazygit is already installed"
    return
  fi

  info "Installing the latest lazygit release"
  version=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazygit/releases/latest | jq -er '.tag_name | ltrimstr("v")')
  case "$(uname -m)" in
    x86_64|amd64) architecture="x86_64" ;;
    aarch64|arm64) architecture="arm64" ;;
    *) die "lazygit's automatic installer does not support architecture $(uname -m)." ;;
  esac

  archive_tmp=$(mktemp)
  extract_dir=$(mktemp -d)
  curl -fL "https://github.com/jesseduffield/lazygit/releases/download/v${version}/lazygit_${version}_Linux_${architecture}.tar.gz" -o "$archive_tmp"
  tar -xzf "$archive_tmp" -C "$extract_dir" lazygit
  install -m 0755 "$extract_dir/lazygit" "$HOME/.local/bin/lazygit"
  rm -f -- "$archive_tmp" "$extract_dir/lazygit"
  rmdir "$extract_dir"
  success "Installed lazygit $version"
}

install_starship() {
  if command -v starship >/dev/null 2>&1; then
    success "Starship is already installed"
    return
  fi

  info "Installing Starship into ~/.local/bin"
  curl -fsSL "$STARSHIP_INSTALLER_URL" | sh -s -- --yes --bin-dir "$HOME/.local/bin"
  hash -r
  command -v starship >/dev/null 2>&1 || die "Starship was installed but is not on PATH."
}

install_lunarvim() {
  if command -v lvim >/dev/null 2>&1; then
    if ! confirm "LunarVim is already installed. Reinstall release 1.4 for Neovim 0.9?" no; then
      success "Keeping the existing LunarVim installation"
      return
    fi
  fi

  info "Installing LunarVim $LUNARVIM_BRANCH"
  # Dependencies were installed explicitly above. Avoid LunarVim's pip --user
  # path, which is rejected by newer Ubuntu/Python externally-managed installs.
  curl -fsSL "$LV_INSTALLER_URL" | env LV_BRANCH="$LUNARVIM_BRANCH" bash -s -- --yes --no-install-dependencies
  hash -r
  command -v lvim >/dev/null 2>&1 || die "LunarVim was installed but lvim is not on PATH."
  success "LunarVim is installed"
}

persist_user_paths() {
  local profile_path="$HOME/.profile"
  local profile_tmp fish_path_file

  info "Persisting local tool paths"
  profile_tmp=$(mktemp)
  if [[ -f "$profile_path" ]]; then
    if grep -Fqx '# BEGIN dotserver local path' "$profile_path" && grep -Fqx '# END dotserver local path' "$profile_path"; then
      awk '
        $0 == "# BEGIN dotserver local path" { skipping = 1; next }
        $0 == "# END dotserver local path" { skipping = 0; next }
        !skipping { print }
      ' "$profile_path" >"$profile_tmp"
    else
      cat "$profile_path" >"$profile_tmp"
    fi
  fi
  {
    cat "$profile_tmp"
    printf '%s\n' \
      '' \
      '# BEGIN dotserver local path' \
      'export PATH="$HOME/.local/bin:$HOME/.local/share/bob/nvim-bin:$HOME/.cargo/bin:$PATH"' \
      '# END dotserver local path'
  } >"${profile_tmp}.new"
  install -m 0644 "${profile_tmp}.new" "$profile_path"
  rm -f -- "$profile_tmp" "${profile_tmp}.new"

  mkdir -p "$HOME/.config/fish/conf.d"
  fish_path_file="$HOME/.config/fish/conf.d/00-dotserver-path.fish"
  printf '%s\n' \
    '# Managed by dotserver/linux/ubuntu.sh' \
    'fish_add_path --global --move $HOME/.local/bin $HOME/.local/share/bob/nvim-bin $HOME/.cargo/bin' \
    >"$fish_path_file"
  chmod 0644 "$fish_path_file"
}

configure_ssh_tmux() {
  local tmux_hook="$HOME/.config/fish/conf.d/10-dotserver-ssh-tmux.fish"

  info "Configuring automatic tmux attachment for SSH logins"
  mkdir -p "$HOME/.config/fish/conf.d"
  printf '%s\n' \
    '# Managed by dotserver/linux/ubuntu.sh' \
    '# Attach to the persistent main session only for interactive SSH shells.' \
    'if status is-interactive; and set -q SSH_TTY; and not set -q TMUX' \
    '    exec tmux new-session -A -s main' \
    'end' \
    >"$tmux_hook"
  chmod 0644 "$tmux_hook"
  success "Interactive SSH logins will attach to tmux session 'main'"
}

set_fish_as_default_shell() {
  local fish_path current_shell current_user
  fish_path=$(command -v fish)
  current_user=$(id -un)
  current_shell=$(getent passwd "$current_user" | cut -d: -f7)

  if ! grep -Fqx "$fish_path" /etc/shells; then
    printf '%s\n' "$fish_path" | sudo tee -a /etc/shells >/dev/null
  fi

  if [[ "$current_shell" != "$fish_path" ]]; then
    info "Setting Fish as the default login shell"
    sudo chsh -s "$fish_path" "$current_user"
  else
    success "Fish is already the default shell"
  fi
}

print_summary() {
  local profile
  profile=$(chezmoi execute-template '{{ .profile }}' 2>/dev/null || printf 'unknown')

  info "Bootstrap complete"
  printf '  %-12s %s\n' "chezmoi" "$(chezmoi --version | sed -n '1p')"
  printf '  %-12s %s\n' "profile" "$profile"
  printf '  %-12s %s\n' "bob" "$(bob --version | sed -n '1p')"
  printf '  %-12s %s\n' "neovim" "$(nvim --version | sed -n '1p')"
  printf '  %-12s %s\n' "lunarvim" "$(lvim --version 2>&1 | sed -n '1p')"
  printf '  %-12s %s\n' "lazygit" "$(lazygit --version | sed -n '1p')"
  printf '  %-12s %s\n' "starship" "$(starship --version | sed -n '1p')"
  printf '  %-12s %s\n' "tmux" "$(tmux -V)"
  printf '  %-12s %s\n' "shell" "$(command -v fish)"
  printf '\nOn the next SSH login, Fish will attach to tmux session main automatically.\n'
  printf 'Detach and preserve it with Ctrl-b followed by d, or simply disconnect.\n'
}

main() {
  exec 3<>/dev/tty
  require_supported_host
  umask 077
  ensure_local_path_for_process

  printf '\nUbuntu headless workstation bootstrap\n'
  printf 'This installs system build tools, GitHub CLI, chezmoi, Bob + Neovim %s,\n' "$NVIM_VERSION"
  printf 'LunarVim release 1.4, lazygit, Starship, Fish, and persistent tmux SSH sessions.\n\n'

  DOTFILES_REPO=$(prompt_with_default "Chezmoi dotfiles repository" "$DOTFILES_REPO")
  if ! confirm "Continue with installation?" yes; then
    printf 'Cancelled.\n'
    return 0
  fi

  install_apt_prerequisites
  ensure_local_path_for_process
  install_github_cli

  if confirm "Configure the private/public ~/.ssh/github key pair now?" yes; then
    configure_github_ssh
  else
    warn "Skipping GitHub key setup; the private dotfiles clone must authenticate some other way."
  fi

  install_chezmoi
  ensure_headless_chezmoi_profile
  configure_npm_prefix
  install_bob_and_neovim
  install_lazygit
  install_starship
  apply_dotfiles
  ensure_local_path_for_process
  install_lunarvim
  persist_user_paths
  configure_ssh_tmux
  set_fish_as_default_shell
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
