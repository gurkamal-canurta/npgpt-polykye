#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup_npgpt_droplet.sh   —  Option B edition (no packaging, use PYTHONPATH)
# - Creates 4 GB swapfile   (one-time, persistent)
# - Installs Python3 + build tools
# - Clones *your* wrapper repo   → /root/npgpt
# - Clones upstream library      → /root/npgpt/upstream   (ohuelab/npgpt)
# - Builds / upgrades a venv and installs:
#       • rdkit wheel            • upstream library
#       • any requirements.lock you ship (optional)
# - Adds /root/npgpt to PYTHONPATH instead of pip-installing it
# - Downloads Smiles-GPT checkpoints
# - Runs test_ligand_generation.py once
# - Drops you in an interactive shell with venv active
###############################################################################

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
UPSTREAM_URL="https://github.com/ohuelab/npgpt.git"

INSTALL_DIR="/root/npgpt"           # your repo
UPSTREAM_DIR="$INSTALL_DIR/upstream" # actual library
VENVDIR="$INSTALL_DIR/.venv"

CHECKPOINT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"

echo "==> 1/8  Creating 4 GB swapfile if needed..."
if ! swapon --show | grep -q "/swapfile"; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap   /swapfile
  swapon   /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "    swapfile created & enabled."
else
  echo "    swapfile already present."
fi

echo "==> 2/8  Updating APT & installing core packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip git curl build-essential

echo "==> 3/8  Cloning / updating wrapper repo..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
fi

echo "==> 4/8  Creating / upgrading virtual-env..."
python3 -m venv "$VENVDIR"
source "$VENVDIR/bin/activate"
pip install --upgrade --quiet pip setuptools wheel

echo "==> 5/8  Installing runtime deps (incl. RDKit wheel)…"
pip install --quiet --no-cache-dir rdkit==2024.9.6
# optional lock-file from your repo
pip install --quiet -r "$INSTALL_DIR/requirements.lock" 2>/dev/null || true

# ──► Option B tweak: expose wrapper repo via PYTHONPATH instead of pip install
export PYTHONPATH="$INSTALL_DIR:${PYTHONPATH:-}"
echo "    Added $INSTALL_DIR to PYTHONPATH."

echo "==> 5b/8  Fetching & installing upstream NPGPT library…"
if [[ -d "$UPSTREAM_DIR/.git" ]]; then
  git -C "$UPSTREAM_DIR" pull --ff-only
else
  git clone --depth 1 "$UPSTREAM_URL" "$UPSTREAM_DIR"
fi
pip install --quiet "$UPSTREAM_DIR"

echo "==> 6/8  Downloading Smiles-GPT checkpoints…"
mkdir -p "$INSTALL_DIR/checkpoints/smiles-gpt"
python - <<PY
import gdown, pathlib, sys, textwrap
url  = "$CHECKPOINT_URL"
dest = pathlib.Path("$INSTALL_DIR/checkpoints/smiles-gpt")
try:
    gdown.download_folder(url, quiet=True, use_cookies=False, output=str(dest))
except Exception as e:
    print("[WARN] gdown:", e, file=sys.stderr)
PY

echo "==> 7/8  Running test_ligand_generation.py …"
python "$INSTALL_DIR/test_ligand_generation.py" || true

echo
echo "========================================"
echo "✅  NPGPT environment ready in $INSTALL_DIR"
echo "   (virtual-env active; wrapper repo on PYTHONPATH)"
echo "========================================"
exec bash --login
