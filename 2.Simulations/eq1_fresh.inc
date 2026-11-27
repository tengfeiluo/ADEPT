# Start of lammps_eq1.in: read the generated cell, minimize, then 20000 x 0.1 fs NVT at 100 K
units           real
atom_style      full
boundary        p p p
bond_style      harmonic
angle_style     harmonic
dihedral_style  fourier
improper_style  cvff
pair_style      lj/cut 8.0
pair_modify     mix arithmetic tail yes
special_bonds   amber
neighbor        3.0 bin
neigh_modify    delay 0
kspace_style    none
read_data       ../../MODEL/${name}/amorphous_polymer_${name}.lmps
thermo          1000
thermo_style    custom step temp press etotal ke pe ebond eangle edihed eimp evdwl ecoul elong vol density lx ly lz
thermo_modify   flush yes
min_style       sd
minimize        1.0e-6 1.0e-7 10000 10000
min_style       fire
minimize        1.0e-6 1.0e-7 10000 10000
reset_timestep  0
timestep        0.1
fix             NVT1 all nvt temp 100 100 $(100.0*dt)
run             20000
unfix           NVT1
