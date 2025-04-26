#!/usr/bin/env bash
set -euo pipefail

log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ─────────── Wipe if requested ───────────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

# ─────────── Constants ───────────
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TORCH_VER=2.3.0
TORCHTEXT_VER=0.18.0
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CHECKPOINTS=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# ─────────── 1. Create & activate venv, install deps ───────────
[[ -d $VENV_DIR ]] || python3 -m venv "$VENV_DIR"
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"

pip install -qU pip setuptools wheel
pip install -q \
  torch=="$TORCH_VER"+cpu torchvision torchtext=="$TORCHTEXT_VER" \
    --index-url https://download.pytorch.org/whl/cpu
pip install -q rdkit tqdm omegaconf hydra-core pandas scikit-learn requests
pip install -q torch-geometric==2.3.0 \
    -f "https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"

log "Installed torch ${TORCH_VER}+cpu, torchtext ${TORCHTEXT_VER}, and other deps"

# ─────────── 2. Clone or update TRACER ───────────
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

# ─────────── 3. Patch config.py for Python 3.12 dataclass defaults ───────────
python <<PY
from pathlib import Path
import re

cfg_path = Path("/root/tracer/src/config/config.py")
txt = cfg_path.read_text()
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
cfg_path.write_text(txt)
PY
log "Patched config.py for dataclass default_factory"

# ─────────── 4. Patch out torchtext imports in code ───────────
python <<PY
from pathlib import Path
import re, textwrap

stub = textwrap.dedent("""
# patched fallback for torchtext.vocab.vocab
from types import SimpleNamespace as _SN
def _mk(counter=None, specials=()):
    stoi, idx = {}, 0
    for tok in specials or []:
        if tok not in stoi:
            stoi[tok] = idx; idx += 1
    if counter:
        for tok in counter:
            if tok not in stoi:
                stoi[tok] = idx; idx += 1
    return _SN(stoi=stoi, itos=list(stoi))

Vocab = _SN(make_vocab=_mk)
vocab = _mk
""").strip()

files = [
  "/root/tracer/src/Model/Transformer/model.py",
  "/root/tracer/src/scripts/preprocess.py",
  "/root/tracer/src/scripts/beam_search.py"
]

for filepath in files:
    path = Path(filepath)
    content = path.read_text()
    if "torchtext" in content:
        patched = re.sub(
            r'^\s*.*torchtext[^\n]*$',
            stub,
            content,
            flags=re.M
        )
        path.write_text(patched)
PY
log "Replaced torchtext imports with pure-Python stub in model.py, preprocess.py, beam_search.py"

# ─────────── 5. Ensure TRACER’s set_up.sh is sourced in the venv ───────────
# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" \
  || echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

# ─────────── 6. Download pretrained checkpoints ───────────
for relpath in "${!CHECKPOINTS[@]}"; do
  dst="/root/tracer/src/ckpts/$relpath"
  [[ -f $dst ]] && continue
  mkdir -p "$(dirname "$dst")"
  curl -Ls -o "$dst" "$CKPT_URL/${CHECKPOINTS[$relpath]}"
done

# ─────────── 7. Smoke-test (run from src so ./data is correct) ───────────
log "Running MCTS smoke-test …"
pushd "/root/tracer/src" >/dev/null
python scripts/mcts.py \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
popd >/dev/null

log "✅ TRACER installation and smoke-test complete"
log "Activate your environment with: source $VENV_DIR/bin/activate"
