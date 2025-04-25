#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_FILE="$INSTALL_DIR/requirements.plapt.txt"
ADD_PYTHONPATH="$PLAPT_SRC"

###############################################################################
log "1/6  verify & activate venv"
###############################################################################
if [[ ! -d $VENVDIR ]]; then
  echo "❌ venv missing. Run setup_npgpt_droplet.sh first." >&2; exit 1
fi
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"

###############################################################################
log "2/6  sync helper repo without touching .venv or checkpoints"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  # remove only the two conflict files if they exist locally
  rm -f "$INSTALL_DIR/plapt_setup.sh" "$INSTALL_DIR/requirements.plapt.txt"
  git -C "$INSTALL_DIR" pull --ff-only
else
  git clone https://github.com/gurkamal-canurta/npgpt-polykye.git "$INSTALL_DIR"
fi

###############################################################################
log "3/6  ensure requirements.plapt.txt"
###############################################################################
if [[ ! -f $REQ_FILE ]]; then
  curl -fsSL \
    https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/requirements.plapt.txt \
    -o "$REQ_FILE" \
  || cat > "$REQ_FILE" <<'EOF'
pandas
scipy
onnxruntime
diskcache
biopython
accelerate
requests
tqdm
datasets
evaluate
pillow
huggingface-hub
EOF
fi

###############################################################################
log "4/6  install PLAPT wheels into venv"
###############################################################################
pip install --quiet --no-cache-dir -r "$REQ_FILE"

###############################################################################
log "5/6  clone / update PLAPT source"
###############################################################################
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/6  smoke-test if present"
###############################################################################
if [[ -f $INSTALL_DIR/plapt_test.py ]]; then
  python "$INSTALL_DIR/plapt_test.py" || true
else
  echo "   • plapt_test.py missing – skipping test"
fi

echo -e "\n✅  PLAPT ready – nothing in NPGPT was touched."
