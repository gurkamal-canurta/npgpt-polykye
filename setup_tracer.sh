#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

###############################################################################
# Optional wipe
###############################################################################
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

###############################################################################
# Paths & constants
###############################################################################
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TORCH_VER=2.4.1      # CPU wheel
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=([Transformer/ckpt_conditional.pth]=45039339
                 [Transformer/ckpt_unconditional.pth]=45039342
                 [GCN/GCN.pth]=45039345)

###############################################################################
# 1. venv + core deps
###############################################################################
[[ -d $VENV_DIR ]] || python3 -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH_VER"+cpu torchvision \
  --index-url https://download.pytorch.org/whl/cpu
pip uninstall -y -q torchtext || true   # ensure binary torchtext is gone
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
# 3. patch config.py for Python 3.12 dataclass rule
###############################################################################
python - <<'PY'
from pathlib import Path
import re
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
# 4. patch Model/Transformer/model.py (done earlier but idempotent)
###############################################################################
python - <<'PY'
from pathlib import Path, re, textwrap
mdl = Path("/root/tracer/src/Model/Transformer/model.py")
txt = mdl.read_text()
if 'torchtext.vocab.vocab' in txt:
    txt = re.sub(r'import\s+torchtext\.vocab\.vocab\s+as\s+Vocab',
                 textwrap.dedent("""
                 # patched: replace torchtext with minimal stub
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
                 """).strip(),
                 txt, flags=re.M, count=1)
    mdl.write_text(txt)
PY

###############################################################################
# 5. **NEW** patch scripts/preprocess.py to drop torchtext import
###############################################################################
python - <<'PY'
from pathlib import Path, re, textwrap
pre = Path("/root/tracer/src/scripts/preprocess.py")
txt = pre.read_text()
if 'from torchtext.vocab import vocab' in txt:
    txt = re.sub(r'from\s+torchtext\.vocab\s+import\s+vocab',
                 textwrap.dedent("""
                 # patched: drop torchtext
                 from types import SimpleNamespace as _SN
                 def vocab(counter=None, specials=()):
                     stoi, idx = {}, 0
                     for tok in specials or []:
                         if tok not in stoi:
                             stoi[tok] = idx; idx += 1
                     if counter:
                         for tok in counter:
                             if tok not in stoi:
                                 stoi[tok] = idx; idx += 1
                     return _SN(stoi=stoi, itos=list(stoi))
                 """).strip(),
                 txt, flags=re.M, count=1)
    pre.write_text(txt)
PY
log "scripts/preprocess.py import patched"

###############################################################################
# 6. add TRACER to PYTHONPATH in venv
###############################################################################
# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

###############################################################################
# 7. checkpoints
###############################################################################
for rel in "${!CKPT[@]}"; do
  f="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $f ]] || { mkdir -p "$(dirname "$f")"; curl -Ls -o "$f" "$CKPT_URL/${CKPT[$rel]}"; }
done

###############################################################################
# 8. smoke-test
###############################################################################
log "running MCTS smoke-test …"
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅  TRACER installed & tested — activate via:"
log "   source $VENV_DIR/bin/activate"
