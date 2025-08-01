// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
module tb;
  // dep packages
  import uvm_pkg::*;
  import dv_utils_pkg::*;
  import sram_ctrl_pkg::*;
  import sram_ctrl_env_pkg::*;
  import sram_ctrl_test_pkg::*;
  import sram_ctrl_bkdr_util_pkg::sram_ctrl_bkdr_util;
  import top_racl_pkg::*;

  // macro includes
  `include "uvm_macros.svh"
  `include "dv_macros.svh"

  wire clk;
  wire rst_n;
  wire clk_otp;
  wire rst_otp_n;
  wire [NUM_MAX_INTERRUPTS-1:0] interrupts;
  // RACL:
  // Currently not used, but copying RTL's default value
  parameter int unsigned RaclPolicySelNumRangesRam = 1;
  racl_policy_vec_t racl_policies;
  assign racl_policies = 0; // Not currently used
  racl_range_t [RaclPolicySelNumRangesRam-1:0] racl_policy_sel_ranges_ram;
  // OTP key derivation interface
  otp_ctrl_pkg::sram_otp_key_req_t key_req;
  otp_ctrl_pkg::sram_otp_key_rsp_t key_rsp;

  otp_ctrl_pkg::sram_key_t   key;
  otp_ctrl_pkg::sram_nonce_t nonce;

  wire seed_valid;

  // interfaces
  clk_rst_if clk_rst_if(.clk(clk), .rst_n(rst_n));
  pins_if #(NUM_MAX_INTERRUPTS) intr_if(interrupts);
  clk_rst_if otp_clk_rst_if(.clk(clk_otp), .rst_n(rst_otp_n));

  // TLUL interface to the CSR regfile
  tl_if tl_if(.clk(clk), .rst_n(rst_n));

  // TLUL interface to the SRAM memory itself
  tl_if sram_tl_if(.clk(clk), .rst_n(rst_n));

  // KDI interface for the OTP<->SRAM connections
  push_pull_if #(.DeviceDataWidth(KDI_DATA_SIZE)) kdi_if(.clk(clk_otp), .rst_n(rst_otp_n));

  // Interface for lifecycle escalation
  sram_ctrl_lc_if lc_if();

  // Interface for SRAM execution
  sram_ctrl_exec_if exec_if();

  `DV_ALERT_IF_CONNECT()

  // DUT

  // The exact number of word address bits.
  // Will be set to 10 for retention SRAM and 14 for main SRAM.
`ifndef SRAM_WORD_ADDR_WIDTH
  `define SRAM_WORD_ADDR_WIDTH 32
`endif

  sram_ctrl #(
    // memory size in bytes
    .MemSizeRam(4 * 2 ** `SRAM_WORD_ADDR_WIDTH),
    .InstrExec(`INSTR_EXEC),
    // number of PRINCE half rounds for the SRAM scrambling feature
    .NumPrinceRoundsHalf(`NUM_PRINCE_ROUNDS_HALF)
  ) dut (
    // main clock
    .clk_i                        (clk                        ),
    .rst_ni                       (rst_n                      ),
    // OTP clock
    .clk_otp_i                    (clk_otp                    ),
    .rst_otp_ni                   (rst_otp_n                  ),
    // TLUL interface for CSR regfile
    .ram_tl_i                     (sram_tl_if.h2d             ),
    .ram_tl_o                     (sram_tl_if.d2h             ),
    // TLUL interface for CSR regfile
    .regs_tl_i                    (tl_if.h2d                  ),
    .regs_tl_o                    (tl_if.d2h                  ),
    // Alert I/O
    .alert_rx_i                   (alert_rx                   ),
    .alert_tx_o                   (alert_tx                   ),
    // RACL IF
    .racl_policies_i              (racl_policies              ),
    .racl_error_o                 (                           ),
    .racl_policy_sel_ranges_ram_i (racl_policy_sel_ranges_ram ),


    // Life cycle escalation
    .lc_escalate_en_i             (lc_if.lc_esc_en            ),
    // OTP key derivation interface
    .sram_otp_key_o               (key_req                    ),
    .sram_otp_key_i               (key_rsp                    ),
    // SRAM ifetch interface
    .lc_hw_debug_en_i             (exec_if.lc_hw_debug_en     ),
    .otp_en_sram_ifetch_i         (exec_if.otp_en_sram_ifetch ),
    // config
    .cfg_i                        ('0                         ),
    .cfg_rsp_o                    (                           ),
    // Error record
    .sram_rerror_o                (                           )
  );

  // KDI interface assignments
  assign kdi_if.req         = key_req.req;
  assign key_rsp.ack        = kdi_if.ack;
  assign key_rsp.key        = key;
  assign key_rsp.nonce      = nonce;
  assign key_rsp.seed_valid = seed_valid;
  // key, nonce, seed_valid all driven by push_pull Device interface
  assign {key, nonce, seed_valid} = kdi_if.d_data;

  // Instantiate the memory backdoor util instance.
  `define SRAM_CTRL_MEM_HIER \
    tb.dut.u_prim_ram_1p_scr.u_prim_ram_1p_adv.gen_ram_inst[0].u_mem.mem

  initial begin
    sram_ctrl_bkdr_util m_sram_ctrl_bkdr_util;
    m_sram_ctrl_bkdr_util = new(.name  ("sram_ctrl_bkdr_util"),
                           .path  (`DV_STRINGIFY(`SRAM_CTRL_MEM_HIER)),
                           .depth ($size(`SRAM_CTRL_MEM_HIER)),
                           .n_bits($bits(`SRAM_CTRL_MEM_HIER)),
                           // Due to the end-to-end bus integrity scheme, the memory primitive
                           // itself does not encode and decode the redundancy information.
                           .err_detection_scheme(mem_bkdr_util_pkg::ErrDetectionNone),
                           .num_prince_rounds_half(`NUM_PRINCE_ROUNDS_HALF));

    // drive clk and rst_n from clk_if
    clk_rst_if.set_active();
    otp_clk_rst_if.set_active();

    // set interfaces into uvm_config_db
    uvm_config_db#(virtual clk_rst_if)::set(null, "*.env", "clk_rst_vif", clk_rst_if);
    uvm_config_db#(virtual clk_rst_if)::set(
        null, "*.env", "clk_rst_vif_sram_ctrl_prim_reg_block", clk_rst_if);
    uvm_config_db#(virtual clk_rst_if)::set(null, "*.env", "otp_clk_rst_vif", otp_clk_rst_if);
    uvm_config_db#(intr_vif)::set(null, "*.env", "intr_vif", intr_if);
    uvm_config_db#(virtual push_pull_if#(.DeviceDataWidth(KDI_DATA_SIZE)))::set(null,
      "*.env.m_kdi_agent*", "vif", kdi_if);
    uvm_config_db#(virtual sram_ctrl_lc_if)::set(null, "*.env", "lc_vif", lc_if);
    uvm_config_db#(virtual sram_ctrl_exec_if)::set(null, "*.env", "exec_vif", exec_if);
    uvm_config_db#(virtual tl_if)::set(
        null, "*.env.m_tl_agent_sram_ctrl_regs_reg_block*", "vif", tl_if);
    uvm_config_db#(virtual tl_if)::set(
        null, "*.env.m_tl_agent_sram_ctrl_prim_reg_block*", "vif", sram_tl_if);
    uvm_config_db#(sram_ctrl_bkdr_util)::set(null, "*.env", "sram_ctrl_bkdr_util",
                                             m_sram_ctrl_bkdr_util);

    $timeformat(-12, 0, " ps", 12);
    run_test();
  end

  `undef SRAM_CTRL_MEM_HIER

endmodule
