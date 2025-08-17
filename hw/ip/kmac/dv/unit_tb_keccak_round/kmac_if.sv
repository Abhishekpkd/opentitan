interface kmac_if #(parameter int Width = 800, DInWidth = 64) (input logic clk);
  logic rst_n;
  logic                 run_i;
  logic                 ready_o;
  logic [DInWidth-1:0]  din_i;
  logic                 wr_i;
  localparam int WORDS = (Width + DInWidth - 1) / DInWidth;
  logic [$clog2(WORDS)-1:0] addr_i;

  modport drv (output run_i, din_i, wr_i, addr_i, input ready_o, rst_n, clk);
  modport mon (input  run_i, din_i, wr_i, addr_i, ready_o, rst_n, clk);
endinterface
