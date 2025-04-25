#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# setup_npgpt_droplet.sh
#   - Installs system Python3 + venv support
#   - Clones/updates NPGPT under /root/npgpt
#   - Builds or reuses a Python venv there
#   - Installs project dependencies and gdown
#   - Fetches Smiles-GPT checkpoints
# Usage:
#   chmod +x setup_npgpt_droplet.sh
#   sudo bash setup_npgpt_droplet.sh
# -----------------------------------------------------------------------------

# 1) Normalize line endings
sed -i 's/\r$//' "$0"

# 2) System packages (idempotent)
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  python3 python3-venv python3-pip \
  sqlite3 git curl

# 3) Clone or update the NPGPT repository under /root/npgpt
PROJECT_DIR="/root/npgpt"
if [ -d "$PROJECT_DIR" ]; then
  cd "$PROJECT_DIR"
  git pull origin main
else
  git clone https://github.com/ohuelab/npgpt.git "$PROJECT_DIR"
  cd "$PROJECT_DIR"
fi

# 4) Prepare disk-backed temp & pip cache
tmp_dir="/root/tmp"
cache_dir="$tmp_dir/pip-cache"
mkdir -p "$tmp_dir" "$cache_dir"
export TMPDIR="$tmp_dir"
export PIP_CACHE_DIR="$cache_dir"

# 5) Create & activate a Python venv (includes pip, setuptools, wheel)
python3 -m venv .venv
source .venv/bin/activate

# 6) Upgrade core packaging tools
pip install --upgrade pip setuptools wheel

# 7) Install project dependencies and gdown for model download
pip install .
pip install --no-cache-dir gdown

# 8) Fetch the Smiles-GPT checkpoint folder
checkpoint_url="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
mkdir -p checkpoints/smiles-gpt
gdown --folder "$checkpoint_url" -O checkpoints/smiles-gpt

# 9) Completion message
echo ""
echo "========================================"
echo "✅ NPGPT setup complete under $PROJECT_DIR"
echo "Next steps:"
echo "  source $PROJECT_DIR/.venv/bin/activate"
echo "========================================"
