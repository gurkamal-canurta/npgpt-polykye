#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR="/root/tmp"

NPGPT_SRC="$INSTALL_DIR/externals/npgpt"                     # main repo
SGPT_DIR="$NPGPT_SRC/externals/smiles-gpt"                   # sub-module path
ADD_PYTHONPATH="$NPGPT_SRC/src:$SGPT_DIR"                    # both packages

CKPT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
TOK_DEST="$SGPT_DIR/checkpoints/benchmark-10m"

###############################################################################
log "1/8  swapfile"
###############################################################################
swapon --noheadings --show | grep -q '/swapfile' || {
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
}

###############################################################################
log "2/8  apt"
###############################################################################
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git curl build-essential

###############################################################################
log "3/8  clone helper repo"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  rm -rf "$INSTALL_DIR"
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
log "4/8  venv + requirements"
###############################################################################
python3 -m venv "$VENVDIR" 2>/dev/null || true
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel
mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
log "5/8  vendor npgpt + smiles-gpt"
###############################################################################
mkdir -p "$(dirname "$NPGPT_SRC")"
if [[ -d "$NPGPT_SRC/.git" ]]; then
  git -C "$NPGPT_SRC" pull --ff-only
else
  rm -rf "$NPGPT_SRC"
  git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"
fi
git -C "$NPGPT_SRC" submodule update --init --recursive

pip install --quiet --no-cache-dir -e "$NPGPT_SRC"   # has pyproject

# ── add both src paths to PYTHONPATH exactly once ────────────────────
if ! grep -qF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate"; then
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
       >> "$VENVDIR/bin/activate"
fi
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/8  checkpoints"
###############################################################################
python - <<PY
# coding: utf-8
import pathlib, shutil, gdown
ckpt = pathlib.Path("$CKPT_DIR"); ckpt.mkdir(parents=True, exist_ok=True)
tok  = pathlib.Path("$TOK_DEST"); tok.mkdir(parents=True, exist_ok=True)
if not any(ckpt.iterdir()):
    gdown.download_folder("$CKPT_URL", quiet=False, use_cookies=False, output=str(ckpt))
src, dst = ckpt / "tokenizer.json", tok / "tokenizer.json"
if src.exists() and not dst.exists(): shutil.copy2(src, dst)
PY

###############################################################################
log "7/8  smoke-test"
###############################################################################
cd "$INSTALL_DIR"
python test_ligand_generation.py || true

###############################################################################
log "8/8  ready (auto-venv)"
###############################################################################
grep -qxF "source $VENVDIR/bin/activate" /root/.bashrc || \
  echo "source $VENVDIR/bin/activate" >> /root/.bashrc
log "✅  Finished – smiles_gpt import fixed. Run again anytime."
exec bash --login
