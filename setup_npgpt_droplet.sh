#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# setup_npgpt_droplet.sh
#
# • Creates a 4 GB swapfile (if none exists)
# • Installs Python3 + pip + build tools
# • Clones/pulls your repo into /root/npgpt
# • Creates a venv in /root/npgpt/.venv (re-creates if corrupt)
# • All pip temp & cache traffic goes to /root/tmp   ← avoids /tmp 512 MB limit
# • Installs rdkit wheel + requirements.lock (if present)
# • Downloads Smiles-GPT checkpoints
# • Activates the venv and leaves you at a login shell
#
# Usage, on a brand-new droplet:
#   curl -L https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/setup_npgpt_droplet.sh \
#        -o setup.sh
#   sudo bash setup.sh
###############################################################################

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR_ON_DISK="/root/tmp"          # pip / wheel build temp lives here
CHECKPOINT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
CHECKPOINT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"

echo "==> 1/7  Ensure 4 GB swapfile ..."
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap   /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon   /swapfile
  echo "    swapfile created and activated."
else
  echo "    swapfile already present."
fi

echo "==> 2/7  Install core APT packages ..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive \
apt-get install -y --no-install-recommends \
    python3 python3-venv python3-pip git curl build-essential

echo "==> 3/7  Clone / pull repo into $INSTALL_DIR ..."
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

echo "==> 4/7  Create / refresh virtual-env ..."
python3 -m venv "$VENVDIR"
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"
pip install --upgrade --quiet pip setuptools wheel

# All pip temp files & caches go on the root disk, not /tmp (tmpfs).
mkdir -p "$TMPDIR_ON_DISK" "$TMPDIR_ON_DISK/pip-cache"
export TMPDIR="$TMPDIR_ON_DISK"
export PIP_CACHE_DIR="$TMPDIR_ON_DISK/pip-cache"

echo "==> 5/7  Install runtime Python deps ..."
# rdkit wheel (≈35 MB) – much lighter than compiling
pip install --quiet --no-cache-dir rdkit==2024.9.6

# If you keep a requirements.lock, use it – silent if absent
if [[ -f $INSTALL_DIR/requirements.lock ]]; then
    pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.lock"
fi

# (No attempt to pip-install the repo itself; it’s just scripts.)

echo "==> 6/7  Download Smiles-GPT checkpoints (first run only) ..."
mkdir -p "$CHECKPOINT_DIR"
python - <<PY
import pathlib, gdown, sys, os, json
url = "$CHECKPOINT_URL"
out = pathlib.Path("$CHECKPOINT_DIR")
if not any(out.iterdir()):
    try:
        gdown.download_folder(url, quiet=False, use_cookies=False, output=str(out))
    except Exception as e:
        print("[WARN] checkpoint download failed:", e, file=sys.stderr)
else:
    print("    checkpoints already present.")
PY

echo "==> 7/7  Done.  Dropping into shell with venv active ..."
echo
echo "========================================"
echo "✅  Environment ready  (venv: $VENVDIR)"
echo "   Try:  python test_ligand_generation.py"
echo "========================================"
exec bash --login
