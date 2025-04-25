#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

REPO_URL="https://github.com/gurkamal-canurta/npgpt-polykye.git"
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
TMPDIR="/root/tmp"

NPGPT_SRC="$INSTALL_DIR/externals/npgpt"
SGPT_DIR="$NPGPT_SRC/externals/smiles-gpt"
ADD_PYTHONPATH="$NPGPT_SRC/src:$SGPT_DIR"

CKPT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
TOK_DEST="$SGPT_DIR/checkpoints/benchmark-10m"

###############################################################################
log "1/8  swapfile"
###############################################################################
swapon --show | grep -q '/swapfile' || {
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
}

###############################################################################
log "2/8  apt"
###############################################################################
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git curl build-essential git-lfs
git lfs install --skip-repo

###############################################################################
log "3/8  clone helper repo"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
log "4/8  venv + requirements"
###############################################################################
python3 -m venv "$VENVDIR" 2>/dev/null || true
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel
mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
log "5/8  vendor npgpt + smiles-gpt"
###############################################################################
mkdir -p "$(dirname "$NPGPT_SRC")"
if [[ -d $NPGPT_SRC/.git ]]; then
  git -C "$NPGPT_SRC" pull --ff-only
else
  git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"
fi
git -C "$NPGPT_SRC" submodule update --init --recursive
pip install --quiet --no-cache-dir -e "$NPGPT_SRC"

# PYTHONPATH once
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/8  checkpoints"
###############################################################################
python - <<PY
import pathlib, shutil, gdown, sys
ckpt = pathlib.Path("$CKPT_DIR"); ckpt.mkdir(parents=True, exist_ok=True)
tok  = pathlib.Path("$TOK_DEST"); tok.mkdir(parents=True, exist_ok=True)
if not any(ckpt.iterdir()):
    gdown.download_folder("$CKPT_URL", quiet=False, use_cookies=False, output=str(ckpt))
src, dst = ckpt/"tokenizer.json", tok/"tokenizer.json"
if src.exists(): shutil.copy2(src, dst)          # always overwrite to ensure good file
PY

###############################################################################
log "7/8  NPGPT smoke-test"
###############################################################################
cd "$INSTALL_DIR"
python test_ligand_generation.py || true

###############################################################################
# ──────────────────────────  PLAPT ADD-ON  ────────────────────────────
###############################################################################
log "9/8  install PLAPT + smoke-test (optional)"
###############################################################################
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_PLAPT="$INSTALL_DIR/requirements.plapt.txt"

# wheels file shipped in repo – falls back to minimal list if missing
if [[ ! -f $REQ_PLAPT ]]; then
  cat >"$REQ_PLAPT"<<'EOF'
pandas scipy onnxruntime diskcache biopython accelerate requests tqdm datasets evaluate pillow huggingface-hub
EOF
fi
pip install --quiet --no-cache-dir -r "$REQ_PLAPT"

mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  git clone https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi
git -C "$PLAPT_SRC" lfs pull               # downloads ONNX weights

python - <<'PY'
import os, sys, pathlib
os.environ.update({"ORT_LOG_LEVEL":"ERROR","ORT_MIN_LOG_LEVEL":"3"})
root = pathlib.Path("/root/npgpt")
plapt_dir = root/"externals"/"plapt"; sys.path.append(str(plapt_dir))
from plapt import Plapt
prot="MKTVRQERLKSIVRILERSKEPVSGAQLAEELSVSRQVIVQDIAYLRSLGYNIVATPRGYVLAGG"
smi ="CC1=CC=C(C=C1)C2=CC(=NN2C3=CC=C(C=C3)S(=O)(=O)N)C(F)(F)F"
try:
    out = Plapt().score_candidates(prot,[smi])[0]
    # accept whatever numeric field is present (affinity / pKd)
    val = next(v for v in out.values() if isinstance(v,(int,float)))
    print(f"\nPLAPT pKd prediction: {val:.3f}\n")
except Exception as e:
    print("[WARN] PLAPT smoke-test failed:", e)
PY

###############################################################################
log "8/8  ready (auto-venv)"
###############################################################################
grep -qxF "source $VENVDIR/bin/activate" /root/.bashrc || \
  echo "source $VENVDIR/bin/activate" >> /root/.bashrc
log "✅  Finished – both NPGPT and PLAPT ready. Re-run anytime."
exec bash --login
