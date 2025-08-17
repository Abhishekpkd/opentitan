#!/bin/bash
# run_all_cov.sh
# Assumes you've already compiled with +cover=bcesft and the same defines/incdirs.

widths=(25 50 100 200 400 800 1600)

# Clean old UCDBs (optional)
rm -f cov_*.ucdb cov_all.ucdb

# Helper to run a sweep
run_sweep() {
  local masking=$1   # 0 = unmasked, 1 = masked
  local mode=$2      # "idle" or "one"
  local plusarg=""
  [[ "$mode" == "one" ]] && plusarg="+DO_ONE_ROUND"

  for W in "${widths[@]}"; do
    # Skip masked W<=50 (known design issue for those params)
    if [[ "$masking" -eq 1 && "$W" -le 50 ]]; then
      echo ">> Skipping masked W=$W"
      continue
    fi

    echo "== $([ "$masking" -eq 1 ] && echo Masked || echo Unmasked) $mode : W=$W =="
    vsim -c -coverage work.tb_keccak_round_mask \
         -GWidth=$W -GDInWidth=64 -GEnMasking=$masking \
         $plusarg \
         -do "coverage save -onexit cov_${masking}_${mode}_${W}.ucdb; run -all; quit -f" \
    || echo "Sim failed: mask=$masking mode=$mode W=$W"
  done
}

# 1) Unmasked idle & one-round
run_sweep 0 idle
run_sweep 0 one

# 2) Masked idle & one-round (25/50 skipped)
run_sweep 1 idle
run_sweep 1 one

# 3) Merge everything
shopt -s nullglob
files=(cov_*.ucdb)
if ((${#files[@]}==0)); then
  echo "No UCDBs found, nothing to merge"; exit 1
fi

echo "Merging ${#files[@]} UCDBs..."
# Suppress object-type mismatch noise between param variants
vcover -suppress 6821 merge cov_all.ucdb "${files[@]}"

# 4) Reports
vcover report -details -code bcesft -assert -cvg -output cov_report.txt cov_all.ucdb
vcover report -details -code bcesft -assert -cvg -html -output cov_html cov_all.ucdb

echo "Done."
echo "  Text report : cov_report.txt"
echo "  HTML report : cov_html/index.html"
