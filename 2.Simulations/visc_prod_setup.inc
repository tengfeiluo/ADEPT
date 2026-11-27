# Production of lammps_visc.in (NVT at Tg+50 K). The Green-Kubo and MSD-slope numbers that lammps_visc.in
# accumulated inside LAMMPS (fix ave/correlate, fix vector) cannot be carried across a restart, so the raw
# shear stress and MSD are written every 10 steps and 3.Analysis/calc_visc.py evaluates the same formulas.
if "${prodstart} == 1" then "reset_timestep 0"
fix             NVT all nvt temp ${Tfinal} ${Tfinal} 100.0
compute         MSD_poly all msd
if "${prodstart} == 1" then "print '${Tfinal} $(vol)' file ${name}_visc_state.dat"
fix             MSD_OUT all ave/time 100 1 1000 c_MSD_poly[*] file ${name}_msd_poly.dat.part_${step0}
fix             RAW all ave/time 10 1 10 c_thermo_press[4] c_thermo_press[5] c_thermo_press[6] c_MSD_poly[4] file ${name}_visc_raw.dat.part_${step0}
thermo          20000
thermo_style    custom step temp press pxy pxz pyz c_MSD_poly[4]
