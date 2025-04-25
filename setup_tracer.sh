#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;36m%s\e[0m\n' "$*"; }

[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed previous /root/tracer"; }

# ── basic paths ──────────────────────────────────────────────────────────────
INSTALL_DIR=/root/tracer
VENV_DIR=$INSTALL_DIR/.venv
TMPDIR=/root/tmp
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPT=([Transformer/ckpt_conditional.pth]=45039339
                 [Transformer/ckpt_unconditional.pth]=45039342
                 [GCN/GCN.pth]=45039345)
mkdir -p "$INSTALL_DIR" "$TMPDIR/pip-cache"
export TMPDIR PIP_CACHE_DIR="$TMPDIR/pip-cache"

# ── 1. venv first ────────────────────────────────────────────────────────────
[[ -d $VENV_DIR ]] || { python3 -m venv "$VENV_DIR"; log "created venv in $VENV_DIR"; }
# shellcheck source=/dev/null
source "$VENV_DIR/bin/activate"
pip install -qU pip setuptools wheel

# ── 2. core wheels inside venv ───────────────────────────────────────────────
TORCH_VER=2.4.1                              # any 2.4.x CPU wheel is fine
pip install -q torch=="$TORCH_VER"+cpu torchvision \
       --index-url https://download.pytorch.org/whl/cpu
log "Torch $TORCH_VER +cpu installed in venv"

pip install -q rdkit
PYG_URL="https://pytorch-geometric.com/whl/torch-${TORCH_VER}+cpu.html"
pip install -q torch-geometric==2.3.0 -f "$PYG_URL" \
               hydra-core omegaconf pandas scikit-learn tqdm requests

# ── 3. clone / update TRACER ─────────────────────────────────────────────────
if [[ -d $INSTALL_DIR/src/.git ]]; then
  git -C "$INSTALL_DIR/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL_DIR/src"
fi

# ── 4. patch Python-3.12 dataclass mutable-default rule ──────────────────────
python - <<'PY'
from pathlib import Path; import re
cfg = Path("/root/tracer/src/config/config.py")
txt = cfg.read_text()
if 'field' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = re.sub(r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

# ── 5. permanent torchtext stub (satisfies torchtext.vocab.vocab) ────────────
python - <<'PY'
import site, textwrap, pathlib
code = """
import sys, types
def _make_vocab(counter=None, specials=()):
    stoi = {tok:i for i,tok in enumerate(specials)}
    if counter is not None:
        for tok in counter:
            stoi.setdefault(tok, len(stoi))
    itos = list(stoi.keys())
    return types.SimpleNamespace(stoi=stoi, itos=itos)

_mod_vocab = types.ModuleType("torchtext.vocab.vocab")
_mod_vocab.make_vocab = _make_vocab
_mod_tv = types.ModuleType("torchtext.vocab")
_mod_tv.vocab = _mod_vocab
_mod_tt = types.ModuleType("torchtext")
_mod_tt.vocab = _mod_tv
sys.modules.update({
    "torchtext": _mod_tt,
    "torchtext.vocab": _mod_tv,
    "torchtext.vocab.vocab": _mod_vocab,
})
"""
pth = pathlib.Path(site.getsitepackages()[0]) / "torchtext_stub.pth"
pth.write_text(textwrap.dedent(code).strip() + '\n')
PY
log "torchtext stub installed (avoids deprecated binary wheels)"

# ── 6. add TRACER to PYTHONPATH automatically ───────────────────────────────
# shellcheck source=/dev/null
source "$INSTALL_DIR/src/set_up.sh"
grep -qxF "source $INSTALL_DIR/src/set_up.sh" "$VENV_DIR/bin/activate" || \
  echo "source $INSTALL_DIR/src/set_up.sh" >> "$VENV_DIR/bin/activate"

# ── 7. weights ───────────────────────────────────────────────────────────────
for rel in "${!CKPT[@]}"; do
  dst="$INSTALL_DIR/src/ckpts/$rel"
  [[ -f $dst ]] || { mkdir -p "$(dirname "$dst")"; curl -Ls -o "$dst" "$CKPT_URL/${CKPT[$rel]}"; }
done

# ── 8. smoke-test ────────────────────────────────────────────────────────────
log "running MCTS smoke-test ..."
python "$INSTALL_DIR/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25

log "✅  TRACER ready – activate with:  source $VENV_DIR/bin/activate"
