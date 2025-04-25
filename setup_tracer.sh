#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

###############################################################################
# wipe if --fresh
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

###############################################################################
# paths & constants
###############################################################################
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TORCH_VER=2.4.1                       # cpu wheel
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345 )

###############################################################################
# 1‒2  create & activate venv, install core deps
###############################################################################
[[ -d $VENV_DIR ]] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH_VER"+cpu torchvision --index-url https://download.pytorch.org/whl/cpu
pip install -q rdkit hydra-core omegaconf pandas scikit-learn tqdm requests
# PyG needs a wheel matching torch cpu build
pip install -q torch-geometric==2.3.0 \
  -f "https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"

###############################################################################
# 3  clone / update TRACER
###############################################################################
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

###############################################################################
# 4  patch Python-3.12 dataclass rule in config.py
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
# 5  **hard-patch model.py to drop torchtext**
###############################################################################
python - <<'PY'
from pathlib import Path, re, textwrap
mdl = Path("/root/tracer/src/Model/Transformer/model.py")
src = mdl.read_text()
pattern = r'^\s*import\s+torchtext\.vocab\.vocab\s+as\s+Vocab\s*$'
if re.search(pattern, src, flags=re.M):
    replacement = textwrap.dedent("""
        # patched: torchtext removed for PyTorch ≥2.4 / Python 3.12
        from types import SimpleNamespace
        def _make_vocab(counter=None, specials=()):
            stoi = {}
            for tok in specials or []:
                stoi.setdefault(tok, len(stoi))
            if counter:
                for tok in counter:
                    stoi.setdefault(tok, len(stoi))
            itos = list(stoi)
            return SimpleNamespace(stoi=stoi, itos=itos)
        Vocab = SimpleNamespace(make_vocab=_make_vocab)
    """).strip()
    src = re.sub(pattern, replacement, src, flags=re.M, count=1)
    mdl.write_text(src)
PY
log "torchtext import replaced with lightweight fallback in model.py"

###############################################################################
# 6  add TRACER to PYTHONPATH for future shells
###############################################################################
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 7  download pretrained checkpoints if missing
###############################################################################
for rel in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$rel]}"; }
done

###############################################################################
# 8  run smoke-test
###############################################################################
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25

log "✅  TRACER installed and smoke-test completed.  Source the venv with:"
log "   source $VENV_DIR/bin/activate"
