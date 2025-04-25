#!/usr/bin/env python
"""
Generates 5 SMILES for three flavonoids with NPGPT and checks
each generated string for chemical validity with RDKit.
"""

import textwrap
from rdkit import Chem
from rdkit.Chem import Descriptors
import torch

from npgpt import SmilesGptModel, SmilesGptTrainingConfig, get_tokenizer
from npgpt.config import SmilesGptGenerationConfig

import argparse
...
if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--temp", type=float, default=1.0, help="sampling temperature")
    ap.add_argument("--top_p", type=float, default=1.0, help="nucleus top-p")
    args = ap.parse_args()

    generation_cfg = SmilesGptGenerationConfig(
        num_samples=5,
        do_sample=True,
        temperature=args.temp,
        top_p=args.top_p,
    )
    main(generation_cfg)   # move the for-loop into a main() that accepts cfg

# ---------- utility ----------------------------------------------------------
def is_valid_smiles(s: str) -> bool:
    """Return True if RDKit can parse & sanitize the SMILES."""
    mol = Chem.MolFromSmiles(s, sanitize=True)
    return mol is not None


def nice(smiles: str) -> str:
    return smiles if len(smiles) <= 120 else smiles[:117] + "..."

# ---------- load model -------------------------------------------------------
device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"\nUsing device: {device}\n")

training_cfg = SmilesGptTrainingConfig()
generation_cfg = SmilesGptGenerationConfig(num_samples=5, do_sample=True)

tokenizer = get_tokenizer(
    training_cfg,
    "externals/smiles-gpt/checkpoints/benchmark-10m/tokenizer.json",
)
model = SmilesGptModel.load_from_checkpoint(
    "checkpoints/smiles-gpt/model.ckpt",
    config=training_cfg,
    tokenizer=tokenizer,
    strict=False,
).to(device).eval()

# ---------- ligands to probe -------------------------------------------------
SEEDS = {
    "Luteolin": "C1=CC(=C(C=C1C2=CC(=O)C3=C(C=C(C=C3O2)O)O)O)O",
    "Cannflavin A": "OC1=C2C(OC(=CC2=O)C3=CC(OC)=C(O)C=C3)=CC(O)=C1C/C=C(/CCC=C(C)C)\\C",
    "Chrysoeriol": "COC1=CC(=C(C=C1O)O)C2=CC(=C(C=C2O)O)C3=CC(=O)C(=C(O3)O)O",
}

# ---------- generation -------------------------------------------------------
for label, seed in SEEDS.items():
    print(f"\n--- {label} ({seed}) ---")
    seed_tokens = tokenizer.encode(seed, add_special_tokens=False)
    bos = torch.tensor([[tokenizer.bos_token_id] + seed_tokens]).to(device)

    outputs = model.model.generate(
        bos,
        max_length=generation_cfg.max_length,
        do_sample=True,
        top_p=generation_cfg.top_p,
        temperature=generation_cfg.temperature,
        pad_token_id=tokenizer.pad_token_id,
        bos_token_id=tokenizer.bos_token_id,
        eos_token_id=tokenizer.eos_token_id,
        num_return_sequences=generation_cfg.num_samples,
    )

    for i, out in enumerate(outputs, 1):
        s = tokenizer.decode(out, skip_special_tokens=True)
        flag = "✅" if is_valid_smiles(s) else "❌"
        print(f"{i}. {nice(s)}  {flag}")

print("\nDone.\n")
