#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ───────────────────────────── wipe ─────────────────────────────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

# ─────────────────────────── constants ──────────────────────────
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.3.0
TORCHTEXT=0.18.0
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A W=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# ────────────────────── 1. venv & deps ─────────────────────────
[[ -d $VENV ]] || python3 -m venv "$VENV"
source "$VENV/bin/activate"

pip install -qU pip setuptools wheel
pip install -q torch=="$TORCH"+cpu torchvision torchtext=="$TORCHTEXT" \
    --index-url https://download.pytorch.org/whl/cpu
pip install -q rdkit tqdm omegaconf hydra-core pandas scikit-learn requests
pip install -q torch-geometric==2.3.0 \
    -f "https://pytorch-geometric.com/whl/torch-${TORCH}+cpu.html"
log "torch ${TORCH}+cpu & torchtext ${TORCHTEXT} installed"

# ──────────────────── 2. clone / update TRACER ───────────────────
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# ───────────────────── 3. patch config.py ───────────────────────
python - <<'PY'
from pathlib import Path
import re
cfg = Path("$INSTALL/src/config/config.py")
txt = cfg.read_text()
if 'field(' not in txt:
    txt = txt.replace('from dataclasses import dataclass',
                      'from dataclasses import dataclass, field')
txt = re.sub(r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
             r'\1: \2 = field(default_factory=\2)', txt)
cfg.write_text(txt)
PY

# ──────────────────── 4. patch code imports ─────────────────────
python - <<'PY'
from pathlib import Path
import re, textwrap

STUB = textwrap.dedent("""
# fallback stub – replaces torchtext vocab
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

for f in (
    "$INSTALL/src/Model/Transformer/model.py",
    "$INSTALL/src/scripts/preprocess.py",
    "$INSTALL/src/scripts/beam_search.py"
); do
  p=Path(f); t=p.read_text()
  if 'torchtext' in t; then
    t=re.sub(r'^\s*.*torchtext[^\n]*$', STUB, t, flags=re.M)
    p.write_text(t)
  fi
done
PY

# ─────────────────── 5. PYTHONPATH setup ───────────────────────
# shellcheck source=/dev/null
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" || \
  echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ──────────────────── 6. download weights ───────────────────────
for rel in "${!W[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] || {
    mkdir -p "$(dirname "$dst")"
    curl -Ls -o "$dst" "$CKPT_URL/${W[$rel]}"
  }
done

# ───────────────────── 7. smoke-test ───────────────────────────
log "running MCTS smoke-test …"
pushd "$INSTALL/src" >/dev/null
python scripts/mcts.py \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
popd >/dev/null

log "✅ TRACER installed & smoke-test passed — activate with:"
log "   source $VENV/bin/activate"
