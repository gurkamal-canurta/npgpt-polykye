#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;36m%s\e[0m\n' "$*"; }

###############################################################################
# 0) CLI flag & base paths
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
# 1) Create / activate venv FIRST
###############################################################################
if [[ ! -d $VENV_DIR ]]; then
  python3 -m venv "$VENV_DIR"
  log "created venv in $VENV_DIR"
fi
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"          # << venv is now active for the rest
pip install -qU pip setuptools wheel

###############################################################################
# 2) Torch inside venv (CPU build)
###############################################################################
TOUCH_TORCH=$(python - <<'PY'
import importlib.util, sys
sys.exit(0 if importlib.util.find_spec("torch") else 1)
PY) || true

if [[ $TOUCH_TORCH == "" ]]; then
  TORCH_VER="2.0.1"
  log "installing torch==$TORCH_VER+cpu in venv"
  pip install -q torch=="$TORCH_VER"+cpu torchvision \
      --index-url https://download.pytorch.org/whl/cpu
else
  TORCH_VER=$(python - <<'PY'
import torch, re, sys
print(re.match(r"\d+\.\d+\.\d+", torch.__version__).group(0))
PY
)
fi
log "Torch version in venv: $TORCH_VER +cpu"

###############################################################################
# 3) Other dependencies (all inside venv)
###############################################################################
python - <<'PY' || pip install -q rdkit        # install rdkit only if missing
import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("rdkit") else 1)
PY

PYG_URL="https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"
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

###############################################################################
# 5) Patch config for Python 3.12 dataclass rule
###############################################################################
python - <<'PY'
from pathlib import Path
import re, textwrap
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = re.sub(r'(\w+):\s+([A-Za-z_][\w]*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 6) Download checkpoints (skip if present)
###############################################################################
for rel in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $dst ]] && continue
  mkdir -p "$(dirname "$dst")"
  curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$rel]}"
done

###############################################################################
# 7) Smoke-test
###############################################################################
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
    --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
    --mcts.num_steps 25

log "✅  TRACER ready – activate with:  source $VENV_DIR/bin/activate"
