#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TMPDIR=/root/tmp
TORCH_VER=2.4.1          # keep the CPU wheel you’re using
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345 )

mkdir -p "$INSTALL_DIR" "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"

# ───────── 1. venv  ──────────────────────────────────────────────────────────
[[ -d $VENV_DIR ]] || { python3 -m venv "$VENV_DIR"; }
source "$VENV_DIR/bin/activate"                              # ensure active
pip install -qU pip setuptools wheel

# ───────── 2. torch & deps inside venv  ──────────────────────────────────────
pip install -q torch=="$TORCH_VER"+cpu torchvision \
  --index-url https://download.pytorch.org/whl/cpu         # torch 2.4 CPU
pip install -q rdkit
PYG_URL="https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
               hydra-core omegaconf pandas scikit-learn tqdm requests
log "torch ${TORCH_VER}+cpu and all deps installed"

# ───────── 3. clone / update TRACER  ─────────────────────────────────────────
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

# ───────── 4. patch Python-3.12 dataclass rule  ──────────────────────────────
python - <<'PY'
from pathlib import Path, re as _r
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = _r.sub(r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

# ───────── 5. **NEW** sitecustomize stub for torchtext  ──────────────────────
python - <<'PY'
import site, pathlib, textwrap
code = """
import sys, types
def _vocab(counter=None, specials=()):
    stoi = {}
    for tok in specials or []:
        stoi.setdefault(tok, len(stoi))
    if counter:
        for tok in counter:
            stoi.setdefault(tok, len(stoi))
    itos = list(stoi)
    return types.SimpleNamespace(stoi=stoi, itos=itos)

_mod_vocab = types.ModuleType('torchtext.vocab.vocab')
_mod_vocab.make_vocab = _vocab
_mod_tv = types.ModuleType('torchtext.vocab'); _mod_tv.vocab = _mod_vocab
_mod_tt = types.ModuleType('torchtext'); _mod_tt.vocab = _mod_tv
sys.modules.update({'torchtext': _mod_tt,
                    'torchtext.vocab': _mod_tv,
                    'torchtext.vocab.vocab': _mod_vocab})
"""
path = pathlib.Path(site.getsitepackages()[0]) / 'sitecustomize.py'
path.write_text(textwrap.dedent(code).lstrip() + '\n')
PY
log "sitecustomize.py stub for torchtext.vocab installed"

# ───────── 6. **NEW** one-line sed patch for model.py  ───────────────────────
sed -i "1s#^#try:\\n import torchtext.vocab.vocab as Vocab\\nexcept ModuleNotFoundError:\\n from types import SimpleNamespace as Vocab\\n#" \
  "$INSTALL_DIR/src/Model/Transformer/model.py"

# ───────── 7. ensure PYTHONPATH  ─────────────────────────────────────────────
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

# ───────── 8. checkpoints  ──────────────────────────────────────────────────
for rel in "${!CKPT[@]}"; do
  f="$INSTALL_DIR/src/ckpts/$rel"; [[ -f $f ]] && continue
  mkdir -p "$(dirname "$f")"
  curl -Ls -o "$f" "$CKPT_URL/${CKPT[$rel]}"
done

# ───────── 9. smoke-test  ────────────────────────────────────────────────────
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅  TRACER ready –  source $VENV_DIR/bin/activate"
