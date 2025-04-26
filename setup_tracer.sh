#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;32m%s\e[0m\n' "$*"; }

# 0) Ensure Python 3.11 is available
if ! command -v python3.11 &> /dev/null; then
    log "Installing Python 3.11..."
    apt-get update
    apt-get install -y --no-install-recommends \
        software-properties-common \
        build-essential \
        libssl-dev \
        zlib1g-dev \
        libbz2-dev \
        libreadline-dev \
        libsqlite3-dev \
        curl \
        llvm \
        libncurses5-dev \
        libncursesw5-dev \
        xz-utils \
        tk-dev \
        libffi-dev \
        liblzma-dev
    add-apt-repository -y ppa:deadsnakes/ppa
    apt-get update
    apt-get install -y python3.11 python3.11-venv python3.11-dev
fi

# 1) Optional clean slate
[[ ${1:-} == "--fresh" ]] && { rm -rf /root/tracer; log "wiped /root/tracer"; }

# 2) Constants
INSTALL=/root/tracer
VENV=$INSTALL/.venv
TORCH=2.3.0
CKPT_URL="https://figshare.com/ndownloader/files"
declare -A CKPTS=(
  [Transformer/ckpt_conditional.pth]=45039339
  [Transformer/ckpt_unconditional.pth]=45039342
  [GCN/GCN.pth]=45039345
)

# 3) Create & activate venv with Python 3.11
[[ -d $VENV ]] || python3.11 -m venv "$VENV"
# shellcheck source=/dev/null
source "$VENV/bin/activate"

# 4) Install dependencies with proper separation
log "Updating base packages..."
pip install -qU pip setuptools wheel

log "Installing PyTorch..."
pip install -q \
    torch=="$TORCH"+cpu \
    torchvision \
    --index-url https://download.pytorch.org/whl/cpu

log "Installing core dependencies..."
pip install -q \
    hydra-core \
    rdkit \
    onnxruntime \
    pandas \
    scipy \
    diskcache \
    biopython \
    accelerate \
    requests \
    tqdm \
    datasets \
    evaluate \
    pillow \
    huggingface-hub \
    scikit-learn

log "Installing torch-geometric..."
pip install -q torch-geometric==2.3.0

# 5) Clone or update TRACER
if [[ -d $INSTALL/src/.git ]]; then
  git -C "$INSTALL/src" pull --ff-only
else
  git clone --depth 1 https://github.com/sekijima-lab/TRACER.git "$INSTALL/src"
fi

# 6) Patch for modern Python compatibility
log "Applying compatibility patches..."
python <<PY
from pathlib import Path
import re

cfg_path = Path("/root/tracer/src/config/config.py")
content = cfg_path.read_text()

# Add field import
if 'field(' not in content:
    content = content.replace(
        'from dataclasses import dataclass',
        'from dataclasses import dataclass, field'
    )

# Fix mutable defaults
content = re.sub(
    r'(\w+):\s+([A-Za-z_]\w*)\s*=\s*\2\(\)',
    r'\1: \2 = field(default_factory=\2)',
    content
)

cfg_path.write_text(content)
PY

# 7) Configure environment paths
log "Setting up environment paths..."
# shellcheck source=/dev/null
source "$INSTALL/src/set_up.sh"
grep -qxF "source $INSTALL/src/set_up.sh" "$VENV/bin/activate" \
  || echo "source $INSTALL/src/set_up.sh" >> "$VENV/bin/activate"

# 8) Download checkpoints
log "Downloading pretrained models..."
for rel in "${!CKPTS[@]}"; do
  dst="$INSTALL/src/ckpts/$rel"
  [[ -f $dst ]] || {
    mkdir -p "$(dirname "$dst")"
    curl -Ls -o "$dst" "$CKPT_URL/${CKPTS[$rel]}"
    log "Downloaded ${rel}"
  }
done

# 9) Validation test
log "Running smoke test..."
pushd "$INSTALL/src" >/dev/null
python scripts/mcts.py \
  mcts.in_smiles_file="C1=CC(=C(C=C1)O)C2=CC(=O)C3=C(C=C(C=C3O2)O)O" \
  mcts.n_step=25
popd >/dev/null

log "✅ Installation completed successfully!"
log "Activate environment with: source $VENV/bin/activate"
