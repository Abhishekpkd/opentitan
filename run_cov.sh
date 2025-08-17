#!/bin/bash

widths=(25 50 100 200 400 800 1600)

# --- 1) Run unmasked simulations ---
for W in "${widths[@]}"; do
  echo "== Unmasked Width=$W =="
  vsim -c -coverage work.tb_keccak_round_mask \
       -GWidth=$W -GDInWidth=64 -GEnMasking=0 \
       -do "coverage save -onexit Acov_${W}.ucdb; run -all; quit -f" \
  || echo "Unmasked sim failed for W=$W"
done

# --- 2) Run masked simulations (skip 25 and 50) ---
for W in "${widths[@]}"; do
  if [[ "$W" -gt 50 ]]; then
    echo "== Masked Width=$W =="
    vsim -c -coverage work.tb_keccak_round_mask \
         -GWidth=$W -GDInWidth=64 -GEnMasking=1 \
         -do "coverage save -onexit Acov_mask_${W}.ucdb; run -all; quit -f" \
    || echo "Masked sim failed for W=$W"
  fi
done

# --- 3) Merge all UCDB files ---
echo "Merging all UCDB files..."
vcover merge Acov_all.ucdb Acov_*.ucdb Acov_mask_*.ucdb

# --- 4) Generate coverage reports ---
echo "Generating text report..."

#vcover report -codeAll -cvg -assert -details -output Acov_report.txt Acov_all.ucdb
vcover report -details -code bcesft -assert -cvg -output Acov_report.txt Acov_all.ucdb

echo "Generating HTML report..."
#vcover report -codeAll -cvg -assert -html -output Acov_html Acov_all.ucdb
vcover report -details -code bcesft -assert -cvg -html -output Acov_html Acov_all.ucdb

echo "Done. Reports:"
echo "  Text:  Acov_report.txt"
echo "  HTML:  Acov_html/index.html"
