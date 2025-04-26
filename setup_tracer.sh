#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ───────────────────────── wipe option ───────────────────────────────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

# ───────────────────────── constants ─────────────────────────────────
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.4.1           # CPU wheel
declare -A W=( [Transformer/ckpt_conditional.pth]=45039339
               [Transformer/ckpt_unconditional.pth]=45039342
               [GCN/GCN.pth]=45039345 )
CKPT_URL="https://figshare.com/ndownloader/files"

# ───────────────────────── venv & deps ───────────────────────────────
[[ -d $VENV ]] || python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH"+cpu torchvision \
        --index-url https://download.pytorch.org/whl/cpu
pip uninstall -y -q torchtext || true         # ensure binary wheel gone
pip install -q rdkit tqdm omegaconf hydra-core pandas scikit-learn requests
pip install -q torch-geometric==2.3.0 \
        -f "https://pytorch-geometric.com/whl/torch-${TORCH}+cpu.html"
log "torch ${TORCH}+cpu & deps installed (torchtext removed)"

# ───────────────────────── clone TRACER ──────────────────────────────
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# ───────────────────────── patch config.py (dataclass) ───────────────
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

# ───────────────────────── sitecustomize stub ────────────────────────
python - <<'PY'
import site, pathlib, textwrap
code = """
import sys, types
def _mk(counter=None, specials=()):
    stoi, idx = {}, 0
    for tok in specials or []:
        if tok not in stoi:
            stoi[tok] = idx; idx += 1
    if counter:
        for tok in counter:
            if tok not in stoi:
                stoi[tok] = idx; idx += 1
    return types.SimpleNamespace(stoi=stoi, itos=list(stoi))
_mod = types.ModuleType('torchtext.vocab.vocab'); _mod.make_vocab=_mk
_pkg = types.ModuleType('torchtext.vocab'); _pkg.vocab=_mod
_root= types.ModuleType('torchtext'); _root.vocab=_pkg
sys.modules.update({'torchtext':_root,'torchtext.vocab':_pkg,
                    'torchtext.vocab.vocab':_mod})
"""
path = pathlib.Path(site.getsitepackages()[0])/'sitecustomize.py'
path.write_text(textwrap.dedent(code).lstrip()+"\n")
PY
log "sitecustomize stub ready"

# ───────────────────────── patch code imports ────────────────────────
python - <<'PY'
from pathlib import Path
import re, textwrap

STUB = textwrap.dedent("""
# ↓ pure-Python fallback – no torchtext needed
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

targets = [
  "/root/tracer/src/Model/Transformer/model.py",
  "/root/tracer/src/scripts/preprocess.py"
]
for f in targets:
    p = Path(f); t = p.read_text()
    if 'torchtext' in t:
        t = re.sub(r'^\s*.*torchtext[^\n]*$', STUB, t, flags=re.M)
        p.write_text(t)
PY
log "torchtext imports removed from model.py & preprocess.py"

# ───────────────────────── add TRACER to PYTHONPATH ──────────────────
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" || \
  echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ───────────────────────── weights ───────────────────────────────────
for rel in "${!W[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${W[$rel]}"; }
done

# ───────────────────────── smoke-test ────────────────────────────────
log "running MCTS smoke-test ..."
python "$INSTALL/src/scripts/mcts.py" \
   --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
   --mcts.num_steps 25
log "✅  TRACER install OK –  activate with:  source $VENV/bin/activate"
