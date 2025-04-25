#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR="/root/tmp"

CKPT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
NPGPT_SRC="$INSTALL_DIR/externals/npgpt"
TOK_DEST="$INSTALL_DIR/externals/smiles-gpt/checkpoints/benchmark-10m"

###############################################################################
# 1. swapfile
###############################################################################
echo "==> 1/8  swapfile"
swapon --show | grep -q '/swapfile' || {
  fallocate -l 4G /swapfile
  chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
}

###############################################################################
# 2. APT
###############################################################################
echo "==> 2/8  apt"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git curl build-essential

###############################################################################
# 3. clone helper repo
###############################################################################
echo "==> 3/8  git clone"
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
# 4. venv + requirements
###############################################################################
echo "==> 4/8  venv + pip"
python3 -m venv "$VENVDIR"
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel
mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
# 5. vendor npgpt source, patch activate script
###############################################################################
echo "==> 5/8  vendoring npgpt"
mkdir -p "$(dirname "$NPGPT_SRC")"
git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"
echo 'export PYTHONPATH="/root/npgpt/externals:$PYTHONPATH"' \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="/root/npgpt/externals:$PYTHONPATH"

###############################################################################
# 6. checkpoint + tokenizer
###############################################################################
echo "==> 6/8  checkpoints"
mkdir -p "$CKPT_DIR" "$TOK_DEST"
python - <<'PY'
# coding: utf-8
import pathlib, shutil, gdown, sys
ckpt = pathlib.Path("/root/npgpt/checkpoints/smiles-gpt")
tok  = pathlib.Path("/root/npgpt/externals/smiles-gpt/checkpoints/benchmark-10m")
url  = "https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
ckpt.mkdir(parents=True, exist_ok=True)
tok.mkdir(parents=True, exist_ok=True)

if not any(ckpt.iterdir()):
    gdown.download_folder(url, quiet=False, use_cookies=False, output=str(ckpt))

src, dst = ckpt / "tokenizer.json", tok / "tokenizer.json"
if src.exists() and not dst.exists():
    shutil.copy2(src, dst)
PY

###############################################################################
# 7. smoke-test
###############################################################################
echo "==> 7/8  smoke-test"
cd "$INSTALL_DIR"
python test_ligand_generation.py || {
  echo -e "\n[ERROR] Smoke-test failed – see above.\n"
}

###############################################################################
# 8. ready
###############################################################################
grep -qF "source $VENVDIR/bin/activate" /root/.bashrc || \
  echo "source $VENVDIR/bin/activate" >> /root/.bashrc
echo -e "\n✅  Setup complete – venv auto-activates on login."
exec bash --login
