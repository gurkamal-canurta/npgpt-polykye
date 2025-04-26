#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

###############################################################################
# wipe if requested
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

###############################################################################
# paths & constants
###############################################################################
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TORCH_VER=2.4.1
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345 )

###############################################################################
# 1. venv & core deps
###############################################################################
[[ -d $VENV_DIR ]] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH_VER"+cpu torchvision \
  --index-url https://download.pytorch.org/whl/cpu
# rid the env of any pre-installed torchtext
pip uninstall -y -q torchtext || true
pip install -q rdkit
PYG_URL="https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
               hydra-core omegaconf pandas scikit-learn tqdm requests
log "torch ${TORCH_VER}+cpu and deps installed (no torchtext wheel)"

###############################################################################
# 2. clone / pull TRACER
###############################################################################
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

###############################################################################
# 3. patch Python 3.12 dataclass rule
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
# 4. write sitecustomize stub (executes on every Python start-up)
###############################################################################
python - <<'PY'
import site, pathlib, textwrap
code = """
import sys, types
def _make_vocab(counter=None, specials=()):
    stoi = {}
    for tok in specials or []:
        stoi.setdefault(tok, len(stoi))
    if counter:
        for tok in counter:
            stoi.setdefault(tok, len(stoi))
    return types.SimpleNamespace(stoi=stoi, itos=list(stoi))
_mod_vocab = types.ModuleType('torchtext.vocab.vocab'); _mod_vocab.make_vocab = _make_vocab
_mod_tv    = types.ModuleType('torchtext.vocab'); _mod_tv.vocab = _mod_vocab
_mod_tt    = types.ModuleType('torchtext'); _mod_tt.vocab = _mod_tv
sys.modules.update({'torchtext': _mod_tt,
                    'torchtext.vocab': _mod_tv,
                    'torchtext.vocab.vocab': _mod_vocab})
"""
pth = pathlib.Path(site.getsitepackages()[0]) / "sitecustomize.py"
pth.write_text(textwrap.dedent(code).lstrip() + "\n")
PY
log "sitecustomize.py stub installed"

###############################################################################
# 5. belt-and-suspenders: rewrite import line in model.py
###############################################################################
python - <<'PY'
from pathlib import Path, re, textwrap
mdl = Path("/root/tracer/src/Model/Transformer/model.py")
txt = mdl.read_text()
if 'torchtext.vocab.vocab' in txt:
    txt = re.sub(r'import\s+torchtext\.vocab\.vocab\s+as\s+Vocab',
                 textwrap.dedent("""
                 from types import SimpleNamespace as _SN
                 def _mk(counter=None, specials=()):  # stubbed vocab
                     stoi={}; [stoi.setdefault(t,len(stoi)) for t in specials]
                     if counter:
                         [stoi.setdefault(t,len(stoi)) for t in counter]
                     return _SN(stoi=stoi, itos=list(stoi))
                 Vocab = _SN(make_vocab=_mk)
                 """).strip(),
                 txt, count=1)
    mdl.write_text(txt)
PY
log "model.py import patched"

###############################################################################
# 6. make TRACER auto-importable
###############################################################################
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 7. weights
###############################################################################
for rel in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$rel]}"; }
done

###############################################################################
# 8. smoke-test
###############################################################################
log "running MCTS smoke-test …"
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅  TRACER installed & tested — activate with:"
log "   source $VENV_DIR/bin/activate"
