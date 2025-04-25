#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;36m%s\e[0m\n' "$*"; }

###############################################################################
# 0) CLI flags & paths
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed previous /root/tracer"; }

INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TMPDIR=/root/tmp
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

mkdir -p "$INSTALL_DIR" "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"

###############################################################################
# 1) Detect or pick a Torch version
###############################################################################
torch_ver=$(python - <<'PY'
import importlib.util, re
spec = importlib.util.find_spec("torch")
if spec is None:
    print("NONE")
else:
    import torch, re
    print(re.match(r"\d+\.\d+\.\d+", torch.__version__).group(0))
PY
)
if [[ $torch_ver == "NONE" ]]; then
  torch_ver="2.0.1"
  NEED_TORCH=1
else
  NEED_TORCH=0
fi
log "using Torch $torch_ver (+cpu)"

###############################################################################
# 2) Create or reuse venv
###############################################################################
if [[ ! -d $VENV_DIR ]]; then
  python3 -m venv "$VENV_DIR"
  log "created venv in $VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel

###############################################################################
# 3) Core dependencies
###############################################################################
if (( NEED_TORCH )); then
  pip install -q torch=="$torch_ver"+cpu torchvision \
    --index-url https://download.pytorch.org/whl/cpu
fi

# ─── Does rdkit exist? ───────────────────────────────────────────────────────
if python - <<'PY'
import importlib.util, sys
sys.exit(0 if importlib.util.find_spec("rdkit") else 1)
PY
then
    log "rdkit already present"
else
    PY_MINOR=$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    if [[ $PY_MINOR == "3.12" ]]; then
        pip install -q rdkit==2024.3.5
    else
        pip install -q rdkit-pypi==2023.9.5
    fi
fi

PYG_URL="https://pytorch-geometric.com/whl/torch-${torch_ver}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
               hydra-core omegaconf pandas scikit-learn tqdm requests

###############################################################################
# 4) Clone or update TRACER
###############################################################################
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi
# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 5) Download checkpoints if missing
###############################################################################
for relpath in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$relpath"
  [[ -f $dst ]] && continue
  mkdir -p "$(dirname "$dst")"
  curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$relpath]}"
done

###############################################################################
# 6) Smoke-test (25-step MCTS)
###############################################################################
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25

###############################################################################
log "✅  TRACER ready – activate with:  source $VENV_DIR/bin/activate"
###############################################################################
