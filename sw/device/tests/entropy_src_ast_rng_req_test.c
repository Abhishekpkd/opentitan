// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "sw/device/lib/base/memory.h"
#include "sw/device/lib/base/mmio.h"
#include "sw/device/lib/dif/dif_entropy_src.h"
#include "sw/device/lib/runtime/ibex.h"
#include "sw/device/lib/runtime/log.h"
#include "sw/device/lib/testing/test_framework/check.h"
#include "sw/device/lib/testing/test_framework/ottf_main.h"

OTTF_DEFINE_TEST_CONFIG();

enum {
  /**
   * The size of the buffer used in firmware to process the entropy bits in
   * firmware override mode.
   */
  kEntropyFifoBufferSize = 16,
};

static uint32_t read_fifo_depth(dif_entropy_src_t *entropy) {
  uint32_t fifo_depth = 0;
  CHECK_DIF_OK(dif_entropy_src_get_fifo_depth(entropy, &fifo_depth));
  return fifo_depth;
}

bool test_main(void) {
  dif_entropy_src_t entropy_src;
  CHECK_DIF_OK(dif_entropy_src_init_from_dt(kDtEntropySrc, &entropy_src));

  CHECK_DIF_OK(dif_entropy_src_set_enabled(&entropy_src, kDifToggleDisabled));

  const dif_entropy_src_fw_override_config_t fw_override_config = {
      .entropy_insert_enable = true,
      .buffer_threshold = kEntropyFifoBufferSize,
  };
  CHECK_DIF_OK(dif_entropy_src_fw_override_configure(
      &entropy_src, fw_override_config, kDifToggleEnabled));

  // Program the entropy src in normal RNG mode.
  const dif_entropy_src_config_t config = {
      .fips_enable = true,
      .fips_flag = true,
      .rng_fips = true,
      // Route the entropy data received from RNG to the FIFO.
      .route_to_firmware = true,
      .single_bit_mode = kDifEntropySrcSingleBitModeDisabled,
      .health_test_threshold_scope = false, /*default*/
      .health_test_window_size = 0x0800,    /*default*/
      .alert_threshold = 2,                 /*default*/
  };
  CHECK_DIF_OK(
      dif_entropy_src_configure(&entropy_src, config, kDifToggleEnabled));

  // Verify that the FIFO depth is non-zero via SW - indicating the reception of
  // data over the AST RNG interface.
  IBEX_SPIN_FOR(read_fifo_depth(&entropy_src) > 0, 6000);

  return true;
}
