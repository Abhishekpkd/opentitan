// sim_main.cpp
#include "Vtb_keccak_round_mask.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "verilatedcov.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Verilated::traceEverOn(true);

  Vtb_keccak_round_mask* top = new Vtb_keccak_round_mask;

  // Run until $finish/$fatal from SV
  while (!Verilated::gotFinish()) {
    top->eval();
  }

  // Write Verilator coverage
  VerilatedCov::write("vcov.dat");
  delete top;
  return 0;
}
