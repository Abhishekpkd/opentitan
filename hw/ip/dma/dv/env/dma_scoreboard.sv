// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

class dma_scoreboard extends cip_base_scoreboard #(
  .CFG_T(dma_env_cfg),
  .RAL_T(dma_reg_block),
  .COV_T(dma_env_cov)
);
  `uvm_component_utils(dma_scoreboard)

  `uvm_component_new

  // Queue structures holding the expected requests on selected source and destination interfaces
  tl_seq_item src_queue[$];  // Request and response items on source TL interface
  tl_seq_item dst_queue[$];  // Request and response items on destination TL interface

  bit [63:0] exp_src_addr;   // Expected address for next source request
  bit [63:0] exp_dst_addr;   // Expected address for next destination request

  // Internal copy of the DMA configuration information for use in validating TL-UL transactions
  // This copy is updated in the `process_reg_write` function below
  dma_seq_item dma_config;

  // Indicates if DMA operation is in progress
  bit operation_in_progress;
  // Tracks the number of bytes read from the source
  uint num_bytes_read;
  // Expectation of how many bytes shall be transferred by the DMA controller before reports
  // 'Chunk Done' or 'Done.'
  // (for handshake mode this is the entire transfer, but for memory-to-memory operation it tracks
  //  the total size in bytes of the chunks thus far supplied).
  uint exp_bytes_transferred;
  // Variable to keep track of number of bytes transferred in current operation
  uint num_bytes_transferred;
  // Tracks the number of destination bytes checked against the source
  uint num_bytes_checked;
  // Variable to indicate if TL error is detected on interface
  bit src_tl_error_detected;
  bit dst_tl_error_detected;
  // Bit to indicate if DMA operation is explicitly aborted with register write
  bit abort_via_reg_write;

  // Interrupt enable state
  bit [NUM_MAX_INTERRUPTS-1:0] intr_enable;
  // Interrupt test state (contributes to `intr_state`).
  bit [NUM_MAX_INTERRUPTS-1:0] intr_test;
  // Hardware  interrupt state (contributes to `intr_state`).
  bit [NUM_MAX_INTERRUPTS-1:0] intr_state_hw;

  // Prediction of the state of an interrupt signal from the DUT.
  typedef struct packed {
    // Maximum delay in clock cycles from the moment of prediction.
    uint delay;
    // Expected new state of the interrupt signal.
    bit intr_expected;
  } dma_intr_pred_t;

  // Temporally-ordered queue of expected interrupt states, for each interrupt
  dma_intr_pred_t exp_intr_queue[NUM_MAX_INTERRUPTS][$];

  // True if in hardware handshake mode and the FIFO interrupt has been cleared
  bit fifo_intr_cleared;
  // Variable to indicate number of writes expected to clear FIFO interrupts
  uint num_fifo_reg_write;
  // Variable to store clear_intr_src register intended for use in monitor_lsio_trigger task
  // since ref argument can not be used in fork-join_none
  bit [31:0] clear_intr_src;
  bit [TL_DW-1:0] exp_digest[16];

  // Allow up to this number of clock cycles from CSR modification until interrupt signal change;
  // a change in the `control` register can lead to a change in the clock gate, and then delays
  // through the register interface and `prim_intr_hw` modules.
  localparam uint CSRtoIntrLatency = 4;
  // Maximum latency from bus error occurring to interrupt signal change reporting it.
  localparam uint BusErrorToIntrLatency = 4;
  // Maximum latency from detecting a memory limit crossing to interrupt signal change reporting it.
  // Must accommodate the write response latency.
  localparam uint MemLimitToIntrLatency = 128;
  // Maximum delay (in clock cycles) from the final bus write of a DMA transfer until the Done
  // interrupt signal shall occur.
  // Note: DUT may suffer delays in final write response appearing and then the completion of the
  //       SHA digest.
  localparam uint WriteToDoneLatency = 1024;
  // Maximum delay from setting 'Go' bit until an invalid configuration raises an Error interrupt;
  // this can depend upon the number of interrupt sources because the DUT performs 'clear interrupt'
  // writes before validating the configuration.
  // Note: this is a conservative figure, but we could perhaps consult the TL agent configuration.
  localparam uint GoToCfgErrLatency = dma_reg_pkg::NumIntClearSources * 40;

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    // Create a_channel analysis fifo
    foreach (cfg.dma_a_fifo[key]) begin
      tl_a_chan_fifos[cfg.dma_a_fifo[key]] = new(cfg.dma_a_fifo[key], this);
    end
    foreach (cfg.dma_d_fifo[key]) begin
      tl_d_chan_fifos[cfg.dma_d_fifo[key]] = new(cfg.dma_d_fifo[key], this);
    end
    foreach (cfg.dma_dir_fifo[key]) begin
      tl_dir_fifos[cfg.dma_dir_fifo[key]] = new(cfg.dma_dir_fifo[key], this);
    end
    // `dma_config` serves to hold a copy of the DMA configuration registers, which are the same
    // values being randomized and used by the vseqs. Its fields are updated in `process_reg_write`
    // and randomizing may catch failures to update them properly
    dma_config = dma_seq_item::type_id::create("dma_config");
    if (!dma_config.randomize()) begin
      `uvm_fatal(`gfn, "Failed to randomize dma_config")
    end
  endfunction : build_phase

  // Look up the given address in the list of 'Clear Interrupt' addresses, returning a positive
  // index iff found.
  function int intr_addr_lookup(bit [63:0] addr);
    for (uint idx = 0; idx < dma_config.intr_src_addr.size(); idx++) begin
      if (dma_config.intr_src_addr[idx] == addr) begin
        // Address matches; this address should just receive write traffic.
        return int'(idx);
      end
    end
    return -1;
  endfunction : intr_addr_lookup

  // Check if the address matches our expectations and is valid for the current configuration.
  // This method is common for both source and destination address.
  function void check_addr(bit [63:0]       addr,        // Observed address.
                           bit [63:0]       exp_addr,    // Expectation.
                           bit              restricted,  // DMA-enabled range applies.
                           bit              fixed_addr,  // Fixed address.
                           // Expected address range for this accesses of this type.
                           bit [63:0]       range_start,
                           bit [31:0]       range_len,
                           // Configuration for this transfer.
                           ref dma_seq_item dma_config,
                           input string     check_type);  // Type of access.
    // End of valid address range; dependent upon the chunk/transfer size and auto-inc setting.
    bit [63:0] range_end = range_start + range_len;
    int idx;

    `uvm_info(`gfn, $sformatf("%s access to 0x%0x, exp 0x%0x, fixed_addr %d, restricted %d",
                              check_type, addr, exp_addr, fixed_addr, restricted), UVM_DEBUG)
    `uvm_info(`gfn,
              $sformatf("  (%s range is [0x%0x,0x%0x) and DMA-enabled range is [0x%0x,0x%0x))",
                        check_type, range_start, range_end,
                        dma_config.mem_range_base, dma_config.mem_range_limit), UVM_DEBUG)

    `DV_CHECK(addr[1:0] == 0, $sformatf("Address is not 4 Byte aligned"))

    // Is this end of the transfer a fixed address?
    if (fixed_addr) begin
      `DV_CHECK(addr[63:2] == range_start[63:2],
                $sformatf("0x%0x doesn't match %s start addr:0x%0x (handshake mode no auto-incr)",
                          addr, check_type, range_start))
    end else begin
      // Addresses generated by DMA are 4-Byte aligned (refer #338)
      bit [63:0] aligned_start_addr = {range_start[63:2], 2'b00};
      // Generic mode address check
      `DV_CHECK(addr >= aligned_start_addr && addr < range_end,
                $sformatf("0x%0x not in %s addr range [0x%0x,0x%0x)", addr, check_type,
                          aligned_start_addr, range_end))
    end

    // Check that this address lies within the DMA-enabled memory range, where applicable.
    if (restricted) begin
      `DV_CHECK(addr >= dma_config.mem_range_base && addr < dma_config.mem_range_limit,
                $sformatf("%s addr 0x%0x does not lie within the DMA-enabled range [0x%0x,0x%0x)",
                          check_type, addr, dma_config.mem_range_base,
                          dma_config.mem_range_limit))
    end

    // Is this request to the address we expected?
    `DV_CHECK(addr[63:2] == exp_addr[63:2],
              $sformatf("%s access 0x%0x does not match expectation 0x%0x", check_type,
                        addr, exp_addr))
  endfunction

  // On-the-fly checking of write data against the pre-randomized source data
  function void check_write_data(string if_name, bit [63:0] a_addr, ref tl_seq_item item);
    bit [tl_agent_pkg::DataWidth-1:0] wdata = item.a_data;
    bit [31:0] offset = num_bytes_transferred;

    `uvm_info(`gfn, $sformatf("if_name %s: write addr 0x%0x mask 0x%0x data 0x%0x", if_name,
                              a_addr, item.a_mask, item.a_data), UVM_HIGH)

    // Check each of the bytes being written, Little Endian byte ordering
    for (int i = 0; i < $bits(item.a_mask); i++) begin
      if (item.a_mask[i]) begin
        `uvm_info(`gfn, $sformatf("src_data %0x write data 0x%0x",
                                  cfg.src_data[offset], wdata[7:0]), UVM_DEBUG)
        `DV_CHECK_EQ(cfg.src_data[offset], wdata[7:0])
        offset++;
      end
      wdata = wdata >> 8;
    end
  endfunction

  // Predict the address to which the next access of this type should occur.
  function bit [63:0] predict_addr(bit [63:0]       addr,
                                   // Bytes read/written, after the current bus access.
                                   uint             num_bytes,
                                   // Start address of transfer (= start of first chunk).
                                   bit [63:0]       start_addr,
                                   bit              addr_inc,
                                   bit              chunk_wrap,
                                   // Configuration for this transfer.
                                   ref dma_seq_item dma_config,
                                   input string     check_type);  // Type of access.
    // Default is to advance by the transfer amount from our previous prediction.
    bit [63:0] next_addr = addr + dma_config.txn_bytes();

    // Are we expecting another access?
    if (num_bytes < dma_config.total_data_size) begin
      if (!dma_config.chunk_data_size || (num_bytes % dma_config.chunk_data_size)) begin
        // Still within this chunk; do we advance per bus transaction?
        if (!addr_inc) begin
          // Fixed address.
          next_addr = addr;
        end
      end else begin
        // End of chunk.
        if (chunk_wrap) begin
          next_addr = start_addr;  // All chunks start at the same address.
        end else if (!addr_inc) begin
          // Chunks do not overlap but all words within a chunk do.
          next_addr = addr + dma_config.chunk_data_size;
        end
      end
    end else begin
      next_addr = {64{1'b1}};  // Invalid; induce a mismatch if there is another access.
    end

    `uvm_info(`gfn, $sformatf("%s prediction 0x%0x (num_bytes 0x%0x after 0x%0x)",
                              check_type, next_addr, num_bytes, addr), UVM_DEBUG)
    `uvm_info(`gfn, $sformatf("  (start 0x%0x, addr_inc %d, chunk_wrap %d)",
                              start_addr, addr_inc, chunk_wrap), UVM_DEBUG)
    return next_addr;
  endfunction

  // Process items on Addr channel
  task process_tl_addr_txn(string if_name, bit [63:0] a_addr, ref tl_seq_item item);
    uint expected_txn_size = dma_config.transfer_width_to_a_size(
                               dma_config.per_transfer_width);
    uint expected_per_txn_bytes = dma_config.transfer_width_to_num_bytes(
                                    dma_config.per_transfer_width);
    tl_a_op_e a_opcode = tl_a_op_e'(item.a_opcode);
    int intr_source;

    `uvm_info(`gfn, $sformatf("Got addr txn \n:%s", item.sprint()), UVM_DEBUG)
    // Common checks
    // Check if the transaction is of correct size
    `DV_CHECK_EQ(item.a_size, 2); // Always 4B

    // Interface specific checks
    // - Read transactions are from Source interface and
    // - Write transactions are to destination interface
    if (!item.is_write()) begin // read transaction
      // Does the DMA-enabled memory range apply to this type of access?
      bit restricted = dma_config.mem_range_valid && (dma_config.src_asid == OtInternalAddr &&
                                                      dma_config.dst_asid != OtInternalAddr);
      bit fixed_addr = dma_config.src_chunk_wrap & !dma_config.src_addr_inc;
      bit [31:0] memory_range;
      // Check if the transaction has correct mask
      `DV_CHECK_EQ($countones(item.a_mask), 4) // Always 4B
      // Check source ASID for read transaction
      `DV_CHECK_EQ(if_name, cfg.asid_names[dma_config.src_asid],
                   $sformatf("Unexpected read txn on %s interface with source ASID %s",
                             if_name, dma_config.src_asid.name()))
      // Check if opcode is as expected
      `DV_CHECK(a_opcode inside {Get},
               $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))

      // Is this address a 'Clear Interrupt' operation?
      intr_source = intr_addr_lookup(a_addr);
      `DV_CHECK_EQ(intr_source, -1, "Unexpected Read access to Clear Interrupt address")

      // The range of memory addresses that should be touched by the DMA controller depends upon
      // whether address incrementing and/or chunk wrapping are used.
      memory_range = dma_config.total_data_size;
      if (dma_config.src_chunk_wrap) begin
        // All chunks within the transfer overlap each other in memory
        memory_range = dma_config.chunk_data_size;
        if (!dma_config.src_addr_inc) begin
          // This configuration is even more restrictive; all accesses are to a single address.
          memory_range = 4;
        end
      end

      // Validate the read address for this source access.
      check_addr(a_addr, exp_src_addr, restricted, fixed_addr, dma_config.src_addr, memory_range,
                 dma_config, "Source");

      // Push addr item to source queue
      src_queue.push_back(item);
      `uvm_info(`gfn, $sformatf("Addr channel checks done for source item"), UVM_HIGH)

      // Update the count of bytes read from the source.
      // Note that this is complicated by the fact that the TL-UL host adapter always fetches
      // complete bus words, so we have to rely upon knowledge of the configured transfer amount.
      num_bytes_read += dma_config.txn_bytes();

      // Update expectation of next source access, predicting from our current expectation;
      // this is important because the current transaction address is missing its LSBs and thus
      // cannot be used.
      exp_src_addr = predict_addr(exp_src_addr, num_bytes_read, dma_config.src_addr,
                                  dma_config.src_addr_inc, dma_config.src_chunk_wrap,
                                  dma_config, "Source");
    end else begin // Write transaction
      // Does the DMA-enabled memory range apply to this type of access?
      bit restricted = dma_config.mem_range_valid && (dma_config.dst_asid == OtInternalAddr &&
                                                      dma_config.src_asid != OtInternalAddr);

      bit fixed_addr = dma_config.dst_chunk_wrap & !dma_config.dst_addr_inc;
      bit [31:0] memory_range;
      // Is this address a 'Clear Interrupt' operation?
      intr_source = intr_addr_lookup(a_addr);
      // Push addr item to destination queue
      dst_queue.push_back(item);
      `uvm_info(`gfn, $sformatf("Addr channel checks done for destination item"), UVM_HIGH)

      // The range of memory addresses that should be touched by the DMA controller depends upon
      // whether chunks overlap.
      memory_range = dma_config.total_data_size;
      if (dma_config.dst_chunk_wrap) begin
        // All chunks within the transfer overlap each other in memory
        memory_range = dma_config.chunk_data_size;
        if (!dma_config.dst_addr_inc) begin
          // This configuration is even more restrictive; all accesses are to a single address.
          memory_range = 4;
        end
      end

      // Write to 'Clear Interrupt' address?
      if (intr_source < 0) begin
        // Regular write traffic
        uint exp_a_mask_count_ones;
        uint num_bytes_this_txn;
        uint transfer_bytes_left;
        uint remaining_bytes;

        // Validate the write address for this destination access.
        check_addr(a_addr, exp_dst_addr, restricted, fixed_addr, dma_config.dst_addr, memory_range,
                   dma_config, "Destination");

        // Note: this will only work because we KNOW that we don't reprogram the `chunk_data_size`
        //       register, so we can rely upon all non-final chunks being of the same size
        `DV_CHECK(num_bytes_transferred < dma_config.total_data_size,
                  "Write transaction when too many bytes transferred already");

        transfer_bytes_left = dma_config.total_data_size - num_bytes_transferred;
        // Bytes remaining until the end of the current chunk
        remaining_bytes = dma_config.chunk_data_size
                             - (num_bytes_transferred % dma_config.chunk_data_size);
        if (transfer_bytes_left < remaining_bytes) begin
          remaining_bytes = transfer_bytes_left;
        end

        exp_a_mask_count_ones = remaining_bytes > expected_per_txn_bytes ?
                                expected_per_txn_bytes : remaining_bytes;
        num_bytes_this_txn = $countones(item.a_mask);

        // check if a_mask matches the data size
        `DV_CHECK_EQ(num_bytes_this_txn, exp_a_mask_count_ones,
                 $sformatf("unexpected write a_mask: %x for %0d-byte transfer. Expected %x bytes",
                           item.a_mask, expected_per_txn_bytes, exp_a_mask_count_ones))

        // Check destination ASID for write transaction
        `DV_CHECK_EQ(if_name, cfg.asid_names[dma_config.dst_asid],
                     $sformatf("Unexpected write txn on %s interface with destination ASID %s",
                               if_name, dma_config.dst_asid.name()))

        // Track write-side progress through this transfer
        `uvm_info(`gfn, $sformatf("num_bytes_this_txn %x intr_source %x",
                                  num_bytes_this_txn, intr_source), UVM_HIGH);

        // On-the-fly checking of writing data
        check_write_data(if_name, a_addr, item);

        // Check if opcode is as expected
        if ((dma_config.per_transfer_width != DmaXfer4BperTxn) ||
            (remaining_bytes < expected_per_txn_bytes)) begin
          `DV_CHECK(a_opcode inside {PutPartialData},
                    $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
        end else begin
          `DV_CHECK(a_opcode inside {PutFullData},
                    $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
        end

        // Update number of bytes transferred only in case of write txn - refer #338
        num_bytes_transferred += num_bytes_this_txn;

        // Update expectation of next destination access, predicting from our current expectation;
        // this is important because the current transaction address is missing its LSBs and thus
        // cannot be used.
        exp_dst_addr = predict_addr(exp_dst_addr, num_bytes_transferred, dma_config.dst_addr,
                                    dma_config.dst_addr_inc, dma_config.dst_chunk_wrap,
                                    dma_config, "Destination");
      end else begin
        // Write to 'Clear Interrupt' address, so check the value written and the bus to which the
        // write has been sent.
        string exp_name;
        exp_name = dma_config.clear_intr_bus[intr_source] ? "host" : "ctn";

        `uvm_info(`gfn, $sformatf("Clear Interrupt write of 0x%0x to address 0x%0x",
                                  item.a_data, item.a_addr), UVM_HIGH)
        `DV_CHECK_EQ(if_name, exp_name,
                     $sformatf("%s received %s-targeted clear interrupt write", if_name, exp_name))
        `DV_CHECK_EQ(dma_config.intr_src_wr_val[intr_source], item.a_data,
                     $sformatf("Unexpected value 0x%0x written to clear interrupt %d", item.a_data,
                               intr_source))
        `DV_CHECK_EQ(item.a_mask, 4'hF, "Unexpected write enables to clear interrupt write")

        // We're expecting only full word writes.
        `DV_CHECK(a_opcode inside {PutFullData},
                  $sformatf("Unexpected opcode : %d on %s", a_opcode.name(), if_name))
      end
    end

    // Track byte-counting within the transfer since it determines the prediction of completion
    `uvm_info(`gfn, $sformatf("num_bytes_transferred 0x%x total_data_size 0x%x",
                              num_bytes_transferred, dma_config.total_data_size), UVM_HIGH);
  endtask

  // Process items on Data channel
  task process_tl_data_txn(string if_name, bit [63:0] a_addr, ref tl_seq_item item);
    bit tl_error_suppressed = 0;
    bit got_source_item = 0;
    bit got_dest_item = 0;
    uint queue_idx = 0;
    tl_d_op_e d_opcode = tl_d_op_e'(item.d_opcode);

    // Check if there is a previous address request with the
    // same source id as the current data request
    foreach (src_queue[i]) begin
      if (item.d_source == src_queue[i].a_source) begin
        got_source_item = 1;
        queue_idx = i;
        `uvm_info(`gfn, $sformatf("Found data item with source id %0d at index: %0d",
                                  item.d_source, queue_idx), UVM_HIGH)
      end
    end
    // Check if there is a previous address request with the
    // same destination id as the current data request
    if (!got_source_item) begin
      foreach (dst_queue[i]) begin
        if (item.d_source == dst_queue[i].a_source) begin
          got_dest_item = 1;
          queue_idx = i;
          `uvm_info(`gfn, $sformatf("Found data item with destination id %0d at index: %0d",
                                    item.d_source, queue_idx), UVM_HIGH)
        end
      end
    end

    // Check if Data item has an outstanding address item
    `DV_CHECK(got_source_item || got_dest_item,
              $sformatf("Data item source id doesn't match any outstanding request"))

    // Source interface item checks
    if (got_source_item) begin
      src_tl_error_detected = item.d_error;
      if (src_tl_error_detected) begin
        `uvm_info(`gfn, $sformatf("Detected TL error on Source Data item (addr 0x%0x)", a_addr),
                  UVM_HIGH)
        // SoC System bus is able to signal Read errors, so these are never suppressed.
      end
      // Check if data item opcode is as expected
      `DV_CHECK(d_opcode inside {AccessAckData},
                $sformatf("Invalid opcode %s for source data item", d_opcode))
      // Delete after all checks related to data channel are done
      `uvm_info(`gfn, $sformatf("Deleting element at %d index in source queue", queue_idx),
                UVM_HIGH)
      src_queue.delete(queue_idx);
    end else if (got_dest_item) begin
      // Destination interface item checks
      dst_tl_error_detected = item.d_error;
      if (dst_tl_error_detected) begin
        `uvm_info(`gfn,
                  $sformatf("Detected TL error on Destination Data item (addr 0x%0x)", a_addr),
                  UVM_HIGH)
        // The SoC System bus does not support signaling of Write errors, so the TL-UL write error
        // will not be reported by the DMA controller; modify our expectation accordingly.
        if (if_name == "sys") begin
          `uvm_info(`gfn, "WARN: Error suppressed because Full System bus DV waived", UVM_LOW)
          tl_error_suppressed = 1;
        end
      end
      // Check if data item opcode is as expected
      `DV_CHECK(d_opcode inside {AccessAck},
                $sformatf("Invalid opcode %s for destination data item", d_opcode))
      // Delete after all checks related to data channel are done
      `uvm_info(`gfn, $sformatf("Deleting element at %d index in destination queue", queue_idx),
                UVM_HIGH)
      dst_queue.delete(queue_idx);
    end

    if (cfg.en_cov && (src_tl_error_detected || dst_tl_error_detected)) begin
      cov.tlul_error_cg.sample(.dma_config(dma_config),
                               .tl_err_asid(if_name_to_asid(if_name)));
    end

    // Errors are expected to raise an interrupt if enabled, but we not must forget a configuration
    // error whilst error-free 'clear interrupt' writes are occurring.
    if (item.d_error && !tl_error_suppressed) begin
      `uvm_info(`gfn, "Bus error detected", UVM_MEDIUM)
      predict_interrupts(BusErrorToIntrLatency, 1 << IntrDmaError, intr_enable);
      intr_state_hw[IntrDmaError] = 1'b1;
    end else if (got_dest_item) begin
      // Is this the final destination write?
      //
      // Note: we must perform this on the data channel (write response) because an error may occur
      //       on the very final write transaction, in which case DONE should not be seen.
      if (num_bytes_transferred >= exp_bytes_transferred) begin
        // Whether an interrupt is expected also depends upon whether it is enabled.
        // Have we yet completed the entire transfer?
        if (num_bytes_transferred >= dma_config.total_data_size) begin
          `uvm_info(`gfn, "Final write completed", UVM_MEDIUM)
          predict_interrupts(WriteToDoneLatency, 1 << IntrDmaDone, intr_enable);
          intr_state_hw[IntrDmaDone] = 1'b1;
        end else begin
          `uvm_info(`gfn, "Chunk writing completed", UVM_MEDIUM)
          predict_interrupts(WriteToDoneLatency, 1 << IntrDmaChunkDone, intr_enable);
          intr_state_hw[IntrDmaChunkDone] = 1'b1;
        end
      end
    end
  endtask

  // Method to process requests on TL interfaces
  task process_tl_txn(string if_name,
                      uvm_tlm_analysis_fifo#(tl_channels_e) dir_fifo,
                      uvm_tlm_analysis_fifo#(tl_seq_item) a_chan_fifo,
                      uvm_tlm_analysis_fifo#(tl_seq_item) d_chan_fifo);
    bit exp_intr_clearing;
    tl_channels_e dir;
    tl_seq_item   item;
    fork
      forever begin
        bit [63:0] a_addr;

        dir_fifo.get(dir);
        // Clear Interrupt writes are emitted even for invalid configurations.
        exp_intr_clearing = dma_config.handshake & |dma_config.clear_intr_src &
                           |dma_config.handshake_intr_en;
        // Check if transaction is expected for a valid configuration
        `DV_CHECK_FATAL(dma_config.is_valid_config || exp_intr_clearing,
                           $sformatf("transaction observed on %s for invalid configuration",
                                     if_name))
        // Check if there is any active operation, but be aware that the Abort functionality
        // intentionally does not wait for a bus response (this is safe because the design never
        // blocks/stalls the TL-UL response).
        `DV_CHECK_FATAL(operation_in_progress || abort_via_reg_write,
                        "Transaction detected with no active operation")
        case (dir)
          AddrChannel: begin
            `DV_CHECK_FATAL(a_chan_fifo.try_get(item),
                            "dir_fifo pointed at A channel, but a_chan_fifo empty")
            a_addr = item.a_addr;
            if (cfg.dma_dv_waive_system_bus && if_name == "sys") begin
              a_addr[63:32] = cfg.soc_system_hi_addr;
            end

            `uvm_info(`gfn, $sformatf("received %s a_chan %s item with addr: %0x and data: %0x",
                                      if_name,
                                      item.is_write() ? "write" : "read", a_addr,
                                      item.a_data), UVM_HIGH)
            process_tl_addr_txn(if_name, a_addr, item);
            // Update num_fifo_reg_write
            if (num_fifo_reg_write > 0) begin
              `uvm_info(`gfn, $sformatf("Processed FIFO clear_intr_src addr: %0x0x", item.a_addr),
                        UVM_DEBUG)
              num_fifo_reg_write--;
            end else begin
              // Set status bit after all FIFO interrupt clear register writes are done
              fifo_intr_cleared = 1;
            end
          end
          DataChannel: begin
            `DV_CHECK_FATAL(d_chan_fifo.try_get(item),
                            "dir_fifo pointed at D channel, but d_chan_fifo empty")
            a_addr = item.a_addr;
            if (cfg.dma_dv_waive_system_bus && if_name == "sys") begin
              a_addr[63:32] = cfg.soc_system_hi_addr;
            end
            `uvm_info(`gfn, $sformatf("received %s d_chan item with addr: %0x and data: %0x",
                                      if_name, a_addr, item.d_data), UVM_HIGH)
            process_tl_data_txn(if_name, a_addr, item);
          end
          default: `uvm_fatal(`gfn, "Invalid entry in dir_fifo")
        endcase
      end
    join_none
  endtask

  // Clear internal variables on reset
  virtual function void reset(string kind = "HARD");
    super.reset();
    `uvm_info(`gfn, "Detected DMA reset", UVM_LOW)
    dma_config.reset_config();
    src_queue.delete();
    dst_queue.delete();
    operation_in_progress = 1'b0;
    num_bytes_read = 0;
    exp_bytes_transferred = 0;
    num_bytes_transferred = 0;
    num_bytes_checked = 0;
    src_tl_error_detected = 0;
    dst_tl_error_detected = 0;
    abort_via_reg_write = 0;
    fifo_intr_cleared = 0;
    intr_enable = 0;
    intr_test = 0;
    intr_state_hw = 0;
  endfunction

  // Method to check if DMA interrupt is expected
  task monitor_and_check_dma_interrupts(ref dma_seq_item dma_config);
    bit   [NUM_MAX_INTERRUPTS-1:0] valid_intr = (1 << cfg.num_interrupts) - 1;
    logic [NUM_MAX_INTERRUPTS-1:0] prev_intr = cfg.intr_vif.sample() & valid_intr;
    forever begin
      // Current state of interrupt lines.
      logic [NUM_MAX_INTERRUPTS-1:0] curr_intr = cfg.intr_vif.sample() & valid_intr;

      // We check the interrupt signals against expectations _one cycle after_ sampling them,
      // because writes to the INTR_TEST register have an immediate effect upon the interrupt lines,
      // but `process_reg_write` is not invoked to update the prediction until the end of the write
      // cycle.
      //
      // We're counting cycles in general, monitoring the interrupt signals for unanticipated
      // changes; we must also ensure that simulation time advance during reset.
      cfg.clk_rst_vif.wait_clks(1);

      // Do not consume simulation time whilst the semaphore is locked; predictions are posted
      // by the function `predict_interrupts` above.
      if (cfg.under_reset) begin
        // Interrupts shall be deasserted by DUT reset, and any predictions no longer apply.
        clear_intr_predictions();
        prev_intr = 'b0;
      end else if (cfg.en_scb) begin
        bit [NUM_MAX_INTERRUPTS-1:0] exp_intr;
        string rsn;
        // Does each interrupt signal match against its expectation?
        for (uint i = 0; i < NUM_MAX_INTERRUPTS; i++) begin
          exp_intr[i] = intr_state_expected(i, curr_intr[i], prev_intr[i]);
          if (curr_intr[i] !== exp_intr[i]) begin
            // Collect a list of the mismatched interrupts
            unique case (i)
              IntrDmaDone:      rsn = {rsn, "Done "};
              IntrDmaChunkDone: rsn = {rsn, "ChunkDone "};
              IntrDmaError:     rsn = {rsn, "Error "};
              default:          rsn = {rsn, "Unknown intr"};
            endcase
          end
        end
        // Check and report any mismatches against expectations, listing those that mismatch.
        `DV_CHECK_EQ(curr_intr, exp_intr,
                     $sformatf("Unexpected state of interrupt signals (Mismatched: %s)", rsn))
        // Retain their new state.
        prev_intr = curr_intr;
      end
    end
  endtask

  // Determine the expected state of the given interrupt signal, based upon any outstanding
  // predictions.
  function bit intr_state_expected(uint intr, logic curr_intr, logic prev_intr);
    bit changed = (curr_intr !== prev_intr);
    // If we have no current predictions, we anticipate no change.
    bit exp_intr = prev_intr;
    bit elapsed = 1'b0;

    if (exp_intr_queue[intr].size() > 0) begin
      // What state should the interrupt signal have when the predicted event occurs?
      dma_intr_pred_t pred = exp_intr_queue[intr][0];
      `uvm_info(`gfn, $sformatf("pred_intr %d : %x %x", intr, pred.delay, pred.intr_expected),
                UVM_HIGH)
      // This prediction is retired and must have been met when:
      //      (i) the interrupt signal has the expected state,
      //     (ii) a change in the signal is observed,
      // or (iii) the maximum latency has been reached.
      elapsed = (pred.delay == 0);
      if (elapsed || changed || curr_intr === pred.intr_expected) begin
        exp_intr = pred.intr_expected;
        void'(exp_intr_queue[intr].pop_front());
      end else begin
        // Just update the lifetime of the prediction.
        exp_intr_queue[intr][0].delay--;
      end
    end
    if (elapsed | changed) begin
      `uvm_info(`gfn, $sformatf("Intr %d: 0x%x exp 0x%0x (prev 0x%x) changed %d elapsed %d",
                                intr, curr_intr, exp_intr, prev_intr, changed, elapsed), UVM_HIGH)
    end
    return exp_intr;
  endfunction

  // Form a prediction about the state of the indicated interrupt signals after at most the
  // specified number of clock signals.
  // Note: this explicitly does NOT mean that they must CHANGE to achieve that state; only that
  //       they must be in that state by then.
  function void predict_interrupts(uint max_delay, bit [31:0] intr_affected, bit [31:0] exp_state);
    // Clear all bits that do not map to defined interrupts, to avoid confusion in the log messages.
    intr_affected &= {NumDmaInterrupts{1'b1}};
    exp_state &= {NumDmaInterrupts{1'b1}};

    `uvm_info(`gfn, $sformatf("Predicting interrupt [0,%0x) -> intr_affected 0x%x == 0x%0x",
                              max_delay, intr_affected, exp_state), UVM_HIGH)

    for (uint i = 0; i < NumDmaInterrupts && |intr_affected; i++) begin
      if (intr_affected[i]) begin
        dma_intr_pred_t predict;
        predict.delay = max_delay;
        predict.intr_expected = exp_state[i];
        exp_intr_queue[i].push_back(predict);
        intr_affected[i] = 0;
      end
    end
  endfunction

  // Clear all pending interrupt predictions; these are no longer expected to occur.
  function void clear_intr_predictions();
    `uvm_info(`gfn, "Clearing interrupt predictions", UVM_MEDIUM)
    for (uint i = 0; i < NUM_MAX_INTERRUPTS; i++) exp_intr_queue[i].delete();
  endfunction

  // Task to monitor LSIO trigger and update scoreboard internal variables
  task monitor_lsio_trigger();
    fork
      begin
        forever begin
          uvm_reg_data_t handshake_en;
          uvm_reg_data_t handshake_intr_en;
          // Wait for at least one LSIO trigger to be active and it is enabled
          @(posedge cfg.dma_vif.handshake_i);
          handshake_en = `gmv(ral.control.hardware_handshake_enable);
          handshake_intr_en = `gmv(ral.handshake_intr_enable);
          // Update number of register writes expected in case at least one
          // of the enabled handshake interrupt is asserted
          if (handshake_en && (cfg.dma_vif.handshake_i & handshake_intr_en)) begin
            num_fifo_reg_write = $countones(clear_intr_src);
            `uvm_info(`gfn,
                      $sformatf("Handshake mode: num_fifo_reg_write:%0d", num_fifo_reg_write),
                      UVM_HIGH)
          end
        end
      end
    join_none
  endtask

  function void check_phase(uvm_phase phase);
    if (!cfg.en_scb) return;
    begin // Check if there are unprocessed source items
      uint size = src_queue.size();
      `DV_CHECK_EQ(size, 0, $sformatf("%0d unhandled source interface transactions",size))
      // Check if there are unprocessed destination items
      size = dst_queue.size();
      `DV_CHECK_EQ(size, 0, $sformatf("%0d unhandled destination interface transactions",size))
    end
    // Check if DMA operation is in progress
    `DV_CHECK_EQ(operation_in_progress, 0, "DMA operation incomplete")
  endfunction

  task run_phase(uvm_phase phase);
    super.run_phase(phase);
    num_fifo_reg_write = 0;
    // Call process methods on TL fifo
    foreach (cfg.fifo_names[i]) begin
      process_tl_txn(cfg.fifo_names[i],
                     tl_dir_fifos[cfg.dma_dir_fifo[cfg.fifo_names[i]]],
                     tl_a_chan_fifos[cfg.dma_a_fifo[cfg.fifo_names[i]]],
                     tl_d_chan_fifos[cfg.dma_d_fifo[cfg.fifo_names[i]]]);
    end
    monitor_and_check_dma_interrupts(dma_config);
    monitor_lsio_trigger();
  endtask

  // Function to get the memory model data at provided address
  function bit [7:0] get_model_data(asid_encoding_e asid, bit [63:0] addr);
    case (asid)
      OtInternalAddr: return cfg.mem_host.read_byte(addr);
      SocControlAddr: return cfg.mem_ctn.read_byte(addr);
      SocSystemAddr : return cfg.mem_sys.read_byte(addr);
      default: begin
        `uvm_error(`gfn, $sformatf("Unsupported Address space ID %d", asid))
      end
    endcase
  endfunction

  // Function to retrieve the next byte written into the destination FIFO
  // Note: that this is destructive in that it pops the data from the FIFO
  function bit [7:0] get_fifo_data(asid_encoding_e asid, bit [63:0] addr);
    case (asid)
      OtInternalAddr: return cfg.fifo_dst_host.read_byte(addr);
      SocControlAddr: return cfg.fifo_dst_ctn.read_byte(addr);
      SocSystemAddr : return cfg.fifo_dst_sys.read_byte(addr);
      default: begin
        `uvm_error(`gfn, $sformatf("Unsupported Address space ID %d", asid))
      end
    endcase
  endfunction

  // Returns the bitmap of Status-type interrupts that are set because of bits in the `status`
  // register being asserted.

  // Utility function to check the contents of the destination memory/FIFO against the
  // corresponding reference source data.
  function void check_data(ref dma_seq_item dma_config, bit [63:0] src_addr, bit [63:0] dst_addr,
                           bit [31:0] src_offset, bit [31:0] size);
    // Is the destination a FIFO?
    bit dst_fifo = dma_config.get_write_fifo_en();

    `uvm_info(`gfn, $sformatf("Checking output data [0x%0x,0x%0x) against 0%0x byte(s) of source",
                              dst_addr, dst_addr + size, size), UVM_MEDIUM)
    `uvm_info(`gfn, $sformatf("  (src_addr 0x%0x at reference offset 0x%0x)", src_addr, src_offset),
                              UVM_MEDIUM)

    for (int i = 0; i < size; i++) begin
      // For the source data we access the original randomized data that we chose
      bit [7:0] src_data = cfg.src_data[src_offset + i];
      bit [7:0] dst_data;

      if (dst_fifo) begin
        dst_data = get_fifo_data(dma_config.dst_asid, dst_addr);
      end else begin
        dst_data = get_model_data(dma_config.dst_asid, dst_addr);
      end
      `uvm_info(`gfn,
                $sformatf("checking src_addr = %0x data = %0x : dst_addr = %0x data = %0x",
                          src_addr, src_data, dst_addr, dst_data), UVM_DEBUG)
      `DV_CHECK_EQ(src_data, dst_data,
                   $sformatf("src_addr = %0x data = %0x : dst_addr = %0x data = %0x",
                             src_addr, src_data, dst_addr, dst_data))
      src_addr++;
      if (!dst_fifo) begin
        dst_addr++;
      end
    end
  endfunction

  // Return the index that a register name refers to e.g. "intr_src_addr_1" yields 1
  function uint get_index_from_reg_name(string reg_name);
    int str_len = reg_name.len();
    // Note: this extracts the final two characters which are either '_y' or 'xy',
    //       and because '_' is permitted in (System)Verilog numbers, it works for 0-99
    string index_str = reg_name.substr(str_len-2, str_len-1);
    return index_str.atoi();
  endfunction

  // Method to process DMA register write
  function void process_reg_write(tl_seq_item item, uvm_reg csr);
    `uvm_info(`gfn, $sformatf("Got reg_write to %s with addr : %0x and data : %0x ",
                              csr.get_name(), item.a_addr, item.a_data), UVM_HIGH)

    // incoming access is a write to a valid csr, so make updates right away
    void'(csr.predict(.value(item.a_data), .kind(UVM_PREDICT_WRITE), .be(item.a_mask)));

    case (csr.get_name())
      "intr_enable": begin
        `uvm_info(`gfn, $sformatf("Got intr_enable = %0x", item.a_data), UVM_HIGH)
        intr_enable = item.a_data;

        // Should raise/lower any interrupt signals for which the INTR_STATE bit is set; check all
        // that may be changed according to the new enable bits.
        predict_interrupts(CSRtoIntrLatency, `gmv(ral.intr_state), item.a_data);
      end
      "intr_state": begin
        // Writing 1 to an INTR_STATE bit clears the corresponding asserted 'Event' interrupt;
        // Status type interrupts are unaffected.
        uvm_reg_data_t intr = item.a_data & `gmv(ral.intr_enable) & ~ral.intr_state.get_ro_mask();
        predict_interrupts(CSRtoIntrLatency, intr, 0);
      end
      "intr_test": begin
        // The 'Read Only' fields tell us which are Status-type interrupts.
        uvm_reg_data_t ro_mask = ral.intr_state.get_ro_mask();
        uvm_reg_data_t now_set;

        `uvm_info(`gfn, $sformatf("intr_test write 0x%x with enables 0x%0x",
                                  item.a_data, intr_enable), UVM_HIGH)

        // Should raise all tested interrupts that are enabled at the time of the test;
        // the intr_state bit and the interrupt line then remain high until cleared.
        //
        // For Status-type interrupts we must retain the fact that they are asserted because of
        // the `intr_test` register.
        intr_test = item.a_data & ro_mask;
        now_set = item.a_data | intr_state_hw;
        predict_interrupts(CSRtoIntrLatency, item.a_data | ro_mask, now_set & intr_enable);
      end
      "src_addr_lo": begin
        dma_config.src_addr[31:0] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got src_addr_lo = %0x", dma_config.src_addr[31:0]), UVM_HIGH)
      end
      "src_addr_hi": begin
        dma_config.src_addr[63:32] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got src_addr_hi = %0x", dma_config.src_addr[63:32]), UVM_HIGH)
      end
      "dst_addr_lo": begin
        dma_config.dst_addr[31:0] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got dst_addr_lo = %0x", dma_config.dst_addr[31:0]), UVM_HIGH)
      end
      "dst_addr_hi": begin
        dma_config.dst_addr[63:32] = item.a_data;
        `uvm_info(`gfn, $sformatf("Got dst_addr_hi = %0x", dma_config.dst_addr[63:32]), UVM_HIGH)
      end
      // TODO: Drop dst_control and src_control
      "dst_config", "dst_control": begin
        `uvm_info(`gfn, $sformatf("Got dst_config = %0x", item.a_data), UVM_HIGH)
        dma_config.dst_chunk_wrap = get_field_val(ral.dst_config.wrap, item.a_data);
        dma_config.dst_addr_inc = get_field_val(ral.dst_config.increment, item.a_data);
      end
      "src_config", "src_control": begin
        `uvm_info(`gfn, $sformatf("Got src_config = %0x", item.a_data), UVM_HIGH)
        dma_config.src_chunk_wrap = get_field_val(ral.src_config.wrap, item.a_data);
        dma_config.src_addr_inc = get_field_val(ral.src_config.increment, item.a_data);
      end
      "addr_space_id": begin
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.src_asid = asid_encoding_e'(`gmv(ral.addr_space_id.src_asid));
        `uvm_info(`gfn, $sformatf("Got source address space id : %s",
                                  dma_config.src_asid.name()), UVM_HIGH)
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.dst_asid = asid_encoding_e'(`gmv(ral.addr_space_id.dst_asid));
        `uvm_info(`gfn, $sformatf("Got destination address space id : %s",
                                  dma_config.dst_asid.name()), UVM_HIGH)
      end
      "enabled_memory_range_base": begin
        if (dma_config.range_regwen == MuBi4True) begin
          dma_config.mem_range_base = item.a_data;
          `uvm_info(`gfn, $sformatf("Got enabled_memory_range_base = %0x",
                                    dma_config.mem_range_base), UVM_HIGH)
        end
      end
      "enabled_memory_range_limit": begin
        if (dma_config.range_regwen == MuBi4True) begin
          dma_config.mem_range_limit = item.a_data;
          `uvm_info(`gfn, $sformatf("Got enabled_memory_range_limit = %0x",
                                    dma_config.mem_range_limit), UVM_HIGH)
        end
      end
      "range_valid": begin
        if (dma_config.range_regwen == MuBi4True) begin
          dma_config.mem_range_valid = `gmv(ral.range_valid.range_valid);
          `uvm_info(`gfn, $sformatf("Got mem_range_valid = %x",
                                    dma_config.mem_range_valid), UVM_HIGH)
        end
      end
      "range_regwen": begin
        // Get mirrored field value and cast to associated enum in dma_config
        dma_config.range_regwen = mubi4_t'(`gmv(ral.range_regwen.regwen));
        `uvm_info(`gfn, $sformatf("Got range register lock = %s",
                                  dma_config.range_regwen.name()), UVM_HIGH)
      end
      "total_data_size": begin
        dma_config.total_data_size = item.a_data;
        `uvm_info(`gfn, $sformatf("Got total_data_size = %0x B",
                                  dma_config.total_data_size), UVM_HIGH)
      end
      "chunk_data_size": begin
        dma_config.chunk_data_size = item.a_data;
        `uvm_info(`gfn, $sformatf("Got chunk_data_size = %0x B",
                                  dma_config.chunk_data_size), UVM_HIGH)
      end
      "transfer_width": begin
        dma_config.per_transfer_width = dma_transfer_width_e'(
                                            `gmv(ral.transfer_width.transaction_width));
        `uvm_info(`gfn, $sformatf("Got transfer_width = %s",
                                  dma_config.per_transfer_width.name()), UVM_HIGH)
      end
      "clear_intr_bus": begin
        dma_config.clear_intr_bus = `gmv(ral.clear_intr_bus.bus);
      end
      "clear_intr_src": begin
        dma_config.clear_intr_src = `gmv(ral.clear_intr_src.source);
        clear_intr_src = dma_config.clear_intr_src;
      end
      "sha2_digest_0",
      "sha2_digest_1",
      "sha2_digest_2",
      "sha2_digest_3",
      "sha2_digest_4",
      "sha2_digest_5",
      "sha2_digest_6",
      "sha2_digest_7",
      "sha2_digest_8",
      "sha2_digest_9",
      "sha2_digest_10",
      "sha2_digest_11",
      "sha2_digest_12",
      "sha2_digest_13",
      "sha2_digest_14",
      "sha2_digest_15": begin
        `uvm_error(`gfn, $sformatf("this reg does not have write access: %0s",
                                       csr.get_full_name()))
      end
      "intr_src_addr_0",
      "intr_src_addr_1",
      "intr_src_addr_2",
      "intr_src_addr_3",
      "intr_src_addr_4",
      "intr_src_addr_5",
      "intr_src_addr_6",
      "intr_src_addr_7",
      "intr_src_addr_8",
      "intr_src_addr_9",
      "intr_src_addr_10": begin
        int index;
        `uvm_info(`gfn, $sformatf("Update %s", csr.get_name()), UVM_DEBUG)
        index = get_index_from_reg_name(csr.get_name());
        dma_config.intr_src_addr[index] = item.a_data;
      end
      "intr_src_wr_val_0",
      "intr_src_wr_val_1",
      "intr_src_wr_val_2",
      "intr_src_wr_val_3",
      "intr_src_wr_val_4",
      "intr_src_wr_val_5",
      "intr_src_wr_val_6",
      "intr_src_wr_val_7",
      "intr_src_wr_val_8",
      "intr_src_wr_val_9",
      "intr_src_wr_val_10": begin
        int index;
        `uvm_info(`gfn, $sformatf("Update %s", csr.get_name()), UVM_DEBUG)
        index = get_index_from_reg_name(csr.get_name());
        dma_config.intr_src_wr_val[index] = item.a_data;
      end
      "status": begin
        uvm_reg_data_t clearing = 0;
        clearing[IntrDmaDone]      = get_field_val(ral.status.done, item.a_data);
        clearing[IntrDmaChunkDone] = get_field_val(ral.status.chunk_done, item.a_data);
        clearing[IntrDmaError]     = get_field_val(ral.status.error, item.a_data);
        // Clearing the hardware contribution to the `intr_state` fields.
        intr_state_hw &= ~clearing;
        // Clearing the status bits also clears the corresponding Status-type interrupt(s) unless
        // the `intr_test` register is forcing them.
        predict_interrupts(CSRtoIntrLatency, clearing, intr_test & intr_enable);
      end
      "control": begin
        bit go, initial_transfer, start_transfer;
        // Update the 'Aborted' prediction in response to setting the CONTROL.abort bit
        // Note: this is a Write Only field so we cannot use the mirrored value
        abort_via_reg_write = get_field_val(ral.control.abort, item.a_data);
        // Abort overrides Go.
        go = get_field_val(ral.control.go, item.a_data) & ~abort_via_reg_write;
        initial_transfer = get_field_val(ral.control.initial_transfer, item.a_data);
        // Is this the very start of a DMA transfer, rather than each individual chunk?
        start_transfer = go & initial_transfer;
        `uvm_info(`gfn, $sformatf("CONTROL register written as 0x%0x", item.a_data), UVM_MEDIUM);
        if (abort_via_reg_write) begin
          `uvm_info(`gfn, "Aborting operation", UVM_LOW)
        end
        // Test bench/firmware is permitted to write to the Control register at the start of each
        // chunk but we must not reset our internal state; for non-initial chunks the Control
        // register write is just a nudge to proceed
        if (start_transfer) begin
          `uvm_info(`gfn, $sformatf("Got Start_Transfer = %0b", start_transfer), UVM_HIGH)
          // Get mirrored field value and cast to associated enum in dma_config
          dma_config.opcode = opcode_e'(`gmv(ral.control.opcode));
          `uvm_info(`gfn, $sformatf("Got opcode = %s", dma_config.opcode.name()), UVM_HIGH)
          // Get handshake mode enable bit
          dma_config.handshake = `gmv(ral.control.hardware_handshake_enable);
          `uvm_info(`gfn, $sformatf("Got hardware_handshake_mode = %0b", dma_config.handshake),
                    UVM_HIGH)
          // Get auto-increment and wrap bits
          dma_config.dst_chunk_wrap = `gmv(ral.dst_config.wrap);
          dma_config.src_chunk_wrap = `gmv(ral.src_config.wrap);
          dma_config.dst_addr_inc = `gmv(ral.dst_config.increment);
          dma_config.src_addr_inc = `gmv(ral.src_config.increment);

          `uvm_info(`gfn, $sformatf("dma_config\n %s",
                                    dma_config.sprint()), UVM_HIGH)
          // Check if configuration is valid;
          // Note: this may depend upon whether full SoC System bus testing has been waived.
          dma_config.dma_dv_waive_system_bus = cfg.dma_dv_waive_system_bus;
          dma_config.soc_system_hi_addr = cfg.soc_system_hi_addr;
          operation_in_progress = 1'b1;
          exp_src_addr = dma_config.src_addr;
          exp_dst_addr = dma_config.dst_addr;
          dma_config.is_valid_config = dma_config.check_config("scoreboard starting transfer");
          `uvm_info(`gfn, $sformatf("dma_config.is_valid_config = %b",
                                    dma_config.is_valid_config), UVM_MEDIUM)
          // Are we expecting an Error interrupt from an invalid configuration?
          predict_interrupts(GoToCfgErrLatency, 1 << IntrDmaError,
                             (!dma_config.is_valid_config << IntrDmaError) & intr_enable);
          // Expect digest to be cleared even for rejected configurations
          exp_digest = '{default:0};
          // Clear status variables
          num_bytes_read = 0;
          num_bytes_transferred = 0;
          num_bytes_checked = 0;
          fifo_intr_cleared = 0;
          // Expectation of bytes transferred before the first 'Chunk Done' or 'Done' signal
          exp_bytes_transferred = dma_config.handshake ? dma_config.total_data_size
                                                       : dma_config.chunk_size(0);
        end else if (!dma_config.handshake && go) begin
          // Status register is cleared, so all Status-type interrupts become deasserted.
          uvm_reg_data_t clearing;
          clearing = (1 << IntrDmaDone) | (1 << IntrDmaChunkDone) | (1 << IntrDmaError);
          predict_interrupts(CSRtoIntrLatency, clearing, 0);
          // Nudging a multi-chunk memory-to-memory transfer to proceed.
          operation_in_progress = 1'b1;
          // In memory-to-memory mode, DV/FW is advancing to the next chunk
          exp_bytes_transferred += dma_config.chunk_size(exp_bytes_transferred);
        end
        if (cfg.en_cov && go) begin
          logic [dma_reg_pkg::NumIntClearSources-1:0][2:0] intr_source_addr_offset;
          logic [dma_reg_pkg::NumIntClearSources-1:0][31:0] intr_source_wr_val;
          for (int unsigned i = 0; i < dma_reg_pkg::NumIntClearSources; i++) begin
            intr_source_addr_offset[i] = dma_config.intr_src_addr[i] % 8;
            intr_source_wr_val[i] = dma_config.intr_src_wr_val[i];
          end
          cov.config_cg.sample(.dma_config(dma_config),
                               .initial_transfer(initial_transfer));
          cov.interrupt_cg.sample(
            .handshake_interrupt_enable(dma_config.handshake_intr_en),
            .clear_intr_src(dma_config.clear_intr_src),
            .clear_intr_bus(dma_config.clear_intr_bus),
            .intr_source_addr_offset(intr_source_addr_offset),
            .intr_source_wr_val(intr_source_wr_val)
          );
        end
      end
      "handshake_intr_enable": begin
        dma_config.handshake_intr_en = `gmv(ral.handshake_intr_enable.mask);
        `uvm_info(`gfn,
                  $sformatf("Got handshake_intr_en = 0x%x", dma_config.handshake_intr_en), UVM_HIGH)
      end
      default: begin
        // This message may indicate a failure to update the configuration in the scoreboard
        // so that it matches the configuration programmed into the DUT
        `uvm_info(`gfn, $sformatf("reg_write of `%s` not handled", csr.get_name()), UVM_MEDIUM)
      end
    endcase
  endfunction

  // Method to process DMA register read
  function void process_reg_read(tl_seq_item item, uvm_reg csr);
    // After reads, if do_read_check is set, compare the mirrored_value against item.d_data
    bit do_read_check = 1'b1;
    `uvm_info(`gfn, $sformatf("Got reg_read to %s with addr : %0x and data : %0x ",
                              csr.get_name(), item.a_addr, item.a_data), UVM_HIGH)
    case (csr.get_name())
      "intr_state": begin
        `uvm_info(`gfn, $sformatf("intr_state = %0x", item.d_data), UVM_MEDIUM)
        // RAL is unaware of the combined contributions of `intr_test` and the `status` register.
        `DV_CHECK_EQ(item.d_data, intr_test | intr_state_hw, "Mismatched interrupt state")
        do_read_check = 1'b0;
      end
      "status": begin
        bit busy, done, chunk_done, aborted, error, sha2_digest_valid;
        bit exp_aborted = abort_via_reg_write;

        do_read_check = 1'b0;
        busy = get_field_val(ral.status.busy, item.d_data);
        done = get_field_val(ral.status.done, item.d_data);
        aborted = get_field_val(ral.status.aborted, item.d_data);
        error = get_field_val(ral.status.error, item.d_data);
        chunk_done = get_field_val(ral.status.chunk_done, item.d_data);
        sha2_digest_valid = get_field_val(ral.status.sha2_digest_valid, item.d_data);

        if (done || aborted || error || chunk_done ) begin
          string reasons;
          if (done)       reasons = "Done ";
          if (aborted)    reasons = {reasons, "Aborted "};
          if (error)      reasons = {reasons, "Error" };
          if (chunk_done) reasons = {reasons, "ChunkDone "};
          operation_in_progress = 1'b0;
          `uvm_info(`gfn, $sformatf("Detected status of DMA operation (%s)", reasons), UVM_MEDIUM)
          // Clear variables
          num_fifo_reg_write = 0;
        end
        // Check total data transferred at the end of DMA operation
        if (done && // `done` bit detected in STATUS
            !(aborted || error) && // no abort or error detected
           !(src_tl_error_detected || dst_tl_error_detected))
        begin // no TL error
          // Check if number of bytes transferred is as expected at this point in the transfer
          `DV_CHECK_EQ(num_bytes_transferred, exp_bytes_transferred,
                       $sformatf("act_data_size: %0d exp_data_size: %0d",
                                 num_bytes_transferred, exp_bytes_transferred))
        end
        // STATUS.aborted should only be true if we requested an Abort.
        // However, the transfer may just have completed successfully even if we did request an
        // Abort and it may even have terminated in response to a TL-UL error for some sequences.
        if (abort_via_reg_write) begin
          bit bus_error = src_tl_error_detected | dst_tl_error_detected;
          `DV_CHECK_EQ(|{aborted, bus_error, done}, 1'b1, "Transfer neither Aborted nor completed.")
          // Invalidate any still-pending interrupt changes; the abort may have occurred after
          // the final write has completed but before the DMA controller actually completes the
          // transfer because e.g. the SHA digest calculation is still completing.
          clear_intr_predictions();
        end else begin
          `DV_CHECK_EQ(aborted, 1'b0, "STATUS.aborted bit set when not expected")
        end
        if (cfg.en_cov) begin
          // Sample dma status and error code
          cov.status_cg.sample(.busy (busy),
                               .done (done),
                               .chunk_done (chunk_done),
                               .aborted (aborted),
                               .error (error),
                               .sha2_digest_valid (sha2_digest_valid));
        end
        // Check results after each chunk of the transfer (memory-to-memory) or after the complete
        // transfer (handshaking mode).
        if (dma_config.is_valid_config && (done || chunk_done)) begin
          if (num_bytes_transferred >= dma_config.total_data_size) begin
            // SHA digest (expecting zeros if unused)
            // When using inline hashing, sha2_digest_valid must be raised at the end
            if (dma_config.opcode inside {OpcSha256, OpcSha384, OpcSha512}) begin
              `DV_CHECK_EQ(sha2_digest_valid, 1, "Digest valid bit not set when done")
            end
            predict_digest(dma_config);
          end

          // Has all of the output already been checked?
          if (num_bytes_checked < num_bytes_transferred) begin
            bit [31:0] check_bytes = num_bytes_transferred - num_bytes_checked;
            bit [63:0] dst_addr = dma_config.dst_addr;
            bit [63:0] src_addr = dma_config.src_addr;

            if (dma_config.src_addr_inc && !dma_config.src_chunk_wrap) begin
              src_addr += num_bytes_checked;
            end
            if (dma_config.dst_addr_inc && !dma_config.dst_chunk_wrap) begin
              dst_addr += num_bytes_checked;
            end

            // TODO: we are still unable to check the final output data if in hardware-handshaking
            // mode and the destination chunks overlap but auto-increment _is_ used, i.e. it's not
            // using a FIFO model.
            if (dma_config.handshake && dma_config.dst_chunk_wrap && dma_config.dst_addr_inc) begin
              `uvm_info(`gfn, "Unable to check output data because of chunks overlapping", UVM_LOW)
            end else begin
              check_data(dma_config, src_addr, dst_addr, num_bytes_checked, check_bytes);
              num_bytes_checked += check_bytes;
            end
          end
        end
      end
      "error_code": begin
        bit [DmaErrLast-1:0] error_code;
        do_read_check = 1'b0;
        error_code[DmaSrcAddrErr]    = get_field_val(ral.error_code.src_addr_error, item.d_data);
        error_code[DmaDstAddrErr]    = get_field_val(ral.error_code.dst_addr_error, item.d_data);
        error_code[DmaOpcodeErr]     = get_field_val(ral.error_code.opcode_error, item.d_data);
        error_code[DmaSizeErr]       = get_field_val(ral.error_code.size_error, item.d_data);
        error_code[DmaBusErr]        = get_field_val(ral.error_code.bus_error, item.d_data);
        error_code[DmaBaseLimitErr]  = get_field_val(ral.error_code.base_limit_error, item.d_data);
        error_code[DmaRangeValidErr] = get_field_val(ral.error_code.range_valid_error, item.d_data);
        error_code[DmaAsidErr]       = get_field_val(ral.error_code.asid_error, item.d_data);
        if (cfg.en_cov) begin
          cov.error_code_cg.sample(.error_code (error_code));
        end
      end
      // Register read check for lock register
      "range_regwen": begin
        do_read_check = 1'b0;
      end
      "sha2_digest_0",
      "sha2_digest_1",
      "sha2_digest_2",
      "sha2_digest_3",
      "sha2_digest_4",
      "sha2_digest_5",
      "sha2_digest_6",
      "sha2_digest_7",
      "sha2_digest_8",
      "sha2_digest_9",
      "sha2_digest_10",
      "sha2_digest_11",
      "sha2_digest_12",
      "sha2_digest_13",
      "sha2_digest_14",
      "sha2_digest_15": begin
        int digest_idx = get_index_from_reg_name(csr.get_name());
        // By default, the hardware outputs little-endian data for each digest (32 bits). But DPI
        // functions expect output to be big-endian. Thus we should flip the expected value if
        // digest_swap is zero.
        bit [TL_DW-1:0] real_digest_val;

        do_read_check = 1'b0;
        real_digest_val = {<<8{item.d_data}};
        `uvm_info(`gfn, $sformatf("Checking SHA digest calulated 0x%0x expected 0x%0x",
                                  real_digest_val, exp_digest[digest_idx]), UVM_MEDIUM)
        `DV_CHECK_EQ(real_digest_val, exp_digest[digest_idx]);
      end
      default: do_read_check = 1'b0;
    endcase

    if (do_read_check) begin
      `DV_CHECK_EQ(csr.get_mirrored_value(), item.d_data, $sformatf("reg name: %0s",
                                                                    csr.get_full_name()))
      void'(csr.predict(.value(item.d_data), .kind(UVM_PREDICT_READ)));
    end
  endfunction

  // Main method to process transactions on register configuration interface
  virtual task process_tl_access(tl_seq_item item, tl_channels_e channel, string ral_name);
    uvm_reg csr;

    bit write = item.is_write();

    uvm_reg_addr_t csr_addr = cfg.ral_models[ral_name].get_word_aligned_addr(item.a_addr);
    // if access was to a valid csr, get the csr handle
    if (csr_addr inside {cfg.ral_models[ral_name].csr_addrs}) begin
      csr = cfg.ral_models[ral_name].default_map.get_reg_by_offset(csr_addr);
      `DV_CHECK_NE_FATAL(csr, null)
    end else begin
      `uvm_fatal(`gfn, $sformatf("\naccess unexpected addr 0x%0h", csr_addr))
    end

    // The access is to a valid CSR, now process it.
    // writes -> update local variable and fifo at A-channel access
    // reads  -> update prediction at address phase and compare at D-channel access
    if (write && channel == AddrChannel) begin
      process_reg_write(item, csr);
    end  // addr_phase_write

    if (!write && channel == DataChannel) begin
      process_reg_read(item,csr);
    end  // data_phase_read
  endtask : process_tl_access

  // query the SHA model to get expected digest
  // update predicted digest to ral mirrored value
  virtual function void predict_digest(ref dma_seq_item dma_config);
    case (dma_config.opcode)
      OpcSha256: begin
        cryptoc_dpi_pkg::sv_dpi_get_sha256_digest(cfg.src_data, exp_digest[0:7]);
        exp_digest[8:15] = '{default:0};
      end
      OpcSha384: begin
        cryptoc_dpi_pkg::sv_dpi_get_sha384_digest(cfg.src_data, exp_digest[0:11]);
        exp_digest[12:15] = '{default:0};
      end
      OpcSha512: begin
        cryptoc_dpi_pkg::sv_dpi_get_sha512_digest(cfg.src_data, exp_digest[0:15]);
      end
      default: begin
        // When not using inline hashing mode
        exp_digest = '{default:0};
      end
    endcase
  endfunction

  function dma_pkg::asid_encoding_e if_name_to_asid(string if_name);
    case (if_name)
      "host": return dma_pkg::OtInternalAddr;
      "ctn":  return dma_pkg::SocControlAddr;
      "sys":  return dma_pkg::SocSystemAddr;
      default: begin
        `dv_error("Unknown interface name: %0s", if_name)
      end
    endcase
  endfunction

endclass
