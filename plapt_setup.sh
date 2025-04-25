#!/usr/bin/env bash
########################################################################
# plapt_setup.sh  –  add PLAPT to the existing NPGPT venv
# * Bullet-proof: safe to run any time, in any partial state
# * Force-syncs helper repo (hard-reset + clean) before using its files
########################################################################
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

# ─── paths ────────────────────────────────────────────────────────────
INSTALL_DIR="/root/npgpt"
VENVDIR="$INSTALL_DIR/.venv"
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
REQ_FILE="$INSTALL_DIR/requirements.plapt.txt"
ADD_PYTHONPATH="$PLAPT_SRC"

###############################################################################
log "1/6  activate venv"
###############################################################################
if [[ ! -d $VENVDIR ]]; then
  echo "❌  NPGPT venv missing. Run setup_npgpt_droplet.sh first." >&2
  exit 1
fi
# shellcheck source=/dev/null
source "$VENVDIR/bin/activate"

###############################################################################
log "2/6  force-sync helper repo (overwrites local files)"
###############################################################################
if [[ -d $INSTALL_DIR/.git ]]; then
  git -C "$INSTALL_DIR" fetch origin
  git -C "$INSTALL_DIR" reset --hard origin/main   # ← overwrites tracked files
  git -C "$INSTALL_DIR" clean -fd                  # ← removes ALL untracked
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
  || {                                          # fallback if GitHub unavailable
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
  }
fi

###############################################################################
log "4/6  install PLAPT wheels"
###############################################################################
pip install --quiet --no-cache-dir -r "$REQ_FILE"

###############################################################################
log "5/6  clone / update PLAPT source"
###############################################################################
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d $PLAPT_SRC/.git ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  rm -rf "$PLAPT_SRC"
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi

# add plapt.py to PYTHONPATH exactly once
grep -qxF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "6/6  smoke-test (if present)"
###############################################################################
if [[ -f $INSTALL_DIR/plapt_test.py ]]; then
  python "$INSTALL_DIR/plapt_test.py" || true
else
  echo "   • plapt_test.py not found – skipping test"
fi

echo -e "\n✅  PLAPT ready – run this script again any time."
