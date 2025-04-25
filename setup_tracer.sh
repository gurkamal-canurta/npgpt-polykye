#!/usr/bin/env bash
# Idempotent installer for TRACER (CPU) – pass --fresh to wipe /root/tracer first
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

###############################################################################
# 0) CLI flags & paths
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed previous /root/tracer"; }
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TMPDIR=/root/tmp
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=( [Transformer/ckpt_conditional.pth]=45039339 \
                  [Transformer/ckpt_unconditional.pth]=45039342 \
                  [GCN/GCN.pth]=45039345 )

mkdir -p "$INSTALL_DIR" "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"

###############################################################################
# 1) Detect or pick a Torch version
###############################################################################
torch_ver=$(python - <<'PY'
import importlib.util, re, sys
spec = importlib.util.find_spec("torch")
if spec is None: print("NONE")
else:
    import torch, re; print(re.match(r"\d+\.\d+\.\d+", torch.__version__).group(0))
PY
)
[[ $torch_ver == "NONE" ]] && { torch_ver="2.0.1" && NEED_TORCH=1; } || NEED_TORCH=0
log "using Torch $torch_ver (+cpu)"

###############################################################################
# 2) Create or reuse venv
###############################################################################
if [[ ! -d $VENV_DIR ]]; then
  python3 -m venv "$VENV_DIR"    # venv is idempotent by spec :contentReference[oaicite:6]{index=6}
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

# rdkit: pick build that matches this Python
python_minor=$(python - <<'PY'
import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")
PY
)
if python - <<'PY'; then import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("rdkit") else 1); fi; then
  log "rdkit already present"
else
  if [[ "$python_minor" == "3.12" ]]; then
    pip install -q rdkit==2024.3.5      # first wheel with 3.12 support :contentReference[oaicite:7]{index=7}
  else
    pip install -q rdkit # wheels for ≤3.11 still live here :contentReference[oaicite:8]{index=8}
  fi
fi

PYG_URL="https://pytorch-geometric.com/whl/torch-${torch_ver}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
              hydra-core omegaconf pandas scikit-learn tqdm requests

###############################################################################
# 4) Clone or update TRACER
###############################################################################
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only         # idempotent update :contentReference[oaicite:9]{index=9}
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src" \
      2>/dev/null || git -C "$INSTALL_DIR/src" pull --ff-only
fi
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 5) Download checkpoints if missing
###############################################################################
for relpath in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$relpath"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$relpath]}"; }
done

###############################################################################
# 6) Smoke-test (luteolin, 25 MCTS steps)
###############################################################################
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
       --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
       --mcts.num_steps 25

log "✅  TRACER ready – activate with:  source $VENV_DIR/bin/activate"
