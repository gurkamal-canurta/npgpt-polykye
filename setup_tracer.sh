#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ─── 1. Optional clean start ────────────────────────────────────────────────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "wiped /root/tracer"; }

# ─── 2. Constants ────────────────────────────────────────────────────────────
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH_VER=2.3.0         # latest CPU wheel compatible with TRACER’s env.yml
CKPT_BASE="https://figshare.com/ndownloader/files"
declare -A CKPTS=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# ─── 3. Create & activate venv, install core deps────────────────────────────
[[ -d $VENV ]] || python3 -m venv "$VENV"
# shellcheck source=/dev/null
source "$VENV/bin/activate"

pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH_VER"+cpu torchvision \
    --index-url https://download.pytorch.org/whl/cpu
# Now install exactly what's in env.yml via pip:
pip install -q \
  rdkit onnxruntime pandas scipy diskcache biopython accelerate requests tqdm \
  datasets evaluate pillow huggingface-hub hydra-core omegaconf scikit-learn torch-geometric==2.3.0

log "Installed torch ${TORCH_VER}+cpu and TRACER dependencies"

# ─── 4. Clone or update TRACER ────────────────────────────────────────────────
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# ─── 5. Patch Python-3.12 dataclass defaults (mutable default_factory) ───────
python <<PY
from pathlib import Path
import re
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field(' not in txt:
    txt = txt.replace(
        'from dataclasses import dataclass',
        'from dataclasses import dataclass, field'
    )
txt = re.sub(
    r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
    r'\1: \2 = field(default_factory=\2)',
    txt
)
cfg.write_text(txt)
PY
log "Patched config.py for dataclass default_factory"

# ─── 6. Ensure TRACER path is in PYTHONPATH ───────────────────────────────────
# shellcheck source=/dev/null
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" || \
  echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ─── 7. Download pretrained checkpoints ───────────────────────────────────────
for rel in "${!CKPTS[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] && continue
  mkdir -p "$(dirname "$dst")"
  curl -Ls -o "$dst" "$CKPT_BASE/${CKPTS[$rel]}"
done

# ─── 8. Smoke-test from within src so data paths resolve ──────────────────────
log "Running MCTS smoke-test …"
pushd "$INSTALL/src" >/dev/null
python scripts/mcts.py \
  mcts.in_smiles_file="C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  mcts.n_step=25
popd >/dev/null

log "✅  TRACER installed & smoke-test passed – activate with:"
log "   source $VENV/bin/activate"
