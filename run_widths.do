transcript on
vdel -all
vlib work
vmap work work
vlog -sv +acc +cover=bcesft \
  hw/ip/prim/rtl/prim_pkg.sv \
  hw/ip/prim/rtl/prim_util_pkg.sv \
  hw/ip/prim/rtl/prim_mubi_pkg.sv \
  hw/ip/lc_ctrl/rtl/lc_ctrl_state_pkg.sv \
  hw/ip/lc_ctrl/rtl/lc_ctrl_reg_pkg.sv \
  hw/ip/lc_ctrl/rtl/lc_ctrl_pkg.sv \
  hw/ip/prim/rtl/prim_assert.sv \
  hw/ip/prim/rtl/prim_flop_macros.sv \
  hw/ip/prim/rtl/prim_flop.sv \
  hw/ip/prim/rtl/prim_buf.sv \
  hw/ip/prim/rtl/prim_sparse_fsm_flop.sv \
  hw/ip/prim/rtl/prim_sec_anchor_buf.sv \
  hw/ip/kmac/rtl/sha3_pkg.sv \
  hw/ip/kmac/rtl/keccak_round.sv \
  hw/ip/kmac/rtl/keccak_2share.sv \
  hw/ip/prim/rtl/prim_count_pkg.sv \
  hw/ip/prim/rtl/prim_count.sv \
  hw/ip/kmac/dv/unit_tb_keccak_round/tb_keccak_round_mask.sv

set widths {25 50 100 200 400 800 1600}
foreach W $widths {
  echo "== Running Width=$W =="
  vsim -c -coverage work.tb_keccak_round_mask -GWidth=$W -GDInWidth=64 \
       -do "run -all; coverage save cov_$W.ucdb; quit -f"
}
vcover merge cov_all.ucdb cov_25.ucdb cov_50.ucdb cov_100.ucdb cov_200.ucdb cov_400.ucdb cov_800.ucdb
vcover report -details -code bcesft cov_all.ucdb > cov_all.txt
quit -f

