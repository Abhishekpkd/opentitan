// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
{
  name: "otp_ctrl"
  import_testplans: ["hw/dv/tools/dvsim/testplans/csr_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/mem_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/intr_test_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/alert_test_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/tl_device_access_types_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/sec_cm_count_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/sec_cm_fsm_testplan.hjson",
                     "hw/dv/tools/dvsim/testplans/stress_all_with_reset_testplan.hjson",
                     "otp_ctrl_sec_cm_testplan.hjson"]
  testpoints: [
    {
      name: wake_up
      desc: '''
            Wake_up test walks through otp_ctrl's power-on initialization, read, program, and
            digest functionalities.

            - drive pwrmgr's request pin to trigger OTP initialization after reset, check status
              after OTP initialization
            - write all-ones to a random address within OTP partition 0, wait until this operation
              completes
            - read out the random selected write address, check if the readout value is all-ones
            - trigger a digest calculation for a Software partition, check if the OtpError
              interrupt is set
            - trigger a digest calculation for a non-software partition, expect operation completes
              without the OtpError interrupt
            - read out secrets through the hardware interfaces
            '''
      stage: V1
      tests: ["otp_ctrl_wake_up"]
    }
    {
      name: smoke
      desc: '''
            OTP_CTRL smoke test provisions and locks partitions.

            - drive pwrmgr's request pin to trigger OTP initialization after reset, check status
              after OTP initialization
            - randomly read out keys pertaining to `key_manager`, `flash`, `sram`, `otbn`
            - randomly issue LC program request
            - write random values to random addresses within each OTP partition
            - read out the random selected write addresses, check if the readout values are expected
            - during read and write operations, check if direct_access_regwen is correctly set by HW
            - perform a system-level reset and check corresponding CSRs are set correctly
            - lock all partitions except life_cycle by triggering digest calculations
            - read back and verify the digest
            - perform a system-level reset to verify the corresponding CSRs exposing the digests
              have been populated

            **Checks**:
            - Assertion checks to ensure vendor specific I/Os: `otp_vendor_test_status_o`,
              `otp_vendor_test_ctrl_i`, `cio_test_o`, and `cio_test_en_o` are connected currently
              with `lc_dft_en_i` On and Off.
            '''
      stage: V1
      tests: ["otp_ctrl_smoke"]
    }
    {
      name: dai_access_partition_walk
      desc: '''
            Similar to UVM's memory walk test, this test ensures every address in each partition
            can be accessed successfully via DAI and TLUL interfaces according to its access policy.
            '''
      stage: V2
      tests: ["otp_ctrl_partition_walk"]
    }
    {
      name: init_fail
      desc: '''
            Based on OTP_CTRL smoke test, this test creates OTP_CTRL's initialization failure:
            - write and read OTP memory via DAI interface
            - randomly issue DAI digest command to lock HW partitions
            - keep writing to OTP memory via DAI interface without asserting reset
            - if digests are not locked, backdoor inject ECC correctable or uncorrectable errors
            - issue reset and power initialization
            - if the injected errors are all correctable errors, disable the `lc_bypass_chk_en`
              after LC program request to create an LC partition check failure

            If fatal error is triggered, this test will check:
            - OTP initialization failure triggers fatal alert
            - `status`, `intr_state`, `err_code` CSRs reflect correct fatal error

            If OTP initialization finished without any fatal error, this test will check:
            - OTP initialization finishes with power init output goes to 1
            - `status`, `intr_state`, `err_code` CSRs reflect ECC correctable error
            '''
      stage: V2
      tests: ["otp_ctrl_init_fail"]
    }
    {
      name: partition_check
      desc: '''
            Randomly program the partition check related CSRs including:
            - `check_timeout`
            - `integrity_check_period`
            - `consistency_check_period`
            - `check_trigger`

            Create a failure scenario by randomly picking one of these three methods:
            - inject ECC errors into the OTP macro via backdoor
            - set the `check_timeout` CSR with a very small value
            - write to a random OTP partition after digest is issued but before reset is asserted

            **Checks**:
            - the corresponding alerts are triggered
            - the error_code register is set correctly
            Note that due to limited simulation time, for background checks, this test only write
            random value that is less than 20 to the check period.
            '''
      stage: V2
      tests: ["otp_ctrl_check_fail", "otp_ctrl_background_chks"]
    }
    {
      name: regwen_during_otp_init
      desc: '''
            The `direct_access_regwen` is a RO register which controls the write-enable of other
            registers. It is not verified by the common CSR tests. HW sets it to 0 when the DAI
            interface is busy.

            Stimulus and checks:
            - randomly read `direct_access_regwen` and verify that it returns 0 during OTP
              initialization
            - verify that the writes to the registers controlled by it do not go through during OTP
              initialization
            '''
      stage: V2
      tests: ["otp_ctrl_regwen"]
    }
    {
      name: partition_lock
      desc: '''
            This test will cover two methods of locking read and write: digest calculation and CSR
            write. After locking the partitions, issue read or program sequences and check if the
            operations are locked correctly, and check if the `AccessError` is set.
            '''
      stage: V2
      tests: ["otp_ctrl_dai_lock"]
    }
    {
      name: interface_key_check
      desc: '''
            OTP_CTRL will generate keys to `flash`, `sram`, and `otbn` upon their requests.
            Based on the DAI access sequence, this test will run key requests sequence in
            parallel, and check if correct keys are generated.
            '''
      stage: V2
      tests: ["otp_ctrl_parallel_key_req"]
    }
    {
      name: lc_interactions
      desc: '''
            Verify the protocols between OTP_CTRL and LC_CTRL. Based on the DAI access sequence,
            run the following sequences in parallel:

            - request a LC state transition via the programming interface
            - enable the `lc_escalation_en` signal

            **Checks**:
            - if the LC program request has `AccessError`, check the LC program response sets
              the `error` bit to 1
            - if `lc_escalation_en` is enabled, verify that alert is triggered and OTP_CTRL entered
              terminal state
            '''
      stage: V2
      tests: ["otp_ctrl_parallel_lc_req", "otp_ctrl_parallel_lc_esc"]
    }
    { name: otp_dai_errors
      desc: '''
            Based on the otp_dai_lock test, this test will randomly run the following OTP errors:
            - DAI interface writes non-blank OTP address
            - DAI interface accesses LC partition
            - DAI interface writes HW digests
            - DAI interface writes non-empty memory

            **Checks**:
            - `err_code` and `status` CSRs
            - `otp_error` interrupt
            '''
      stage: V2
      tests: ["otp_ctrl_dai_errs"]
    }
    { name: otp_macro_errors
      desc: '''
            Randomly run the following OTP errors:
            - MacroError
            - MacroEccCorrError
            - MacroEccUncorrError

            **Checks**:
            - `err_code` and `status` CSRs
            - `otp_error` interrupt
            - if the error is unrecoverable, verify that alert is triggered and OTP_CTRL entered
              terminal state
            '''
      stage: V2
      tests: ["otp_ctrl_macro_errs"]
    }
    {
      name: test_access
      desc: '''
            This test checks if the test access to OTP macro is connected correctly.

            **Stimulus and Checks**:
            - Write and check read results from the prim_tl_i/o.
            - Ensure no error or alert occurs from DUT.
            '''
      stage: V2
      tests: ["otp_ctrl_test_access"]
    }
    {
      name: stress_all
      desc: '''
            - combine above sequences in one test to run sequentially, except csr sequence
            - randomly add reset between each sequence
            '''
      stage: V2
      tests: ["{name}_stress_all"]
    }
    {
      name: sec_cm_additional_check
      desc: '''
            Verify the outcome of injecting faults to security countermeasures.

            Stimulus:
            As mentioned in `prim_count_check`, `prim_fsm_check` and `prim_double_lfsr_check`.

            Checks:
            - Check the value of status register according to where the fault is injected.
            - Check OTP_CTRL is locked after the fatal fault injection by trying to access OTP_CTRL
              via dai, kdi, and lci interfaces.
            '''
      stage: V2S
      tests: ["otp_ctrl_sec_cm"]
    }
    {
      name: otp_ctrl_low_freq_read
      desc: '''
            This test checks if OTP's read operation can operate successfully in a low clock
            frequency before the clock is calibrated.

            **Stimulus and Checks**:
            - Configure OTP_CTRL's clock to 6MHz low frequency.
            - Backdoor write OTP memory.
            - Use DAI access to read each memory address and compare if the value is correct.
            - If DAI address is in a SW partition, read and check again via TLUL interface.
            '''
      stage: V3
      tests: ["otp_ctrl_low_freq_read"]
    }
  ]

  covergroups: [
    {
      name: power_on_cg
      desc: '''Covers the following conditions when OTP_CTRL finishes power-on initialization:
            - whether `lc_escalation_en` is On
            - whether any partition (except life cycle partition) is locked
            '''
    }
  % if enable_flash_key:
    {
      name: flash_req_cg
      desc: '''Covers whether secret1 partition is locked during `flash` data or address
            request.'''
    }
  % endif
    {
      name: sram_req_cg
      desc: '''Covers whether secret1 partition is locked during all `srams` key request.'''
    }
    {
      name: otbn_req_cg
      desc: '''Covers whether secret1 partition is locked during `otbn` key request.'''
    }
    {
      name: lc_prog_cg
      desc: '''Covers whether the error bit is set during LC program request.'''
    }
    {
      name: keymgr_o_cg
      desc: '''Covers the following conditions when scoreboard checks `keymgr_o` value:
            - whether secret2 partition is locked
            - whether `lc_seed_hw_rd_en_i` is On
            '''
    }
    {
      name: req_dai_access_after_alert_cg
      desc: '''Covers if sequence issued various DAI requests after any fatal alert is
            triggered.'''
    }
    {
      name: issue_checks_after_alert_cg
      desc: '''Covers if sequence issued various OTP_CTRL's background checks after any fatal alert
            is triggered.'''
    }
    {
      name: csr_rd_after_alert_cg
      desc: '''Covers if the following CSRs are being read and the value is checked in scoreboard
            after any fatal alert is triggered:
            - unbuffered partitions' digest CSRs
            - HW partition's digest CSRs
            - secrets partitions' digest CSRs
            - direct_access read data CSRs
            - status CSR
            - error_code CSR
            '''
    }
    {
      name: dai_err_code_cg
      desc: '''Covers all applicable error codes in DAI, and cross each error code with all
               7 partitions.'''
    }
    {
      name: lci_err_code_cg
      desc: '''Covers all applicable error codes in LCI.'''
    }
    {
      name: unbuf_err_code_cg
      desc: '''This is an array of covergroups to cover all applicable error codes in three
            unbuffered partitions.'''
    }
    {
      name: buf_err_code_cg
      desc: '''This is an array of covergroups to cover all applicable error codes in five
            buffered partitions.'''
    }
    {
      name: unbuf_access_lock_cg_wrap_cg
      desc: '''This is an array of covergroups to cover lock conditions below in three
            unbuffered partitions:
            - the partition is write-locked
            - the partition is read-locked
            - the current operation type
            Then cross the three coverpoints.'''
    }
    {
      name: dai_access_secret2_cg
      desc: '''Covers whether `lc_creator_seed_sw_rw_en` is On during any DAI accesses.'''
    }
    {
      name: status_csr_cg
      desc: '''Covers the value of every bit in `status` CSR.'''
    }
    // The following covergroups are implemented in `otp_ctrl_cov_if.sv`.
    {
      name: lc_esc_en_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether LC program request is in progress
            - whether DAI interface is busy
            '''
    }
  % if enable_flash_key:
    {
      name: flash_data_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
    {
      name: flash_addr_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
  % endif
    {
      name: sram_0_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
    {
      name: sram_1_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
    {
      name: otbn_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
    {
      name: lc_prog_req_condition_cg
      desc: '''Covers the following conditions when `lc_escalation_en` is On:
            - whether any key requests is in progress
            - whether DAI interface is busy
            - whether lc_esc_en is On
            '''
    }
  ]
}
