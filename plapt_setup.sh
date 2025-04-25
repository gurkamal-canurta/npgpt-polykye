#!/usr/bin/env bash
########################################################################
#  plapt_setup.sh – add the PLAPT library to the existing NPGPT venv   #
#  Idempotent: safe to run any number of times in any partial state.   #
########################################################################
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

# ─── paths ────────────────────────────────────────────────────────────
INSTALL_DIR="/root/npgpt"            # where your repo already lives
VENVDIR="$INSTALL_DIR/.venv"         # existing virtual-env
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_FILE="$INSTALL_DIR/requirements.plapt.txt"
ADD_PYTHONPATH="$PLAPT_SRC"          # expose plapt.py

# ─── 1. activate venv (abort clearly if missing) ──────────────────────
log "1/5  activate existing venv"
if [[ ! -d $VENVDIR ]]; then
  echo "❌  NPGPT venv not found. Run setup_npgpt_droplet.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"

# ─── 2. guarantee requirements.plapt.txt exists ───────────────────────
log "2/5  ensure requirements.plapt.txt"
if [[ ! -f $REQ_FILE ]]; then
  if curl -fsSL \
       https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/requirements.plapt.txt \
       -o "$REQ_FILE"; then
    echo "   • downloaded $REQ_FILE from GitHub"
  else
    echo "   • GitHub version not found, writing fallback list locally"
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

# ─── 3. install extra wheels only if missing ──────────────────────────
log "3/5  install PLAPT wheels"
pip install --quiet --no-cache-dir -r "$REQ_FILE"

# ─── 4. clone or update PLAPT repo & expose path ──────────────────────
log "4/5  clone / update PLAPT"
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  rm -rf "$PLAPT_SRC"
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi
# add to PYTHONPATH exactly once (safe under set -u)
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

# ─── 5. smoke-test if plapt_test.py is present ────────────────────────
log "5/5  smoke-test"
if [[ -f $INSTALL_DIR/plapt_test.py ]]; then
  python "$INSTALL_DIR/plapt_test.py" || true
else
  echo "   • plapt_test.py not found – skipping test"
fi

echo -e "\n✅  PLAPT installed and ready – re-run script anytime."
