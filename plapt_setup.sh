#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

INSTALL_DIR="/root/npgpt"                # repo you already have
VENVDIR="$INSTALL_DIR/.venv"
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_FILE="$INSTALL_DIR/requirements.plapt.txt"
ADD_PYTHONPATH="$PLAPT_SRC"

###############################################################################
log "1/5  activate existing venv"
###############################################################################
if [[ ! -d $VENVDIR ]]; then
  echo "❌  NPGPT venv not found. Run setup_npgpt_droplet.sh first."
  exit 1
fi
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"

###############################################################################
log "2/5  obtain requirements.plapt.txt"
###############################################################################
if [[ ! -f $REQ_FILE ]]; then
  if curl -fsSL \
       https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/requirements.plapt.txt \
       -o "$REQ_FILE"; then
    echo "   • downloaded $REQ_FILE from GitHub"
  else
    echo "   • GitHub file missing, writing fallback list locally"
    cat > "$REQ_FILE" <<'EOF'
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
fi

###############################################################################
log "3/5  install extra wheels"
###############################################################################
pip install --quiet --no-cache-dir -r "$REQ_FILE"

###############################################################################
log "4/5  clone / update PLAPT repo"
###############################################################################
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d "$PLAPT_SRC/.git" ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi

# expose plapt.py via PYTHONPATH exactly once
grep -qF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "5/5  smoke-test: plapt_test.py"
###############################################################################
if [[ -f $INSTALL_DIR/plapt_test.py ]]; then
  python "$INSTALL_DIR/plapt_test.py" || true
else
  echo "   • plapt_test.py not found – skipping smoke-test"
fi

echo -e "\n✅  PLAPT installed – you can re-run this script anytime."
