#!/usr/bin/env bash
set -euo pipefail

log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR="/root/tmp"

NPGPT_SRC="$INSTALL_DIR/externals/npgpt"
PY_PATH_LINE='export PYTHONPATH="/root/npgpt/externals:$PYTHONPATH"'

CKPT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
TOK_DEST="$INSTALL_DIR/externals/smiles-gpt/checkpoints/benchmark-10m"

###############################################################################
log "1/8  swapfile  (idempotent)"
###############################################################################
if ! swapon --noheadings --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
fi

###############################################################################
log "2/8  apt  (idempotent)"
###############################################################################
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git curl build-essential

###############################################################################
log "3/8  clone helper repo  (update if exists)"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
log "4/8  venv + requirements.runtime.txt  (refresh safely)"
###############################################################################
python3 -m venv "$VENVDIR" 2>/dev/null || true   # creates if missing
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel

mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"

pip install --upgrade --quiet --no-cache-dir \
  -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
log "5/8  vendor npgpt source  (update or clone)"
###############################################################################
mkdir -p "$(dirname "$NPGPT_SRC")"
if [[ -d $NPGPT_SRC/.git ]]; then
  git -C "$NPGPT_SRC" pull --ff-only
else
  git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"
fi

# ensure PYTHONPATH line is present exactly once
grep -qxF "$PY_PATH_LINE" "$VENVDIR/bin/activate" || \
  echo "$PY_PATH_LINE" >> "$VENVDIR/bin/activate"
eval "$PY_PATH_LINE"   # apply to current shell

###############################################################################
log "6/8  checkpoints  (download only once)"
###############################################################################
python - <<PY
# coding: utf-8
import pathlib, shutil, gdown, sys, os
ckpt = pathlib.Path("$CKPT_DIR"); ckpt.mkdir(parents=True, exist_ok=True)
tok  = pathlib.Path("$TOK_DEST"); tok.mkdir(parents=True, exist_ok=True)

if not any(ckpt.iterdir()):
    gdown.download_folder("$CKPT_URL", quiet=False, use_cookies=False,
                          output=str(ckpt))

src, dst = ckpt / "tokenizer.json", tok / "tokenizer.json"
if src.exists() and not dst.exists():
    shutil.copy2(src, dst)
PY

###############################################################################
log "7/8  smoke-test (safe to re-run)"
###############################################################################
cd "$INSTALL_DIR"
python - <<'PY'
import importlib, sys, traceback, pathlib, json, rdkit
try:
    from test_ligand_generation import main as test_main
    test_main()
except Exception:
    traceback.print_exc()
    sys.exit(1)
PY

###############################################################################
log "8/8  ready – venv auto-activates on login"
###############################################################################
grep -qxF "source $VENVDIR/bin/activate" /root/.bashrc || \
  echo "source $VENVDIR/bin/activate" >> /root/.bashrc

log "✅  All done – you are now in (.venv)"
exec bash --login
