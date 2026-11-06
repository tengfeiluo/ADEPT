# 300 K hold: same thermostat/barostat and outputs as lammps_eq2.in step 3 (files appended across chunks)
fix             NPTf all npt temp 300 300 100.0 iso 1.0 1.0 1000.0
compute         c2 all chunk/atom molecule nchunk once limit 0 ids once compress no
compute         c3 all gyration/chunk c2
fix             rg all ave/time 1 10000 10000 c_c3 append ${name}_Rg.data mode vector
variable        dens equal density
fix             densprint all print 1000 "${dens}" append ${name}_density.dat screen no
