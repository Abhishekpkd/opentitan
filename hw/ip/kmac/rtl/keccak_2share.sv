// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// This module is the single round keccak permutation module
// It supports Keccak with up to 1600b of state

`include "prim_assert.sv"

module keccak_2share
  import prim_mubi_pkg::*;
#(
  parameter int Width = 1600, // b= {25, 50, 100, 200, 400, 800, 1600}

  // Derived
  localparam int W        = Width/25,
  localparam int L        = $clog2(W),
  localparam int MaxRound = 12 + 2*L,           // Keccak-f only
  localparam int RndW     = $clog2(MaxRound+1), // Representing up to MaxRound

  // Control parameters
  parameter  bit EnMasking    = 1'b0, // Enable secure hardening
  parameter  bit ForceRandExt = 1'b0, // 1: Always forward externally provided randomness.
                                      // 0: Switch between external randomness and internal
                                      //    intermediate state according to dom_in_rand_ext_i.
  localparam int Share        = EnMasking ? 2 : 1
) (
  input clk_i,
  input rst_ni,

  input  lc_ctrl_pkg::lc_tx_t lc_escalate_en_i, // Used to disable SVAs when escalating.

  input [RndW-1:0] rnd_i, // Current round index

  // Control inputs used when EnMasking = 1.
  input mubi4_t phase_sel_i,       // Output mux control
  input         dom_out_low_i,     // DOM multiplier output mux
  input         dom_in_low_i,      // DOM multiplier input mux
  input         dom_in_rand_ext_i, // DOM multiplier input randomness mux
  input         dom_update_i,      // DOM multiplier pipeline reg write enable

  input      [Width/2-1:0] rand_i, // Randomness for remasking.

  // State input and output
  input        [Width-1:0] s_i [Share],
  output logic [Width-1:0] s_o [Share]
);
  ///////////
  // Types //
  ///////////
  //             x    y    z
  typedef logic [4:0][4:0][W-1:0] box_t;   // (x,y,z) state
  typedef logic           [W-1:0] lane_t;  // (z)
  typedef logic [4:0]     [W-1:0] plane_t; // (x,z)
  typedef logic [4:0][4:0]        slice_t; // (x,y)
  typedef logic      [4:0][W-1:0] sheet_t; // (y,z) identical to plane_t
  typedef logic [4:0]             row_t;   // (x)
  typedef logic      [4:0]        col_t;   // (y) identical to row_t

  //////////////
  // Keccak_f //
  //////////////
  box_t state_in   [Share];
  box_t state_out  [Share];
  box_t theta_data [Share];
  box_t rho_data   [Share];
  box_t pi_data    [Share];
  box_t chi_data   [Share];
  box_t iota_data  [Share];

  box_t phase1_in  [Share];
  box_t phase1_out [Share];
  box_t phase2_in  [Share];
  box_t phase2_out [Share];

  /////////////////
  // Unused nets //
  /////////////////
  // Tie off input signals that aren't used in the unmasked implementation.
  if (!EnMasking) begin : gen_tie_unused
    logic unused_clk;
    logic unused_rst_n;
    mubi4_t unused_phase_sel;
    logic unused_dom_ctrl;
    logic [Width/2-1:0] unused_rand;
    assign unused_clk = clk_i;
    assign unused_rst_n = rst_ni;
    assign unused_phase_sel = phase_sel_i;
    assign unused_dom_ctrl =
        ^{dom_out_low_i, dom_in_low_i, dom_in_rand_ext_i, dom_update_i};
    assign unused_rand = rand_i;
  end

  //////////////////////////////////////////////////
  // Input/output type conversion and interfacing //
  //////////////////////////////////////////////////
  for (genvar i = 0 ; i < Share ; i++) begin : g_state_inout
    assign state_in[i] = bitarray_to_box(s_i[i]);
    assign s_o[i]      = box_to_bitarray(state_out[i]);
  end : g_state_inout

  if (EnMasking) begin : g_2share_data
    assign phase1_in = state_in;
    assign phase2_in = state_in;

    always_comb begin
      unique case (phase_sel_i)
        MuBi4False: state_out = phase1_out;
        MuBi4True:  state_out = phase2_out;
        default:    state_out = phase1_out;
      endcase
    end
  end else begin : g_single_data
    assign phase1_in = state_in;
    assign phase2_in = phase1_out;
    assign state_out = phase2_out;
  end

  //////////////
  // Datapath //
  //////////////
  for (genvar i = 0 ; i < Share ; i++) begin : g_datapath

    // Phase 1:
    assign theta_data[i] = theta(phase1_in[i]);
    // Commented out rho function as vcs complains z-Offset%W isn't constant
    // assign rho_data[i]   = rho(theta_data[i]);

    assign pi_data[i]    = pi(rho_data[i]);

    // Phase 2 (Cycles 1, 2 and 3):
    // Chi : See below
    // Iota: See below
  end : g_datapath

  assign phase1_out = pi_data;

  // Iota adds Round Constants(RC), so only one share should be XORed
  if (EnMasking) begin : g_2share_iota
    assign iota_data[0]  = iota(chi_data[0], rnd_i);
    assign iota_data[1]  = chi_data[1];
  end else begin : g_single_iota
    assign iota_data[0]  = iota(chi_data[0], rnd_i);
  end

  if (EnMasking) begin : g_2share_chi
    // Domain-Oriented Masking
    // reference: https://eprint.iacr.org/2017/395.pdf

    localparam int unsigned WSheetHalf = $bits(sheet_t)/2;
    logic [4:0][WSheetHalf-1:0] in_prd, out_prd;

    /////////////////////
    // DOM multipliers //
    /////////////////////

    for (genvar x = 0 ; x < 5 ; x++) begin : g_chi_w
      localparam int X1 = (x + 1) % 5;
      localparam int X2 = (x + 2) % 5;

      sheet_t sheet0[Share]; // Inverted input X1
      sheet_t sheet1[Share]; // X2
      sheet_t sheet2[Share]; // DOM output

      assign sheet0[0] = ~phase2_in[0][X1];
      assign sheet0[1] = phase2_in[1][X1];

      assign sheet1[0] = phase2_in[0][X2];
      assign sheet1[1] = phase2_in[1][X2];

      // Convert sheet_t to 1D arrays, one for the upper and lower half lane.
      logic [WSheetHalf-1:0] a0_l, a1_l, b0_l, b1_l;
      logic [WSheetHalf-1:0] a0_h, a1_h, b0_h, b1_h;
      logic [WSheetHalf-1:0] a0, a1, b0, b1, q0, q1;

      assign a0_l = {sheet0[0][0][W/2-1:0],
                     sheet0[0][1][W/2-1:0],
                     sheet0[0][2][W/2-1:0],
                     sheet0[0][3][W/2-1:0],
                     sheet0[0][4][W/2-1:0]};
      assign a1_l = {sheet0[1][0][W/2-1:0],
                     sheet0[1][1][W/2-1:0],
                     sheet0[1][2][W/2-1:0],
                     sheet0[1][3][W/2-1:0],
                     sheet0[1][4][W/2-1:0]};

      assign a0_h = {sheet0[0][0][W-1:W/2],
                     sheet0[0][1][W-1:W/2],
                     sheet0[0][2][W-1:W/2],
                     sheet0[0][3][W-1:W/2],
                     sheet0[0][4][W-1:W/2]};
      assign a1_h = {sheet0[1][0][W-1:W/2],
                     sheet0[1][1][W-1:W/2],
                     sheet0[1][2][W-1:W/2],
                     sheet0[1][3][W-1:W/2],
                     sheet0[1][4][W-1:W/2]};

      assign b0_l = {sheet1[0][0][W/2-1:0],
                     sheet1[0][1][W/2-1:0],
                     sheet1[0][2][W/2-1:0],
                     sheet1[0][3][W/2-1:0],
                     sheet1[0][4][W/2-1:0]};
      assign b1_l = {sheet1[1][0][W/2-1:0],
                     sheet1[1][1][W/2-1:0],
                     sheet1[1][2][W/2-1:0],
                     sheet1[1][3][W/2-1:0],
                     sheet1[1][4][W/2-1:0]};

      assign b0_h = {sheet1[0][0][W-1:W/2],
                     sheet1[0][1][W-1:W/2],
                     sheet1[0][2][W-1:W/2],
                     sheet1[0][3][W-1:W/2],
                     sheet1[0][4][W-1:W/2]};
      assign b1_h = {sheet1[1][0][W-1:W/2],
                     sheet1[1][1][W-1:W/2],
                     sheet1[1][2][W-1:W/2],
                     sheet1[1][3][W-1:W/2],
                     sheet1[1][4][W-1:W/2]};

      // Input muxing
      assign a0 = dom_in_low_i ? a0_l : a0_h;
      assign a1 = dom_in_low_i ? a1_l : a1_h;
      assign b0 = dom_in_low_i ? b0_l : b0_h;
      assign b1 = dom_in_low_i ? b1_l : b1_h;

      // Randomness muxing
      if (!ForceRandExt) begin : gen_in_prd_mux
        // Intermediate results are rotated across rows. The new Row x depends on
        // data from Rows x + 1 and x + 2. Hence we don't want to use intermediate
        // results from Rows x, x + 1, and x + 2 for remasking.
        assign in_prd[x] = dom_in_rand_ext_i ? rand_i[x * WSheetHalf +: WSheetHalf] :
                                               out_prd[rot_int(x, 5)];
      end else begin : gen_no_in_prd_mux
        // Always use the externally provided randomness.
        assign in_prd[x] = rand_i[x * WSheetHalf +: WSheetHalf];
        // Tie off unused signals.
        logic unused_out_prd;
        assign unused_out_prd = ^{dom_in_rand_ext_i, out_prd[rot_int(x, 5)]};
      end

      prim_dom_and_2share #(
        .DW (WSheetHalf), // a half sheet
        .Pipeline(1) // Process the full sheet in 3 clock cycles. This reduces
                     // SCA leakage.
      ) u_dom (
        .clk_i,
        .rst_ni,

        .a0_i      (a0),
        .a1_i      (a1),
        .b0_i      (b0),
        .b1_i      (b1),
        .z_valid_i (dom_update_i),
        .z_i       (in_prd[x]),
        .q0_o      (q0),
        .q1_o      (q1),
        .prd_o     (out_prd[x])
      );

      // Output conversion from q0, q1 to sheet_t
      // For simplicity, we forward the generated lane half to both the upper
      // and lower lane halves at this point. The actual output muxing/selection
      // happens after the Iota step when generating phase2_out from iota_data
      // and state_in below.
      assign sheet2[0][4] = {2{q0[W/2*0+:W/2]}};
      assign sheet2[0][3] = {2{q0[W/2*1+:W/2]}};
      assign sheet2[0][2] = {2{q0[W/2*2+:W/2]}};
      assign sheet2[0][1] = {2{q0[W/2*3+:W/2]}};
      assign sheet2[0][0] = {2{q0[W/2*4+:W/2]}};

      assign sheet2[1][4] = {2{q1[W/2*0+:W/2]}};
      assign sheet2[1][3] = {2{q1[W/2*1+:W/2]}};
      assign sheet2[1][2] = {2{q1[W/2*2+:W/2]}};
      assign sheet2[1][1] = {2{q1[W/2*3+:W/2]}};
      assign sheet2[1][0] = {2{q1[W/2*4+:W/2]}};

      // Final XOR to generate the output
      assign chi_data[0][x] = sheet2[0] ^ phase2_in[0][x];
      assign chi_data[1][x] = sheet2[1] ^ phase2_in[1][x];
    end : g_chi_w

    // Since Chi and thus Iota are separately applied to the lower and upper half
    // lanes, we need to forward the input to the other half.
    for (genvar x = 0 ; x < 5 ; x++) begin : g_2share_phase2_out_row
      for (genvar y = 0 ; y < 5 ; y++) begin : g_2share_phase2_out_col
        assign phase2_out[0][x][y] = dom_out_low_i ?
            { state_in[0][x][y][W-1:W/2], iota_data[0][x][y][W/2-1:0]} :
            {iota_data[0][x][y][W-1:W/2],  state_in[0][x][y][W/2-1:0]};
        assign phase2_out[1][x][y] = dom_out_low_i ?
            { state_in[1][x][y][W-1:W/2], iota_data[1][x][y][W/2-1:0]} :
            {iota_data[1][x][y][W-1:W/2],  state_in[1][x][y][W/2-1:0]};
      end
    end

  end else begin : g_single_chi
    assign chi_data[0] = chi(phase2_in[0]);
    assign phase2_out = iota_data;
  end

  // Rho ======================================================================
  // As RhoOffset[x][y] is considered as variable int in VCS,
  // it is replaced with generate statement.
  // Revised to meet verilator lint. Now RhoOffset is 1-D array
  localparam int RhoOffset [25]  = '{
    //y  0    1    2    3    4     x
         0,  36,   3, 105, 210, // 0:  0  1  2  3  4
         1, 300,  10,  45,  66, // 1:  5  6  7  8  9
       190,   6, 171,  15, 253, // 2: 10 11 12 13 14
        28,  55, 153,  21, 120, // 3: 15 16 17 18 19
        91, 276, 231, 136,  78  // 4: 20 21 22 23 24
  };
  for (genvar i = 0 ; i < Share ; i++) begin : g_rho
    box_t rho_in, rho_out;
    assign rho_in = theta_data[i];
    assign rho_data[i] = rho_out;

    for (genvar x = 0 ; x < 5 ; x++) begin : gen_rho_x
      for (genvar y = 0 ; y < 5 ; y++) begin : gen_rho_y
        localparam int Offset = RhoOffset[5*x+y]%W;
        localparam int ShiftAmt = W- Offset;
        if (Offset == 0) begin : gen_offset0
          assign rho_out[x][y][W-1:0] = rho_in[x][y][W-1:0];
        end else begin : gen_others
          assign rho_out[x][y][W-1:0] = {rho_in[x][y][0+:ShiftAmt],
                                         rho_in[x][y][ShiftAmt+:Offset]};
        end
      end
    end
  end : g_rho

  ////////////////
  // Assertions //
  ////////////////

  `ASSERT_INIT(ValidWidth_A,
      EnMasking == 0 && Width inside {25, 50, 100, 200, 400, 800, 1600} ||
      EnMasking == 1 && Width inside {50, 100, 200, 400, 800, 1600})
  `ASSERT_INIT(ValidW_A, W inside {1, 2, 4, 8, 16, 32, 64})
  `ASSERT_INIT(ValidL_A, L inside {0, 1, 2, 3, 4, 5, 6})
  `ASSERT_INIT(ValidRound_A, MaxRound <= 24) // Keccak-f only

  // phase_sel_i shall stay for two cycle after change to 1.
  lc_ctrl_pkg::lc_tx_t unused_lc_sig;
  assign unused_lc_sig = lc_escalate_en_i;
  if (EnMasking) begin : gen_selperiod_chk
    `ASSUME(SelStayTwoCycleIfTrue_A,
        ($past(phase_sel_i) == MuBi4False) && (phase_sel_i == MuBi4True)
        |=> phase_sel_i == MuBi4True, clk_i, !rst_ni ||
            lc_ctrl_pkg::lc_tx_test_true_loose(lc_escalate_en_i))
  end

  ///////////////
  // Functions //
  ///////////////

  // Convert bitarray to 3D box
  // Please take a look at FIPS PUB 202
  // https://nvlpubs.nist.gov/nistpubs/FIPS/NIST.FIPS.202.pdf
  // > For all triples (x,y,z) such that 0<=x<5, 0<=y<5, and 0<=z<w,
  // >    A[x,y,z]=S[w(5y+x)+z]
  function automatic box_t bitarray_to_box(logic [Width-1:0] s_in);
    automatic box_t box;
    for (int y = 0 ; y < 5 ; y++) begin
      for (int x = 0 ; x < 5 ; x++) begin
        for (int z = 0 ; z < W ; z++) begin
          box[x][y][z] = s_in[W*(5*y+x) + z];
        end
      end
    end
    return box;
  endfunction : bitarray_to_box

  // Convert 3D cube to bitarray
  function automatic logic [Width-1:0] box_to_bitarray(box_t state);
    automatic logic [Width-1:0] bitarray;
    for (int y = 0 ; y < 5 ; y++) begin
      for (int x = 0 ; x < 5 ; x++) begin
        for (int z = 0 ; z < W ; z++) begin
          bitarray[W*(5*y+x)+z] = state[x][y][z];
        end
      end
    end
    return bitarray;
  endfunction : box_to_bitarray

  // Rotate integer indices
  function automatic integer rot_int(integer in, integer num);
    integer out;
    if (in == 0) begin
      out = num - 1;
    end else begin
      out = in - 1;
    end
    return out;
  endfunction

  // Step Mapping =============================================================
  // theta
  // XOR each bit in the state with the parity of two columns
  // C[x,z] = A[x,0,z] ^ A[x,1,z] ^ A[x,2,z] ^ A[x,3,z] ^ A[x,4,z]
  // D[x,z] = C[x-1,z] ^ C[x+1,z-1]
  // theta = A[x,y,z] ^ D[x,z]
  localparam int ThetaIndexX1 [5] = '{4, 0, 1, 2, 3}; // (x-1)%5
  localparam int ThetaIndexX2 [5] = '{1, 2, 3, 4, 0}; // (x+1)%5
  function automatic box_t theta(box_t state);
    plane_t c;
    plane_t d;
    box_t result;
    for (int x = 0 ; x < 5 ; x++) begin
      c[x] = state[x][0] ^ state[x][1] ^ state[x][2] ^ state[x][3] ^ state[x][4];
    end
    for (int x = 0 ; x < 5 ; x++) begin
      for (int z = 0 ; z < W ; z++) begin
        int index_z;
        index_z = (z == 0) ? W-1 : z-1; // (z+1)%W
        d[x][z] = c[ThetaIndexX1[x]][z] ^ c[ThetaIndexX2[x]][index_z];
      end
    end
    for (int x = 0 ; x < 5 ; x++) begin
      for (int y = 0 ; y < 5 ; y++) begin
        result[x][y] = state[x][y] ^ d[x];
      end
    end
    return result;
  endfunction : theta

  // rho

  // Commented out entire rho function due to VCS elaboration error.
  // (z-RhoOffset[x][y]%W) isn't considered as a constant in VCS.
  // Even changing it to W-RhoOffset[x][y]%W and assign to ShiftAmt
  // creates same error.

  // Offset : Look at Table 2 in FIPS PUB 202
  //localparam int RhoOffset [5][5]  = '{
  //  //y  0    1    2    3    4     x
  //  '{   0,  36,   3, 105, 210},// 0
  //  '{   1, 300,  10,  45,  66},// 1
  //  '{ 190,   6, 171,  15, 253},// 2
  //  '{  28,  55, 153,  21, 120},// 3
  //  '{  91, 276, 231, 136,  78} // 4
  //};

  // rotate bits of each lane by offset
  // 1. rho[0,0,z] = A[0,0,z]
  // 2. Offset swap
  //    a. (x,y) := (1,0)
  //    b. for t [0..23]
  //       i. rho[x,y,z] = A[x,y,z-(t+1)(t+2)/2]
  //       ii. (x,y) = (y, (2x+3y))
  //function automatic box_t rho(box_t state);
  //  box_t result;
  //  for (int x = 0 ; x < 5 ; x++) begin
  //    for (int y = 0 ; y < 5 ; y++) begin
  //      for (int z = 0 ; z < W ; z++) begin
  //        automatic int index_z;
  //        index_z = (z-RhoOffset[x][y])%W;
  //        result[x][y][z] = state[x][y][(z-RhoOffset[x][y])%W];
  //      end
  //    end
  //  end
  //  return result;
  //endfunction : rho

  // pi
  // rearrange the position of lanes
  // pi[x,y,z] = state[(x+3y),x,z]
  localparam int PiRotate [5][5] = '{
    //y  0    1    2    3    4     x
    '{   0,   3,   1,   4,   2},// 0
    '{   1,   4,   2,   0,   3},// 1
    '{   2,   0,   3,   1,   4},// 2
    '{   3,   1,   4,   2,   0},// 3
    '{   4,   2,   0,   3,   1} // 4
  };
  function automatic box_t pi(box_t state);
    box_t result;
    for (int x = 0 ; x < 5 ; x++) begin
      for (int y = 0 ; y < 5 ; y++) begin
        result[x][y][W-1:0] = state[PiRotate[x][y]][x][W-1:0];
      end
    end
    return result;
  endfunction : pi

  // chi
  // chi[x,y,z] = state[x,y,z] ^ ((state[x+1,y,z] ^ 1) & state[x+2,y,z])
  localparam int ChiIndexX1 [5] = '{1, 2, 3, 4, 0}; // (x+1)%5
  localparam int ChiIndexX2 [5] = '{2, 3, 4, 0, 1}; // (x+2)%5
  function automatic box_t chi(box_t state);
    box_t result;
    for (int x = 0 ; x < 5 ; x++) begin
      result[x] = state[x] ^ ((~state[ChiIndexX1[x]]) & state[ChiIndexX2[x]]);
    end
    return result;
  endfunction : chi

  // iota
  // XOR (x,y) = (0,0) with Round Constant (RC)

  // RC parameter: Precomputed by util/keccak_rc.py. Only up-to 0..L-1 is used
  // RC = '0
  // RC[2**j-1] = rc(j+7*rnd)
  // rc(t) =
  //    1. t%255 == 0 -> 1
  //    2. R[0:7] = 'b10000000
  //    3. for i = [1..t%255]
  //      a. R = 0 || R
  //      b. R[0] = R[0] ^ R[8]
  //      c. R[4] = R[4] ^ R[8]
  //      d. R[5] = R[5] ^ R[8]
  //      e. R[6] = R[6] ^ R[8]
  //      f. R = R[0:7]
  //    4. return R[0]
  // RC has L = [0..6]
  // for lower L case, only chopping lower part of 64bit RC is sufficient.
  localparam logic [63:0] RC [24] = '{
     64'h 0000_0000_0000_0001, // Round 0
     64'h 0000_0000_0000_8082, // Round 1
     64'h 8000_0000_0000_808A, // Round 2
     64'h 8000_0000_8000_8000, // Round 3
     64'h 0000_0000_0000_808B, // Round 4
     64'h 0000_0000_8000_0001, // Round 5
     64'h 8000_0000_8000_8081, // Round 6
     64'h 8000_0000_0000_8009, // Round 7
     64'h 0000_0000_0000_008A, // Round 8
     64'h 0000_0000_0000_0088, // Round 9
     64'h 0000_0000_8000_8009, // Round 10
     64'h 0000_0000_8000_000A, // Round 11
     64'h 0000_0000_8000_808B, // Round 12
     64'h 8000_0000_0000_008B, // Round 13
     64'h 8000_0000_0000_8089, // Round 14
     64'h 8000_0000_0000_8003, // Round 15
     64'h 8000_0000_0000_8002, // Round 16
     64'h 8000_0000_0000_0080, // Round 17
     64'h 0000_0000_0000_800A, // Round 18
     64'h 8000_0000_8000_000A, // Round 19
     64'h 8000_0000_8000_8081, // Round 20
     64'h 8000_0000_0000_8080, // Round 21
     64'h 0000_0000_8000_0001, // Round 22
     64'h 8000_0000_8000_8008  // Round 23
  };

  // iota: XOR with RC for (x,y) = (0,0)
  function automatic box_t iota(box_t state, logic [RndW-1:0] rnd);
    box_t result;
    result = state;
    result[0][0][W-1:0] = state[0][0][W-1:0] ^ RC[rnd][W-1:0];

    return result;
  endfunction : iota

  // Round function : Rnd(A,i_r)
  // Not used due to rho function issue described above.

  //function automatic box_t keccak_rnd(box_t state, logic [RndW-1:0] rnd);
  //  box_t keccak_state;
  //  keccak_state = iota(chi(pi(rho(theta(state)))), rnd);
  //
  //  return keccak_state;
  //endfunction : keccak_rnd

endmodule
