#!/usr/bin/env bash
set -euo pipefail
log(){ printf '\e[1;34m%s\e[0m\n' "$*"; }

INSTALL_DIR="/root/npgpt"                       # repo we already have
VENVDIR="$INSTALL_DIR/.venv"
PLAPT_SRC="$INSTALL_DIR/externals/plapt"
ADD_PYTHONPATH="$PLAPT_SRC"

###############################################################################
log "1/4  activate existing venv"
###############################################################################
source "$VENVDIR/bin/activate" || {
  echo "❌  NPGPT venv not found. Run setup_npgpt_droplet.sh first."; exit 1; }

###############################################################################
log "2/4  install extra wheels for PLAPT"
###############################################################################
pip install --quiet --no-cache-dir -r "$INSTALL_DIR/requirements.plapt.txt"

###############################################################################
log "3/4  clone / update PLAPT repo"
###############################################################################
mkdir -p "$(dirname "$PLAPT_SRC")"
if [[ -d "$PLAPT_SRC/.git" ]]; then
  git -C "$PLAPT_SRC" pull --ff-only
else
  git clone --depth 1 https://github.com/trrt-good/PLAPT.git "$PLAPT_SRC"
fi

# PLAPT is a single-file module; no setup.py -> just put it on PYTHONPATH
grep -qF "$ADD_PYTHONPATH" "$VENVDIR/bin/activate" || \
  echo "export PYTHONPATH=\"$ADD_PYTHONPATH\${PYTHONPATH+:\$PYTHONPATH}\"" \
  >> "$VENVDIR/bin/activate"
export PYTHONPATH="$ADD_PYTHONPATH${PYTHONPATH+:":$PYTHONPATH"}"

###############################################################################
log "4/4  smoke-test: python plapt_test.py"
###############################################################################
python "$INSTALL_DIR/plapt_test.py" || true
echo "✅  PLAPT installed – re-run this script any time."
