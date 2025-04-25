#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_FILE="$INSTALL_DIR/requirements.plapt.txt"
ADD_PYTHONPATH="$PLAPT_SRC"

###############################################################################
log "1/6  activate venv"
###############################################################################
[[ -d $VENVDIR ]] || { echo "❌  NPGPT venv missing." >&2; exit 1; }
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"

###############################################################################
log "2/6  update helper repo"
###############################################################################
git -C "$INSTALL_DIR" pull --ff-only

###############################################################################
log "3/6  ensure requirements.plapt.txt"
###############################################################################
if [[ ! -f $REQ_FILE ]]; then
  if curl -fsSL \
       https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/requirements.plapt.txt \
       -o "$REQ_FILE"; then
    echo "   • downloaded $REQ_FILE from GitHub"
  else
    echo "   • writing fallback list"
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
log "4/6  install PLAPT wheels"
###############################################################################
pip install --quiet --no-cache-dir -r "$REQ_FILE"

###############################################################################
log "5/6  clone / update PLAPT repo"
###############################################################################
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  rm -rf "$PLAPT_SRC"
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi

# add plapt.py to PYTHONPATH once
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/6  smoke-test"
###############################################################################
if [[ -f $INSTALL_DIR/plapt_test.py ]]; then
  python "$INSTALL_DIR/plapt_test.py" || true
else
  echo "   • plapt_test.py still not present – skip test"
fi

echo -e "\n✅  PLAPT ready – re-run this script any time."
