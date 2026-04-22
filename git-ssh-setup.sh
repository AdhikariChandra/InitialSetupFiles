#!/bin/bash
# ==============================
# Git + SSH Setup Script
# Fedora Workstation
# ==============================

set -euo pipefail

# -------- Usage function --------
usage() {
  echo "Usage: $0 --email <email> --name <username> [--repo <repo_ssh_url>] [--yes]"
  echo
  echo "Options:"
  echo "  --email   Your Git/GitHub email address (required)"
  echo "  --name    Your Git username (required)"
  echo "  --repo    SSH URL of a repo to clone or pull (optional, e.g. git@github.com:user/repo.git)"
  echo "  --yes     Auto-accept all install prompts (non-interactive mode)"
  echo
  echo "Example:"
  echo "  $0 --email you@example.com --name \"Your Name\" --repo git@github.com:user/repo.git"
  echo
  exit 1
}

# -------- Helper: prompt or auto-accept --------
confirm() {
  local prompt="$1"
  if [[ "$auto_yes" == true ]]; then
    echo "${prompt} [auto-yes]"
    return 0
  fi
  read -rp "${prompt} (y/n): " answer
  [[ "${answer:-n}" =~ ^[Yy]$ ]]
}

# -------- Parse arguments --------
email=""
username=""
repo_url=""
auto_yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "❌ --email requires a value."
        exit 1
      fi
      email="$2"
      shift 2
      ;;
    --name)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "❌ --name requires a value."
        exit 1
      fi
      username="$2"
      shift 2
      ;;
    --repo)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "❌ --repo requires a value."
        exit 1
      fi
      repo_url="$2"
      shift 2
      ;;
    --yes)
      auto_yes=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "❌ Unknown argument: $1"
      usage
      ;;
  esac
done

# -------- Validate required args --------
if [ -z "$email" ] || [ -z "$username" ]; then
  echo "❌ Missing required arguments."
  usage
fi

# Email validation
regex='^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'
if [[ ! "$email" =~ $regex ]]; then
  echo "❌ Invalid email format: $email"
  exit 1
fi

# SSH URL validation — must be validated before use in Step 8
if [ -n "$repo_url" ]; then
  # Strip trailing slash before any checks
  repo_url="${repo_url%/}"
  if [[ ! "$repo_url" =~ ^git@ ]]; then
    echo "❌ --repo must be an SSH URL (e.g. git@github.com:user/repo.git)"
    exit 1
  fi
fi

echo "🔧 Setting up Git and SSH on Fedora..."

# -------- Pre-flight: check sudo access --------
if ! sudo -n true 2>/dev/null; then
  echo "⚠️  This script may need sudo for package installation (git, xclip)."
  echo "   If prompted and you lack sudo rights, package installs will fail."
fi

# ------------------------------
# STEP 1: Check Git installation
# ------------------------------
if command -v git >/dev/null 2>&1; then
    echo "✅ Git is already installed: $(git --version)"
else
    if confirm "Git is not installed. Install it now?"; then
        echo "📦 Installing Git via dnf..."
        sudo dnf install -y git
        echo "✅ Git installed: $(git --version)"
    else
        echo "❌ Git is required. Exiting."
        exit 1
    fi
fi

# ------------------------------
# STEP 2: Check ssh-keygen
# ------------------------------
command -v ssh-keygen >/dev/null 2>&1 || {
    echo "❌ ssh-keygen not found. Install it with: sudo dnf install -y openssh-clients"
    exit 1
}
echo "✅ ssh-keygen is available."

# ------------------------------
# STEP 3: Configure Git
# ------------------------------
git config --global user.name "$username"  || { echo "❌ Failed to set git user.name";  exit 1; }
git config --global user.email "$email"    || { echo "❌ Failed to set git user.email"; exit 1; }
echo "✅ Git global config set (name: $username, email: $email)"

# ------------------------------
# STEP 4: SSH Key setup
# ------------------------------
SSH_KEY="$HOME/.ssh/id_ed25519"
AGENT_ENV="$HOME/.ssh/agent.env"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [ ! -f "$SSH_KEY" ]; then
    echo "🔑 No SSH key found. Generating ed25519 key..."
    ssh-keygen -t ed25519 -C "$email" -f "$SSH_KEY"
    echo "✅ SSH key generated at $SSH_KEY"
else
    echo "✅ SSH key already exists at $SSH_KEY"
fi

# Enforce correct permissions — SSH silently rejects keys that are too permissive
chmod 600 "$SSH_KEY"
chmod 644 "${SSH_KEY}.pub"
echo "✅ SSH key permissions verified (600/644)."

# ------------------------------
# STEP 5: Start ssh-agent
# ------------------------------
# Write agent env vars to a file and source it so SSH_AUTH_SOCK/SSH_AGENT_PID
# are available both in this script and can be reloaded by the user later.
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
    echo "🔄 Starting ssh-agent..."
    eval "$(ssh-agent -s)" > "$AGENT_ENV"
    chmod 600 "$AGENT_ENV"
    source "$AGENT_ENV"
    echo "✅ ssh-agent started."
    echo "   To reuse this agent in other terminals, run: source $AGENT_ENV"
    echo "   To load it automatically, add to ~/.bashrc: [ -f $AGENT_ENV ] && source $AGENT_ENV"
else
    echo "✅ ssh-agent is already running (PID: ${SSH_AGENT_PID:-unknown})."
fi

# Only add key if not already loaded — compare by fingerprint, not path.
# ssh-add -l outputs fingerprints (e.g. SHA256:abc...), never file paths.
# Guard the ssh-add -l call with || true so set -e doesn't abort when the
# agent is empty (exit 1) or unreachable (exit 2).
echo "🔑 Checking if SSH key is already loaded in agent..."
key_fingerprint=$(ssh-keygen -lf "${SSH_KEY}.pub" | awk '{print $2}')
if { ssh-add -l 2>/dev/null || true; } | grep -q "$key_fingerprint"; then
    echo "✅ SSH key already loaded in agent. Skipping."
else
    ssh-add "$SSH_KEY" || { echo "❌ Failed to add SSH key to agent. Check your passphrase."; exit 1; }
    echo "✅ SSH key added to agent."
fi

# ------------------------------
# STEP 6: Copy public key
# ------------------------------
echo
echo "📋 Your public SSH key:"
echo "------------------------------------------------------------"
cat "${SSH_KEY}.pub"
echo "------------------------------------------------------------"

# xclip requires both the binary and an active X display — fails silently in headless/SSH sessions
if command -v xclip >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    xclip -selection clipboard < "${SSH_KEY}.pub"
    echo "✅ SSH public key copied to clipboard via xclip."
elif ! command -v xclip >/dev/null 2>&1; then
    if confirm "xclip not found. Install it for clipboard support?"; then
        sudo dnf install -y xclip
        if [ -n "${DISPLAY:-}" ]; then
            xclip -selection clipboard < "${SSH_KEY}.pub"
            echo "✅ SSH public key copied to clipboard via xclip."
        else
            echo "⚠️  xclip installed but no DISPLAY detected (headless session). Copy the key above manually."
        fi
    else
        echo "⚠️  Skipping clipboard copy. Please copy the key above manually."
    fi
else
    echo "⚠️  No DISPLAY detected (headless/SSH session). Clipboard copy skipped."
    echo "   Copy the key above manually or use: cat ${SSH_KEY}.pub"
fi

echo
echo "👉 Add the key to GitHub: https://github.com/settings/keys"

if [[ "$auto_yes" == false ]]; then
    read -rp "Press ENTER after you've added your SSH key to GitHub..."
fi

# ------------------------------
# STEP 7: Test SSH connection
# ------------------------------
echo "🔍 Testing SSH connection to GitHub..."

# GitHub always returns exit code 1 even on a successful auth handshake —
# capture stderr+stdout and inspect the message instead of relying on exit code.
ssh_output=$(ssh -T git@github.com 2>&1) || true

if echo "$ssh_output" | grep -qi "authenticated"; then
    echo "✅ SSH connection to GitHub successful!"
    echo "   $ssh_output"
else
    echo "❌ SSH connection to GitHub failed."
    echo "   Response: $ssh_output"
    echo "   Troubleshooting tips:"
    echo "   - Make sure you added the correct public key to GitHub"
    echo "   - Run: ssh -vT git@github.com  for verbose debug output"
    exit 1
fi

# ------------------------------
# STEP 8: Repo setup (optional)
# ------------------------------
if [ -n "$repo_url" ]; then
    # Strip .git suffix using parameter expansion (handles missing .git and
    # trailing slashes already stripped above), then extract the final path component
    repo_name=$(basename "${repo_url%.git}")

    if [ -z "$repo_name" ]; then
        echo "❌ Could not determine repo name from URL: $repo_url"
        exit 1
    fi

    if [ -d "$repo_name" ]; then
        echo "📂 Directory '$repo_name' already exists. Fetching latest changes..."
        cd "$repo_name" || { echo "❌ Failed to cd into $repo_name"; exit 1; }
        # Use fetch + status rather than pull --ff-only to avoid aborting on
        # diverged branches. Let the user decide how to reconcile.
        git fetch origin
        git status
        echo
        echo "ℹ️  Run 'git pull', 'git rebase', or 'git merge' to integrate remote changes."
    else
        echo "⬇️  Cloning $repo_url ..."
        git clone "$repo_url" || { echo "❌ git clone failed."; exit 1; }
        cd "$repo_name" || { echo "❌ Failed to cd into $repo_name"; exit 1; }
    fi

    echo
    echo "📁 Repo is at: $(pwd)"
    ls -lah
    echo
    # cd only affects this subshell — remind the user to navigate themselves
    echo "ℹ️  Note: run 'cd $repo_name' in your terminal to navigate into the repo."
else
    echo "ℹ️  No --repo provided. Skipping clone step."
fi

echo
echo "🎉 Setup complete! Git and SSH are ready to use."
