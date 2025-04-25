#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR="/root/tmp"

# ── NPGPT paths ─────────────────────────────────────────────────────
NPGPT_SRC="$INSTALL_DIR/externals/npgpt"
SGPT_DIR="$NPGPT_SRC/externals/smiles-gpt"
PUBLIC_SGPT_LINK="$INSTALL_DIR/externals/smiles-gpt"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
TOK_DEST="$SGPT_DIR/checkpoints/benchmark-10m/tokenizer.json"

# ── PLAPT paths ─────────────────────────────────────────────────────
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_PLAPT="$INSTALL_DIR/requirements.plapt.txt"

ADD_PYTHONPATH="$NPGPT_SRC/src:$SGPT_DIR:$PLAPT_SRC"

###############################################################################
log "1/9  swapfile (idempotent)"
###############################################################################
swapon --show | grep -q '/swapfile' || {
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
}

###############################################################################
log "2/9  apt + git-lfs"
###############################################################################
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git git-lfs curl build-essential
git lfs install --skip-repo

###############################################################################
log "3/9  clone / update helper repo"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
log "4/9  venv + runtime wheels"
###############################################################################
python3 -m venv "$VENVDIR" 2>/dev/null || true
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel
mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
log "5/9  vendor NPGPT (+Smiles-GPT) & ensure tokenizer"
###############################################################################
mkdir -p "$(dirname "$NPGPT_SRC")"
if [[ -d $NPGPT_SRC/.git ]]; then git -C "$NPGPT_SRC" pull --ff-only
else git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"; fi
git -C "$NPGPT_SRC" submodule update --init --recursive
pip install --quiet --no-cache-dir -e "$NPGPT_SRC"

# symlink public path once
[[ -e $PUBLIC_SGPT_LINK ]] || ln -s "$SGPT_DIR" "$PUBLIC_SGPT_LINK"

# copy tokenizer unconditionally if source exists
SRC_TOK="$CKPT_DIR/tokenizer.json"
if [[ -f $SRC_TOK ]]; then
  install -m 644 "$SRC_TOK" "$TOK_DEST"
fi

# add pythonpath
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/9  checkpoints download (only if missing)"
###############################################################################
python - <<PY
import pathlib, gdown, shutil, sys, os
ckpt = pathlib.Path("$CKPT_DIR"); ckpt.mkdir(parents=True, exist_ok=True)
if not any(ckpt.iterdir()):
    gdown.download_folder(
        "https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy",
        quiet=False, use_cookies=False, output=str(ckpt))
dst = pathlib.Path("$TOK_DEST"); dst.parent.mkdir(parents=True, exist_ok=True)
src = ckpt / "tokenizer.json"
if src.exists(): shutil.copy2(src, dst)
PY

###############################################################################
log "7/9  NPGPT smoke-test"
###############################################################################
if [[ ! -f $TOK_DEST ]]; then
  echo "❌ tokenizer.json still missing – aborting NPGPT test" >&2
else
  python "$INSTALL_DIR/test_ligand_generation.py" || true
fi

###############################################################################
log "8/9  install PLAPT & quiet smoke-test"
###############################################################################
# wheels
if [[ ! -f $REQ_PLAPT ]]; then
  curl -fsSL \
  https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/requirements.plapt.txt \
  -o "$REQ_PLAPT"
fi
pip install --quiet --no-cache-dir -r "$REQ_PLAPT"

# source + weights
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then git -C "$PLAPT_SRC" pull --ff-only
else git clone https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"; fi
git -C "$PLAPT_SRC" lfs pull

# smoke-test
python - <<'PY'
import os, sys, pathlib, warnings
os.environ["ORT_LOG_LEVEL"] = "ERROR"           # silence onnxruntime
root = pathlib.Path("/root/npgpt")
plapt_dir = root / "externals" / "plapt"
sys.path.append(str(plapt_dir)); os.chdir(plapt_dir)

from plapt import Plapt
prot = "MKTVRQERLKSIVRILERSKEPVSGAQLAEELSVSRQVIVQDIAYLRSLGYNIVATPRGYVLAGG"
smi  = "CC1=CC=C(C=C1)C2=CC(=NN2C3=CC=C(C=C3)S(=O)(=O)N)C(F)(F)F"
try:
    res = Plapt().score_candidates(prot, [smi])[0]   # returns dict
    print(f"\nPLAPT pKd prediction: {res['affinity']:.3f}\n")
except Exception as e:
    print("[WARN] PLAPT test failed:", e)
PY

###############################################################################
log "9/9  ready – venv auto-activates"
###############################################################################
grep -qxF "source $VENVDIR/bin/activate" /root/.bashrc || \
 echo "source $VENVDIR/bin/activate" >> /root/.bashrc
exec bash --login
