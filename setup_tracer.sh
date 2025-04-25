#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;36m%s\e[0m\n' "$*"; }

###############################################################################
# 0) Locations
###############################################################################
ROOT=/root
TRACER_DIR=$ROOT/tracer
VENV=$TRACER_DIR/.venv

###############################################################################
# 1) Find or decide the Torch build we’ll use
###############################################################################
torch_ver=$(python - <<'PY'
import sys, importlib.util, re, os
spec = importlib.util.find_spec("torch")
if spec is None:
    sys.exit(1)
import torch, re
print(re.match(r"\d+\.\d+\.\d+", torch.__version__).group(0))
PY) || torch_ver="2.0.1"
log "✓ using Torch $torch_ver (CPU)"

###############################################################################
# 2) Fresh venv
###############################################################################
python3 -m venv "$VENV"
source "$VENV/bin/activate"
pip install -U pip setuptools wheel

###############################################################################
# 3) Core deps (reuse Torch wheel if system already has it)
###############################################################################
if ! python - <<EOF
import importlib.util, sys; sys.exit(0 if importlib.util.find_spec("torch") else 1)
EOF
then
  pip install torch=="${torch_ver}"+cpu torchvision --index-url https://download.pytorch.org/whl/cpu
fi

# torch-geometric CPU wheel matches the Torch version
pyg_url="https://pytorch-geometric.com/whl/torch-${torch_ver}+cpu.html"
pip install rdkit hydra-core omegaconf pandas scikit-learn tqdm
pip install torch-geometric==2.3.0 -f "$pyg_url"

###############################################################################
# 4) Clone TRACER & set PYTHONPATH
###############################################################################
git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$TRACER_DIR"
cd "$TRACER_DIR"
source set_up.sh
echo "source $TRACER_DIR/set_up.sh" >> "$VENV/bin/activate"

###############################################################################
# 5) Pull pretrained weights
###############################################################################
mkdir -p ckpts/Transformer ckpts/GCN
curl -L -o ckpts/Transformer/ckpt_conditional.pth  \
     https://figshare.com/ndownloader/files/45039339
curl -L -o ckpts/Transformer/ckpt_unconditional.pth \
     https://figshare.com/ndownloader/files/45039342
curl -L -o ckpts/GCN/GCN.pth \
     https://figshare.com/ndownloader/files/45039345

###############################################################################
# 6) Quick smoke-test (luteolin scaffold, 25-step tree)
###############################################################################
log "▶ running MCTS smoke-test ..."
python scripts/mcts.py \
       --data.input.start_smiles "C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
       --mcts.num_steps 25

log "✅  TRACER setup complete — remember:  source $VENV/bin/activate"
