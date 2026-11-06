# 1st step of lammps_eq2.in: 20000 x 0.1 fs NPT at 1000 K, then restart the clock for the ramp
timestep        0.1
fix             NPTi all npt temp 1000 1000 $(100.0*dt) iso 1.0 1.0 $(1000.0*dt)
run             20000
unfix           NPTi
reset_timestep  0
