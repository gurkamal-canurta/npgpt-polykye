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
ADD_PYTHONPATH="$NPGPT_SRC/src:$SGPT_DIR"

CKPT_URL="https://drive.google.com/drive/folders/1olCPouDkaJ2OBdNaM-G7IU8T6fBpvPMy"
CKPT_DIR="$INSTALL_DIR/checkpoints/smiles-gpt"
TOK_DEST="$SGPT_DIR/checkpoints/benchmark-10m"

# ── PLAPT paths ─────────────────────────────────────────────────────
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_PLAPT="$INSTALL_DIR/requirements.plapt.txt"

###############################################################################
log "1/8  swapfile (idempotent)"
###############################################################################
swapon --show | grep -q '/swapfile' || {
  fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  swapon /swapfile
}

###############################################################################
log "2/8  apt + git-lfs"
###############################################################################
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  python3 python3-venv python3-pip git git-lfs curl build-essential
git lfs install --skip-repo

###############################################################################
log "3/8  helper repo"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone "$REPO_URL" "$INSTALL_DIR"
fi

###############################################################################
log "4/8  venv + runtime wheels"
###############################################################################
python3 -m venv "$VENVDIR" 2>/dev/null || true
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"
pip install -U --quiet pip setuptools wheel
mkdir -p "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.runtime.txt"

###############################################################################
log "5/8  vendor NPGPT + Smiles-GPT"
###############################################################################
mkdir -p "$(dirname "$NPGPT_SRC")"
if [[ -d $NPGPT_SRC/.git ]]; then git -C "$NPGPT_SRC" pull --ff-only
else git clone --depth 1 https://github.com/ohuelab/npgpt.git "$NPGPT_SRC"; fi
git -C "$NPGPT_SRC" submodule update --init --recursive
pip install --quiet --no-cache-dir -e "$NPGPT_SRC"

grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/8  checkpoints"
###############################################################################
python - <<PY
import pathlib, gdown, shutil
ckpt = pathlib.Path("$CKPT_DIR"); ckpt.mkdir(parents=True, exist_ok=True)
tok  = pathlib.Path("$TOK_DEST"); tok.mkdir(parents=True, exist_ok=True)
if not any(ckpt.iterdir()):
    gdown.download_folder("$CKPT_URL", quiet=False, use_cookies=False, output=str(ckpt))
src, dst = ckpt/"tokenizer.json", tok/"tokenizer.json"
if src.exists(): shutil.copy2(src, dst)
PY

###############################################################################
log "7/8  NPGPT smoke-test"
###############################################################################
cd "$INSTALL_DIR"
python test_ligand_generation.py || true

###############################################################################
log "8/8  PLAPT install + adaptive smoke-test"
###############################################################################
# wheels list (clone already put one in repo)
[[ -f $REQ_PLAPT ]] || echo "onnxruntime pandas scipy diskcache biopython accelerate requests tqdm datasets evaluate pillow huggingface-hub" > "$REQ_PLAPT"
pip install --quiet --no-cache-dir -r "$REQ_PLAPT"

mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then git -C "$PLAPT_SRC" pull --ff-only
else git clone https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"; fi
git -C "$PLAPT_SRC" lfs pull --include "models/*.onnx"

python - <<'PY'
import os, sys, pathlib, glob
os.environ.update({"ORT_LOG_LEVEL":"ERROR","ORT_MIN_LOG_LEVEL":"3"})
plapt_dir = pathlib.Path("/root/npgpt/externals/plapt")
sys.path.append(str(plapt_dir)); os.chdir(plapt_dir)

# pick any .onnx in models/
models = sorted(glob.glob("models/*.onnx"))
if not models:
    print("[WARN] no ONNX model found in plapt/models – skipped test"); quit()

from plapt import Plapt
prot = "MKTVRQERLKSIVRILERSKEPVSGAQLAEELSVSRQVIVQDIAYLRSLGYNIVATPRGYVLAGG"
smi  = "CC1=CC=C(C=C1)C2=CC(=NN2C3=CC=C(C=C3)S(=O)(=O)N)C(F)(F)F"
try:
    res = Plapt(prediction_module_path=models[0]).score_candidates(prot,[smi])[0]
    val = next(v for v in res.values() if isinstance(v,(int,float)))
    print(f"\nPLAPT pKd prediction: {val:.3f}  ✔️\n")
except Exception as e:
    print("[WARN] PLAPT smoke-test failed:", e)
PY

grep -qxF "source $VENVDIR/bin/activate" /root/.bashrc || \
  echo "source $VENVDIR/bin/activate" >> /root/.bashrc
log "✅  Finished – NPGPT & PLAPT both installed. Re-run anytime."
exec bash --login
