# Build APG_qm.py = APG_gas.py (hardened typing) + QM (RESP/ESP) monomer charges. 2026-10-17
import re
gas = open('APG_gas.py').read(); resp = open('APG_resp.py').read()
fn = resp[resp.index('def assign_resp_charges('):resp.index('def PolymerGen(')]
hdr = resp[resp.index('CHARGE_SCHEME = '):resp.index('smiles_csv = ')]
def rep(s, a, b):
    assert s.count(a) == 1, a; return s.replace(a, b)
g = gas
g = rep(g, "from pysimm.apps.random_walk import random_walk, copolymer\n",
        "from pysimm.apps.random_walk import random_walk, copolymer\nimport numpy as np\n")
g = rep(g, "all_gen = False\n", "# --- QM charge scheme (RESP | ESP); typing identical to APG_gas.py ---\n" + hdr + "\nall_gen = False\n")
g = rep(g, "def PolymerGen(", fn + "def PolymerGen(")
# capped-monomer QM fit before cap-H removal (no typing needed: fit uses elements + coordinates only)
g = rep(g, "    p_head.linker = 'head'\n    p_tail.linker = 'tail'\n\n    for b in p_head.bonds:",
"""    p_head.linker = 'head'
    p_tail.linker = 'tail'

    # fit charges on the closed-shell, H-capped monomer; fold each removed cap-H charge onto its head/tail atom
    s = assign_resp_charges(pysimm_obj=s, output_xyz="monomer_capped.xyz", nproc=nproc, opt=True, total_multiplicity=1)
    if s is None:
        raise RuntimeError(f"{CHARGE_SCHEME} charge fit failed on the capped monomer")
    for pp in s.particles:
        pp._qfit = pp.charge
    p_head = s.particles[head]; p_tail = s.particles[tail]

    for b in p_head.bonds:""")
g = rep(g, "            pb = b.a if b.b is p_head else b.b \n            s.particles.remove(pb.tag, update=False)\n",
        "            pb = b.a if b.b is p_head else b.b \n            p_head._qfit += pb._qfit\n            s.particles.remove(pb.tag, update=False)\n")
g = rep(g, "            pb = b.a if b.b is p_tail else b.b \n            s.particles.remove(pb.tag, update=False)\n",
        "            pb = b.a if b.b is p_tail else b.b \n            p_tail._qfit += pb._qfit\n            s.particles.remove(pb.tag, update=False)\n")
g = rep(g, "    apply_charges_safe(s, f, 'monomer')\n",
"""    for pp in s.particles:
        pp.charge = pp._qfit
    print(f"[{CHARGE_SCHEME}] repeat-unit charge sum = {sum(pp.charge for pp in s.particles):+.6f}", flush=True)
""")
g = rep(g, "    apply_charges_safe(ter, f, 'terminator')\n",
"""    for i, particle in enumerate(ter.particles[-4:]):   # RESP-fitted CH3 cap (same as APG_resp.py)
        particle.charge = ch3_charges[i]
        particle.x, particle.y, particle.z = ch3_positions[i]
""")
g = rep(g, "    apply_charges_safe(c2_polymer, f, 'terminated_polymer')\n",
"""    # keep the QM monomer + CH3 charges carried through random_walk/copolymer
    print(f"[{CHARGE_SCHEME}] chain charge sum = {sum(pp.charge for pp in c2_polymer.particles):+.6f}", flush=True)
""")
open('APG_qm.py', 'w').write(g)
print("ok", len(g.splitlines()))
