#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "removed /root/tracer"; }

INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.4.1
CKPT=https://figshare.com/ndownloader/files
declare -A W=([Transformer/ckpt_conditional.pth]=45039339
              [Transformer/ckpt_unconditional.pth]=45039342
              [GCN/GCN.pth]=45039345)

# ── 1. venv ────────────────────────────────────────────────────────────────
[[ -d $VENV ]] || python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip -q install -U pip setuptools wheel
pip -q install torch=="$TORCH"+cpu torchvision --index-url \
      https://download.pytorch.org/whl/cpu
pip -q uninstall -y torchtext || true        # never load the binary wheel
pip -q install rdkit tqdm omegaconf hydra-core pandas scikit-learn requests
pip -q install torch-geometric==2.3.0 \
      -f "https://pytorch-geometric.com/whl/torch-${TORCH}+cpu.html"
log "torch ${TORCH}+cpu and deps installed (torchtext removed)"

# ── 2. clone TRACER ────────────────────────────────────────────────────────
[[ -d $INSTALL/src/.git ]] \
  && git -C "$INSTALL/src" pull --ff-only \
  || git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"

# ── 3. patch config.py (mutable defaults) ──────────────────────────────────
python - <<'PY'
from pathlib import Path
import re
p = Path("/root/tracer/src/config/config.py"); t = p.read_text()
if 'field(' not in t:
    t = t.replace('from dataclasses import dataclass',
                  'from dataclasses import dataclass, field')
t = re.sub(r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
           r'\1: \2 = field(default_factory=\2)', t)
p.write_text(t)
PY

# ── 4. sitecustomize stub (pure-Python torchtext) ───────────────────────────
python - <<'PY'
import site, pathlib, textwrap
code = """
import sys, types
def _vocab(counter=None, specials=()):
    stoi, idx = {}, 0
    for tok in specials or []:
        if tok not in stoi:
            stoi[tok] = idx; idx += 1
    if counter:
        for tok in counter:
            if tok not in stoi:
                stoi[tok] = idx; idx += 1
    return types.SimpleNamespace(stoi=stoi, itos=list(stoi))
_mod = types.ModuleType('torchtext.vocab.vocab'); _mod.make_vocab=_vocab
_pkg = types.ModuleType('torchtext.vocab'); _pkg.vocab=_mod
_root = types.ModuleType('torchtext'); _root.vocab=_pkg
sys.modules.update({'torchtext':_root,'torchtext.vocab':_pkg,
                    'torchtext.vocab.vocab':_mod})
"""
path = pathlib.Path(site.getsitepackages()[0])/'sitecustomize.py'
path.write_text(textwrap.dedent(code).lstrip()+"\n")
PY
log "sitecustomize stub written"

# ── 5. patch model.py and preprocess.py (failsafe) ─────────────────────────
python - <<'PY'
from pathlib import Path
import re, textwrap

def patch(file, pattern):
    txt = file.read_text()
    if re.search(pattern, txt):
        stub = textwrap.dedent("""
        # fallback stub: replaces torchtext vocab
        from types import SimpleNamespace as _SN
        def _vocab(counter=None, specials=()):
            stoi, idx = {}, 0
            for tok in specials or []:
                if tok not in stoi:
                    stoi[tok] = idx; idx += 1
            if counter:
                for tok in counter:
                    if tok not in stoi:
                        stoi[tok] = idx; idx += 1
            return _SN(stoi=stoi, itos=list(stoi))
        vocab = _vocab if 'from torchtext' in locals() else None
        Vocab = _SN(make_vocab=_vocab)
        """).strip()
        txt = re.sub(pattern, stub, txt, flags=re.M)
        file.write_text(txt)

patch(Path("/root/tracer/src/Model/Transformer/model.py"),
      r'^\s*import\s+torchtext\.vocab\.vocab.*$')
patch(Path("/root/tracer/src/scripts/preprocess.py"),
      r'^\s*from\s+torchtext\.vocab\s+import\s+vocab.*$')
PY
log "TorchText imports patched out of codebase"

# ── 6. make TRACER importable
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" \
  || echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ── 7. download weights
for rel id in "${!W[@]}"; do
  tgt="$INSTALL/src/ckpts/$rel"
  [[ -f $tgt ]] || { mkdir -p "$(dirname "$tgt")"; curl -Ls -o "$tgt" "$CKPT/${W[$rel]}"; }
done

# ── 8. smoke-test
log "running MCTS smoke-test …"
python "$INSTALL/src/scripts/mcts.py" \
  --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  --mcts.num_steps 25
log "✅  TRACER installed & tested — activate with:"
log "   source $VENV/bin/activate"
