`timescale 1ns/1ps
module tb_top;
  // ---------------- Clock ----------------
  logic clk = 0;
  always #5 clk = ~clk; // 100MHz

  // ---------------- Plusargs / config ----------------
  int Width     = 800;
  int DInWidth  = 64;
  int EnMasking = 0;
  int NumRounds = 24;
  bit DoOne     = 0;
  string TEST   = "idle"; // idle | one | multi

  initial begin
    void'($value$plusargs("WIDTH=%d",      Width));
    void'($value$plusargs("DINWIDTH=%d",   DInWidth));
    void'($value$plusargs("MASKING=%d",    EnMasking));
    void'($value$plusargs("NUM_ROUNDS=%d", NumRounds));
    void'($value$plusargs("TEST=%s",       TEST));
    if ($test$plusargs("DO_ONE_ROUND")) DoOne = 1;
  end

  // ---------------- Interface ----------------
  kmac_if #(.Width(Width), .DInWidth(DInWidth)) if0(clk);

  // ---------------- DUT: keccak_round ----------------
  // Params & ports match your current TB usage:
  //   Parameters: Width, DInWidth, EnMasking
  //   Ports     : clk_i, rst_ni, run_i, ready_o, din_i, wr_i, addr_i
  keccak_round #(
    .Width(Width),
    .DInWidth(DInWidth),
    .EnMasking(EnMasking)
  ) dut (
    .clk_i   (clk),
    .rst_ni  (if0.rst_n),
    .run_i   (if0.run_i),
    .ready_o (if0.ready_o),
    .din_i   (if0.din_i),
    .wr_i    (if0.wr_i),
    .addr_i  (if0.addr_i)
  );

  // ---------------- Simple sequences (inline) ----------------
  // (You can move these into tb_seq_pkg.sv later)
  task automatic reset_seq();
    if0.rst_n <= 0; repeat (5) @(posedge clk);
    if0.rst_n <= 1; repeat (5) @(posedge clk);
  endtask

  task automatic preload_full_state();
    int words = (Width + DInWidth - 1) / DInWidth;
    for (int a = 0; a < words; a++) begin
      if0.din_i  <= $urandom();
      if0.addr_i <= a[$bits(if0.addr_i)-1:0];
      if0.wr_i   <= 1; @(posedge clk);
      if0.wr_i   <= 0; @(posedge clk);
    end
  endtask

  task automatic walking_ones();
    int words = (Width + DInWidth - 1) / DInWidth;
    for (int a = 0; a < words; a++) begin
      for (int b = 0; b < DInWidth; b++) begin
        if0.din_i  <= '0 | (1 << b);
        if0.addr_i <= a[$bits(if0.addr_i)-1:0];
        if0.wr_i   <= 1; @(posedge clk);
        if0.wr_i   <= 0; @(posedge clk);
      end
    end
  endtask

  task automatic pulse_one_round();
    // mirrors your +DO_ONE_ROUND behavior
    @(posedge clk); if0.run_i <= 1;
    @(posedge clk); if0.run_i <= 0;
    // sample the busy/ready handshake
    @(negedge if0.ready_o);
    @(posedge if0.ready_o);
  endtask

  task automatic multi_rounds(int n);
    repeat (n) pulse_one_round();
  endtask

  task automatic idle_only(int cycles=50);
    repeat (cycles) @(posedge clk);
  endtask

  // ---------------- Test flow ----------------
  initial begin
    // Optional banner like your current TB prints
    if (DoOne) $display("[%0t] TB: +DO_ONE_ROUND set – pulsing run_i once", $time);

    reset_seq();
    preload_full_state();
    walking_ones();

    if (DoOne) begin
      pulse_one_round();
    end else begin
      case (TEST)
        "idle":  idle_only();
        "one":   pulse_one_round();
        "multi": multi_rounds(NumRounds);
        default: idle_only();
      endcase
    end

    repeat (5) @(posedge clk);
    $finish;
  end

endmodule
