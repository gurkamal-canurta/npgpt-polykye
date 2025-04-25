#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

###############################################################################
# Optional wipe
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

###############################################################################
# Paths & constants
###############################################################################
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TORCH_VER=2.4.1                     # CPU wheel
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345 )

mkdir -p "$INSTALL_DIR"
mkdir -p /root/tmp/pip-cache
export TMPDIR=/root/tmp PIP_CACHE_DIR=/root/tmp/pip-cache

###############################################################################
# 1. venv – everything happens inside it
###############################################################################
[[ -d $VENV_DIR ]] || python3 -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel

###############################################################################
# 2. Core wheels (Torch, RDKit, PyG, utilities) – inside venv
###############################################################################
pip install -q torch=="$TORCH_VER"+cpu torchvision \
    --index-url https://download.pytorch.org/whl/cpu
pip install -q rdkit
PYG_URL="https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
               hydra-core omegaconf pandas scikit-learn tqdm requests
pip install -q torchtext==0.18.0 --no-deps               # ← NEW line
log "torch ${TORCH_VER}+cpu, torchtext 0.18.0 and all deps installed"

###############################################################################
# 3. Clone / update TRACER repo
###############################################################################
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

###############################################################################
# 4. Patch Python-3.12 dataclass (mutable default) in config.py
###############################################################################
python - <<'PY'
from pathlib import Path, re
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field(' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = re.sub(r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

###############################################################################
# 5. Add TRACER to PYTHONPATH automatically in future shells
###############################################################################
# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 6. Download pretrained checkpoints if missing
###############################################################################
for rel in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$rel]}"; }
done

###############################################################################
# 7. Smoke-test
###############################################################################
log "running MCTS smoke-test …"
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅  TRACER installed and smoke-test completed – activate with:"
log "   source $VENV_DIR/bin/activate"
