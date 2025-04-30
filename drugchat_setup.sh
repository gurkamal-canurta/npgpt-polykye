#!/usr/bin/env bash
set -euo pipefail

# 1. Install uv (Astral) if missing
if ! command -v uv &>/dev/null; then
  echo "📥 Installing uv…"
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$HOME/.uv/bin:$PATH"
fi

# 2. Create & enter .venv (Python 3.9)
echo "🐍 Creating virtual environment…"
uv venv --python 3.9
# shellcheck disable=SC1091
source .venv/bin/activate

# 3. Fetch requirements.txt from GitHub
echo "📄 Downloading requirements.txt…"
curl -LsSf https://raw.githubusercontent.com/gurkamal-canurta/npgpt-polykye/main/drugchat_requirements.txt -o requirements.txt

# 4. Sync with uv pip sync
echo "🔄 Installing dependencies…"
uv pip install --upgrade pip setuptools wheel
uv pip sync \
  --index-url             https://pypi.org/simple \
  --extra-index-url       https://download.pytorch.org/whl/cu116 \
  --find-links            https://data.pyg.org/whl/torch-1.12.1+cu116.html \
  --index-strategy        unsafe-best-match \
  requirements.txt

# 5. Verify core packages
echo "✅ Verifying installation…"
python - <<'EOF'
from importlib.metadata import version
import torch, torch_scatter, torch_geometric
print("✔ typing_extensions:", version("typing-extensions"))
print("✔ torch:", torch.__version__)
print("✔ torch_scatter:", torch_scatter.__version__)
print("✔ torch_geometric:", torch_geometric.__version__)
EOF

echo
echo "All set! To work in this env, run:"
echo "  source .venv/bin/activate"
echo
echo "To snapshot installed packages, run:"
echo "  uv pip freeze > freeze.txt"
