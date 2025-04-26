#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ──────────────────────────────── wipe ────────────────────────────────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

# ───────────────────────────── constants ──────────────────────────────
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.3.0  # STABLE, compatible with torchtext 0.18.0
TORCHTEXT=0.18.0
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A W=([Transformer/ckpt_conditional.pth]=45039339
              [Transformer/ckpt_unconditional.pth]=45039342
              [GCN/GCN.pth]=45039345)

# ──────────────────────────── create venv ─────────────────────────────
[[ -d $VENV ]] || python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip install -qU pip setuptools wheel

# ──────────────────────────── install torch 2.3 + torchtext ───────────
pip install -q torch=="$TORCH"+cpu torchvision torchtext=="$TORCHTEXT" \
      --index-url https://download.pytorch.org/whl/cpu
pip install -q rdkit tqdm omegaconf hydra-core pandas scikit-learn requests
pip install -q torch-geometric==2.3.0 \
      -f "https://pytorch-geometric.com/whl/torch-${TORCH}+cpu.html"
log "torch ${TORCH}+cpu & torchtext ${TORCHTEXT} installed (officially compatible)"

# ──────────────────────────── clone/update TRACER ─────────────────────
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# ──────────────────────────── fix dataclass (Py3.12) ──────────────────
python - <<'PY'
from pathlib import Path
import re
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field(' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = re.sub(r'(\w+):\s+([A-Za-z_]+\w*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

# ──────────────────────────── PYTHONPATH ──────────────────────────────
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" || \
  echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ──────────────────────────── download weights ────────────────────────
for rel in "${!W[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${W[$rel]}"; }
done

# ──────────────────────────── smoke-test ──────────────────────────────
log "running MCTS smoke-test ..."
python "$INSTALL/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅ TRACER successfully installed & tested — activate with:"
log "   source $VENV/bin/activate"
