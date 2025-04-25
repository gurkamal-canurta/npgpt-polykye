#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup_npgpt_droplet.sh  —  one-shot bootstrap for a fresh Ubuntu droplet
#
# • Creates a 4 GB swapfile if none exists
# • Installs Python3 + core build tools
# • Clones or pulls this repo into /root/npgpt
# • Creates / upgrades a venv in that folder
# • Installs Python deps *incl. RDKit wheel*  (≈40 MB, fits fine)
# • Downloads Smiles-GPT checkpoints
# • Runs test_ligand_generation.py once
# • Leaves you in an interactive shell with the venv active
#
# Usage (on a new droplet):
#   curl -L https://raw.githubusercontent.com/your-user/your-repo/main/setup_npgpt_droplet.sh \
#        -o setup.sh && sudo bash setup.sh
###############################################################################

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
CHECKPOINT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"

echo "==> 1/8  Creating 4 GB swapfile if needed..."
if ! swapon --show | grep -q "/swapfile"; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
  echo "    swapfile created & enabled."
else
  echo "    swapfile already present."
fi

echo "==> 2/8  Updating APT & installing core packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip git curl

echo "==> 3/8  Cloning / updating repo into $INSTALL_DIR..."
if [[ -d "$INSTALL_DIR/.git" ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo "==> 4/8  Creating / upgrading virtual-env..."
python3 -m venv "$VENVDIR"
source "$VENVDIR/bin/activate"
pip install --upgrade --quiet pip setuptools wheel

echo "==> 5/8  Installing project & runtime deps  (includes RDKit wheel)..."
pip install --quiet --no-cache-dir rdkit==2024.9.6
pip install --quiet -r "$INSTALL_DIR/requirements.lock" 2>/dev/null || true   # if you use a lockfile
pip install --quiet "$INSTALL_DIR"

echo "==> 6/8  Downloading Smiles-GPT checkpoint folder..."
mkdir -p "$INSTALL_DIR/checkpoints/smiles-gpt"
python - <<PY
import gdown, pathlib, sys
url = "$CHECKPOINT_URL"
out = pathlib.Path("$INSTALL_DIR/checkpoints/smiles-gpt")
try:
    gdown.download_folder(url, quiet=True, use_cookies=False, output=str(out))
except Exception as e:
    print(f"[WARN] gdown: {e}", file=sys.stderr)
PY

echo "==> 7/8  Running test_ligand_generation.py ..."
python "$INSTALL_DIR/test_ligand_generation.py" || true

echo
echo "========================================"
echo "✅  NPGPT environment ready in $INSTALL_DIR"
echo "   (venv already active)"
echo "========================================"
exec bash --login   # stay in a login shell with venv active
