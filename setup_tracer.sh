#!/usr/bin/env bash
set -euo pipefail

log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# ────── 0. Optional wipe ──────
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "wiped /root/tracer"; }

# ────── 1. Paths & versions ──────
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.3.0
CKPT_BASE=https://figshare.com/ndownloader/files
declare -A CKPTS=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# ────── 2. Create & activate venv ──────
[[ -d $VENV ]] || python3 -m venv "$VENV"    # venv docs :contentReference[oaicite:5]{index=5}
source "$VENV/bin/activate"

# ────── 3. Install PyTorch, TorchText, & deps ──────
pip install -qU pip setuptools wheel
pip install -q \
    torch=="${TORCH}"+cpu torchvision torchtext==0.18.0 \
    --index-url https://download.pytorch.org/whl/cpu  # official CPU wheels :contentReference[oaicite:6]{index=6}
pip install -q \
    rdkit onnxruntime pandas scipy diskcache biopython accelerate \
    requests tqdm datasets evaluate pillow huggingface-hub \
    scikit-learn torch-geometric==2.3.0

log "Installed torch ${TORCH}+cpu, torchtext 0.18.0, and other packages"

# ────── 4. Clone or update TRACER ──────
[[ -d $INSTALL/src/.git ]] \
  && git -C "$INSTALL/src" pull --ff-only \
  || git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"

# ────── 5. Patch Python-3.12 dataclass defaults ──────
# Use sed -i with extended regex to add default_factory :contentReference[oaicite:7]{index=7}
sed -i -E \
  -e 's/from dataclasses import dataclass/&\, field/' \
  -e 's/([A-Za-z_][A-Za-z0-9_]*): ([A-Za-z_][A-Za-z0-9_]*) = \2\(\)/\1: \2 = field(default_factory=\2)/g' \
  "$INSTALL/src/config/config.py"
log "Applied dataclass default_factory patch"

# ────── 6. Ensure PYTHONPATH ──────
# shellcheck source=/dev/null
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" \
  || echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# ────── 7. Download checkpoints ──────
for rel in "${!CKPTS[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] && continue
  mkdir -p "$(dirname "$dst")"
  curl -sLo "$dst" "$CKPT_BASE/${CKPTS[$rel]}"  # figshare download URL 
done

# ────── 8. Run MCTS smoke-test ──────
log "Running MCTS smoke-test …"
pushd "$INSTALL/src" >/dev/null
python scripts/mcts.py \
  mcts.in_smiles_file="C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  mcts.n_step=25
popd >/dev/null

log "✅ TRACER install & smoke-test complete—activate with 'source $VENV/bin/activate'"
