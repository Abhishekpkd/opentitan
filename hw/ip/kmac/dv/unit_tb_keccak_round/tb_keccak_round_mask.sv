// tb_keccak_round_mask.sv
`timescale 1ns/1ps

module tb_keccak_round_mask #(
  parameter int Width    = 800,
  //parameter int DInWidth = 64,
  parameter bit EnMasking = 1'b0   // <— NEW
);

  // -------- Parameters to hit partial last chunk --------
  //localparam int Width    = 800;
  localparam int DInWidth = 64;
 
  //localparam int Share = (EnMasking && (Width != 25 && Width != 50)) ? 2 : 1;
  localparam int Share = EnMasking ? 2 : 1;     // <— NEW
  localparam int DInEntry = (Width + DInWidth - 1) / DInWidth; // 13
  localparam int LastAddr = DInEntry - 1;                       // 12
  localparam int LastBits = Width - (LastAddr * DInWidth);      // 32
  //localparam int Share    = 1; // EnMasking=0 → one share

  // ---------------- Clock / Reset ----------------
  logic clk_i   = 1'b0;
  logic rst_ni  = 1'b0;

  initial begin
    clk_i = 0;
    forever #5 clk_i = ~clk_i; // 100 MHz
  end

  task automatic apply_reset();
    rst_ni = 0;
    repeat (5) @(posedge clk_i);
    rst_ni = 1;
    repeat (2) @(posedge clk_i);
  endtask

  // ---------------- DUT I/O (write path) ----------------
  logic                valid_i = 1'b0;
  logic [ $clog2(DInEntry)-1:0 ] addr_i = '0;
  logic [DInWidth-1:0] data_i [Share];
  initial for (int s = 0; s < Share; s++) data_i[s] = '0;
  wire                 ready_o;

  // ---------------- Tie-offs for unused ports ----------------
  logic run_i = 1'b0;
  logic rand_valid_i = 1'b0; 
  logic rand_early_i = 1'b0;
  logic rand_aux_i   = 1'b0;
  logic [Width/2-1:0] rand_data_i = '0;
  logic rand_update_o, rand_consumed_o;
  logic complete_o;

  
  lc_ctrl_pkg::lc_tx_t lc_escalate_en_i = lc_ctrl_pkg::Off;    //dont modify




  // clear_i must be MuBi false
  prim_mubi_pkg::mubi4_t clear_i = prim_mubi_pkg::MuBi4False;

  // state observation (black-box from output, no hierarchy peek)
  wire [Width-1:0] state_o [Share];

  // ---------------- DUT ----------------
  keccak_round #(
    .Width(Width),
    .DInWidth(DInWidth),
    .EnMasking(EnMasking)   // <— was 1'b0
  ) dut (
    .clk_i,
    .rst_ni,

    .valid_i,
    .addr_i,
    .data_i,
    .ready_o,

    .run_i           (run_i),
    .rand_valid_i    (rand_valid_i),
    .rand_early_i    (rand_early_i),
    .rand_data_i     (rand_data_i),
    .rand_aux_i      (rand_aux_i),
    .rand_update_o   (rand_update_o),
    .rand_consumed_o (rand_consumed_o),

    .complete_o      (complete_o),

    .state_o         (state_o),

    .lc_escalate_en_i(lc_escalate_en_i),

    .sparse_fsm_error_o(),
    .round_count_error_o(),
    .rst_storage_error_o(),

    .clear_i         (clear_i)
  );

  // Lane extractor from state_o port (no hierarchy)
  function automatic logic [63:0] lane64(input int a);
  int start = a * DInWidth;
  logic [63:0] tmp = '0;
  // copy up to 64 bits that are still within Width; zero-pad the rest
  for (int i = 0; i < DInWidth; i++) begin
    if (start + i < Width) begin
      tmp[i] = state_o[0][start + i];
    end
  end
  return tmp;
endfunction


// Disable the "AssertConnected_A" check inside prim_sparse_fsm_flop
defparam dut.u_state_regs.EnableAlertTriggerSVA = 1'b0; // to remove assertion error prim_sparse_fsm_flop
defparam dut.u_round_count.EnableAlertTriggerSVA = 1'b0; // prim_count


 /* // ---------------- Simple write task with ready/valid ----------------
  task automatic write_chunk(input int a, input logic [63:0] wdata);
    // Wait until DUT is idle/ready (KeccakStIdle → ready_o==1)
    @(posedge clk_i);
    //wait (ready_o == 1'b1);  //error as verilator not supporting
    // poll ready_o on clock edges
    while (ready_o !== 1'b1) @(posedge clk_i);
    // Pulse valid for one cycle
    addr_i  = a[ $bits(addr_i)-1:0 ];
    data_i[0] = wdata;
    valid_i = 1'b1;
    @(posedge clk_i);
    valid_i = 1'b0;
  endtask  */  

 /* task automatic wait_ready();
  // wait for a clean rising-edge sample where ready is 1,
  // then confirm it's still 1 on the next edge
  do @(posedge clk_i); while (ready_o !== 1'b1);
  @(posedge clk_i);
  if (ready_o !== 1'b1) wait_ready(); // rare, but avoids race
endtask */

//Trying simpler wait_ready()

  task automatic wait_ready();
  @(posedge clk_i); // sample after a clean edge
  while (ready_o !== 1'b1) @(posedge clk_i);
endtask


  task automatic write_chunk(input int a, input logic [63:0] wdata);
    wait_ready();
    addr_i     = a[$bits(addr_i)-1:0];
    data_i[0]  = wdata;
    valid_i    = 1'b1;
    @(posedge clk_i);
    valid_i    = 1'b0;
endtask

function automatic logic [63:0] mask64(input int bits);
  if (bits <= 0)       return 64'h0;
  else if (bits >= 64) return 64'hFFFF_FFFF_FFFF_FFFF;
  else                 return (64'h1 << bits) - 1;
endfunction


  initial run_i = 1'b0; // and never assert it in this TB

  // Optional one-round kick using a plusarg
initial begin
  if ($test$plusargs("DO_ONE_ROUND")) begin
    $display("[%0t] TB: +DO_ONE_ROUND set — pulsing run_i once", $time);
    repeat (2) @(posedge clk_i);
    run_i <= 1'b1;
    @(posedge clk_i);
    run_i <= 1'b0;
    repeat (4) @(posedge clk_i);
  end
end


  // ---------------- Test Sequence ----------------
  initial begin

    int a;
    logic [63:0] before_last, last_write, after_last;
    //logic [31:0] before_hi, before_lo, after_hi, after_lo, exp_lo;
    logic [63:0] mask, expected;

    // Defaults
    valid_i      = 1'b0;
    addr_i       = '0;
    data_i[0]    = '0;

    run_i = 0;
    rand_valid_i = 0;
    rand_early_i = 0;
    rand_aux_i   = 0;
    rand_data_i  = '0;

    apply_reset();

    @(posedge clk_i);
    $display("[%0t] ready_o=%b, keccak_st=%0d", $time, ready_o, dut.keccak_st);
    assert (ready_o === 1'b1)
      else $fatal(1, "ready_o not high after reset; keccak_st=%0d", dut.keccak_st);

    repeat (2) @(posedge clk_i); // settle into Idle

    // Kick the DUT so ready_o will go high.
    //run_i = 1'b1;
    //@(posedge clk_i);
    //run_i = 1'b0;  // or keep it 1'b1 for the whole test — both work for this TB


    // 1) Prime addresses 0..11 with distinct data (any pattern)
    for ( a = 0; a < LastAddr; a++) begin
      write_chunk(a, 64'hA5A5_0000_0000_0000 ^ (64'(a) << 8));
    end

    // Snapshot last lane BEFORE partial write
    @(posedge clk_i);
    before_last = lane64(LastAddr);

    // 2) Final write at addr=12 with all 1s (lights both halves)
    last_write = 64'hFFFF_FFFF_FFFF_FFFF;
    write_chunk(LastAddr, last_write);

    // Observe AFTER
    @(posedge clk_i);
    after_last  = lane64(LastAddr);
  // -----------------------
       //ONLY 32 BIT SPLIT
  //------------------------
    /* // Split into halves
    before_hi = before_last[63:32];
    before_lo = before_last[31:0];
    after_hi  = after_last[63:32];
    after_lo  = after_last[31:0];

    // Expectations for LastBits=32:
    // Only low 32b should change for Width=800 (LastBits=32)
    exp_lo = before_lo ^ last_write[31:0];


    // Upper 32b must be unchanged
    assert(after_hi == before_hi)
    else $fatal(1, "MASK FAIL: Upper 32 bits changed on partial write (before=%08x after=%08x)",
                before_hi, after_hi);

    // Lower 32b must be XOR of previous with data_lo (all 1s → bitwise invert)
    //exp_lo = before_lo ^ last_write[31:0]; //old
    assert(after_lo == exp_lo)
    else $fatal(1, "XOR FAIL: Lower 32 bits not XOR'ed as expected (before=%08x data_lo=%08x after=%08x exp=%08x)",
                before_lo, last_write[31:0], after_lo, exp_lo);

      assert(a >= 0 && a< DInEntry)
      else $fatal(1,"VALUE OF a OUTSIDE RANGE");

    $display("PASS: Partial-chunk mask OK. Upper32 stable, Lower32 XORed.");   */
    
    // Masked expectation: only LastBits are affected by XOR
    mask     = mask64(LastBits);
    expected = ((before_last ^ last_write) & mask) |
             ( before_last              & ~mask);

    assert (after_last == expected)
    else $fatal(1,
      "PARTIAL XOR FAIL: Width=%0d LastBits=%0d before=%016h data=%016h after=%016h exp=%016h mask=%016h",
      Width, LastBits, before_last, last_write, after_last, expected, mask);

    $display("PASS: Partial-chunk mask OK. Width=%0d DInWidth=%0d LastAddr=%0d LastBits=%0d",
           Width, DInWidth, LastAddr, LastBits);


    // Small pause for coverage sampling
    repeat (5) @(posedge clk_i);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk_i);
    $display("TIMEOUT - finishing");
    $finish;
  end


endmodule
