#!/usr/bin/env python
"""
Very small PLAPT smoke-test: predicts a single affinity score.
"""

from plapt import Plapt

protein = (
    "MKTVRQERLKSIVRILERSKEPVSGAQLAEELSVSRQVIVQDIAYLRSLGYNIVATPRGYVLAGG"
)
ligand  = "CC1=CC=C(C=C1)C2=CC(=NN2C3=CC=C(C=C3)S(=O)(=O)N)C(F)(F)F"

model = Plapt()                           # will download weights once (~90 MB)
score = model.score_candidates(protein, [ligand])[0]

print(f"\nPredicted affinity (pKd): {score:.3f}")
