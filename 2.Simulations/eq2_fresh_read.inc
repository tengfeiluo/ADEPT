units           real
atom_style      full
boundary        p p p
bond_style      harmonic
angle_style     harmonic
dihedral_style  fourier
improper_style  cvff
pair_style      lj/cut/coul/long 8.0 12.0
pair_modify     mix arithmetic tail yes
special_bonds   amber
read_data       ${name}_eq1.data
