units           real
dimension       3
boundary        p p p
atom_style      full
pair_style      lj/cut/coul/long 12.0 12.0
bond_style      harmonic
angle_style     harmonic
dihedral_style  fourier
improper_style  cvff
special_bonds   amber
pair_modify     mix arithmetic tail yes
read_data       ../../OPTIMIZATION/${name}/${name}_eq2.data
