#!/bin/bash
set -euo pipefail
ADEPT="$(cd "$(dirname "$0")/.." && pwd)"
echo "=== Unit test: bash helpers ==="
export initial_dir
initial_dir=$(mktemp -d)
mkdir -p "$initial_dir/POLYMER_DATA/THERMAL_CONDUCTIVITY/PIDX"
# shellcheck disable=SC1091
agent_checkpoint_log() { :; }
# shellcheck source=/dev/null
source "$ADEPT/Files/checkpoint.sh"
is_number() { [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }

tc_dir=$initial_dir/POLYMER_DATA/THERMAL_CONDUCTIVITY/PIDX
printf '%s\n' '0 1 2 3 4 5 6 7 8 9 10 0.0 0.0' '10000 1 2 3 4 5 6 7 8 9 10 -5.5 8.2' > "$tc_dir/PIDX_thermo.chunk.dat"
tc_merge_chunk_outputs PIDX
printf '%s\n' '10000 1 2 3 4 5 6 7 8 9 10 -5.5 8.2' '20000 1 2 3 4 5 6 7 8 9 10 -12.0 15.0' > "$tc_dir/PIDX_thermo.chunk.dat"
tc_merge_chunk_outputs PIDX
n=$(grep -c '^10000' "$tc_dir/PIDX_thermo.dat")
echo "count_10000=$n"
[[ "$n" == "1" ]]
echo "10000 -5.5 8.2" > "$tc_dir/PIDX_tc_progress.dat"
state=$(tc_thermo_state PIDX)
echo "state=$state"
[[ "$state" == "10000 -5.5 8.2" ]]
touch "$tc_dir/PIDX_rstrt_3"
sleep 1
touch "$tc_dir/PIDX_rstrt_end"
rst=$(tc_pick_restart_file PIDX)
echo "rst=$rst"
[[ "$rst" == *rstrt_end ]]
tc_has_resume_artifacts PIDX
echo "PASS bash helpers"
rm -rf "$initial_dir"

echo "=== Integration: real TC.in 200 then resume 400 ==="
EQ2="$ADEPT/POLYMER_DATA_full/2/POLYMER_DATA/OPTIMIZATION/PID00002/PID00002_eq2.data"
if [[ ! -f "$EQ2" ]]; then
  echo "SKIP integration (no local eq2.data at $EQ2)"
  echo "ALL TESTS PASSED (helpers only)"
  exit 0
fi
TEST=$(mktemp -d)
mkdir -p "$TEST"/{2.Simulations,POLYMER_DATA/OPTIMIZATION/PID00002,POLYMER_DATA/THERMAL_CONDUCTIVITY/PID00002}
cp "$ADEPT/2.Simulations/lammps_TC.in" "$TEST/2.Simulations/"
cp "$EQ2" "$TEST/POLYMER_DATA/OPTIMIZATION/PID00002/"
cd "$TEST/POLYMER_DATA/THERMAL_CONDUCTIVITY/PID00002"
cat > PID00002_tally_offset.inc <<'EOF'
variable off4 equal 0.0
variable off5 equal 0.0
EOF

echo "[chunk1] fresh -> 200"
mpirun --oversubscribe --bind-to none -n 2 lmp -in ../../../2.Simulations/lammps_TC.in \
  -var name PID00002 -var resume 0 -var rstfile none -var run_upto 200 -var total_steps 400 \
  > chunk1.log 2>&1 || { echo "chunk1 failed"; tail -40 chunk1.log; exit 1; }
grep -E "TC_RUN|TC_DONE|ERROR" chunk1.log || true
[[ -f PID00002_rstrt_end ]]
[[ -f PID00002_tc_progress.dat ]]
cat PID00002_tc_progress.dat
OFF4=$(awk '{print $2}' PID00002_tc_progress.dat)
OFF5=$(awk '{print $3}' PID00002_tc_progress.dat)
STEP1=$(awk '{print $1+0}' PID00002_tc_progress.dat)
echo "after chunk1 step=$STEP1 off4=$OFF4 off5=$OFF5"
[[ "$STEP1" -ge 200 ]]

cat > PID00002_tally_offset.inc <<EOF
variable off4 equal ${OFF4}
variable off5 equal ${OFF5}
EOF
RST="$PWD/PID00002_rstrt_end"

echo "[chunk2] resume -> 400"
mpirun --oversubscribe --bind-to none -n 2 lmp -in ../../../2.Simulations/lammps_TC.in \
  -var name PID00002 -var resume 1 -var rstfile "$RST" -var run_upto 400 -var total_steps 400 \
  > chunk2.log 2>&1 || { echo "chunk2 failed"; tail -60 chunk2.log; exit 1; }
grep -E "Reading restart|TC_RUN|TC_DONE|ERROR" chunk2.log || true
STEP2=$(awk '{print $1+0}' PID00002_tc_progress.dat)
echo "after chunk2 step=$STEP2"
[[ "$STEP2" -ge 400 ]]
grep -q "Reading restart file" chunk2.log
grep -q "TC_DONE" chunk2.log
# Ensure we did not start over at step 0 in chunk2
grep -q "Current step  : 200" chunk2.log || grep -q "TC_RUN .* step=200" chunk2.log
echo "PASS real resume 200->400"
echo "ALL TESTS PASSED"
rm -rf "$TEST"
