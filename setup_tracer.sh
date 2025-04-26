#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# 1) Optional clean slate
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "wiped /root/tracer"; }

# 2) Constants
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.3.0                    # CPU wheel compatible with TRACER’s env.yml :contentReference[oaicite:4]{index=4}
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPTS=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# 3) Create & activate venv
[[ -d $VENV ]] || python3 -m venv "$VENV"           # venv is the standard tool for isolated envs :contentReference[oaicite:5]{index=5}
# shellcheck source=/dev/null
source "$VENV/bin/activate"

# 4) Install PyTorch + Hydra-Core (includes OmegaConf), and other deps
pip install -qU pip setuptools wheel              # upgrade installer tools
pip install -q \
     torch=="$TORCH"+cpu torchvision hydra-core   \
     --index-url https://download.pytorch.org/whl/cpu  # Hydra-Core brings in OmegaConf automatically :contentReference[oaicite:6]{index=6}
pip install -q \
     rdkit onnxruntime pandas scipy diskcache biopython accelerate requests tqdm \
     datasets evaluate pillow huggingface-hub scikit-learn torch-geometric==2.3.0

log "Installed torch ${TORCH}+cpu, Hydra-Core (with OmegaConf), and TRACER pip deps"

# 5) Clone or update TRACER
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# 6) Patch Python-3.12 dataclass defaults (mutable default_factory)
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
log "Patched config.py for default_factory (Python 3.12)"

# 7) Ensure TRACER path is available
# shellcheck source=/dev/null
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" \
  || echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# 8) Download pretrained checkpoints
for rel in "${!CKPTS[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] || {
    mkdir -p "$(dirname "$dst")"
    curl -Ls -o "$dst" "$CKPT_URL/${CKPTS[$rel]}"
  }
done

# 9) Run MCTS smoke-test via Hydra overrides
log "Running MCTS smoke-test …"
pushd "$INSTALL/src" >/dev/null
python scripts/mcts.py \
  mcts.in_smiles_file="C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  mcts.n_step=25
popd >/dev/null

log "✅ TRACER successfully installed & smoke-test passed"
log "Activate your environment with: source $VENV/bin/activate"
