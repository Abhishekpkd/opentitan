# Comportability Definition and Specification

## Document Goals

This document is aimed at laying out the definition of a *Comportable IP design*, i.e. one that is ported to conform to the framework of lowRISC ecosystem IP, suitable for inclusion in compliant designs.
This is primarily a technical discussion and specification of interface compliance within the framework.
Separate documents contain or will contain critical elements like coding style, verification, and documentation, but are not the purview of this specification.

A good definition of Comportable can be found in
[Johnson's Dictionary of the English Language](https://en.wikipedia.org/wiki/A_Dictionary_of_the_English_Language).
The 1808 miniature edition gives
["Comportable, a. consistent, suitable, fit"](https://books.google.co.uk/books?id=JwC-GInMrW4C&dq=%22comportable%22&pg=PA45&ci=31%2C225%2C415%2C42&source=bookclip)

![scan of definition on page 45](https://books.google.co.uk/books/content?id=JwC-GInMrW4C&pg=PA45&img=1&zoom=3&hl=en&sig=ACfU3U3-RHKNO-UV3r7xOGeK1VigzCl3-w&ci=31%2C225%2C415%2C42&edge=0)



## Definitions

The table below lists some keywords used in this specification.

| Keyword | Definition |
| --- | --- |
| alerts      | Interrupt-type outputs of IP designs that are classified as security critical. These have special handling in the outer chip framework. |
| comportable | A definition of compliance on the part of IP that is able to plug and play with other IP to form the full chip framework. |
| CSRs        | Control and Status Registers; loosely the collection of registers within a peripheral which are addressable by the (local) host processor via a chip-wide address map.  Special care is dedicated to the definition and handling of CSRs to maximize software uniformity and re-use, as well as documentation consistency. |
| framework   | this project concerns itself not only with compliant IP, but also provides a full chip framework suitable for FPGA implementation, and prepared to be the foundation for a full silicon implementation. This could roughly be translated as Top Level Netlist. |
| interrupts  | Non-security critical signals from peripheral devices to the local host processor within the framework SOC. |
| MIO         | Multiplexable IO; a pad at the top chip level which can be connected to one of the peripherals' MIO-ready inputs or outputs. |
| peripheral  | Any comportable IP that is part of the library, outside of the local host processor. |

## Non-Technical Comportability Requirements

All comportable IP must adhere to a few requirements, briefly discussed here.

### License and copyright

All files should include a comment with a copyright message.
This is normally "lowRISC contributors (OpenTitan project)".
The style is to not include a year in the notice.
Files adapted from other sources should retain any copyright messages and include details of the upstream location.

The Apache License, Version 2.0 is the default for all files in the repository.
Use of other licenses must be noted (and care is needed to ensure compatibility with the rest of the code).
All files should include a comment line with the SPDX-License-Identifier: tag and the Identifier from the [License List](https://spdx.org/licenses/).
An additional "Licensed under" line may be used to give a more human readable version.
If the file is not covered by a SPDX license then the "Licensed under" line is required (note that such files are unlikely to be permitted in the main open source repository).

All files that use the default copyright and license should therefore include the following header (change the comment character as appropriate):

```
// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
```

The project has adopted [Hjson](https://hjson.github.io/) for JSON files, extending JSON to allow comments.
Thus the Hjson files can include the header above.
If pure JSON must be used for some reason, the "SPDX-License-Identifier:" can be added as the first key after the opening "{".
Tools developed by the project should accept and ignore this key.

### Coding Style

All IP must follow the [lowRISC Verilog Coding Style Guide](https://github.com/lowRISC/style-guides/blob/master/VerilogCodingStyle.md).
This style guide sets the definition of agreed-upon SystemVerilog style, requirements and preferences.
See that document for details.
It is the goal of lowRISC to create technical collateral to inform when an IP does not conform, as well as assist in the formatting of Verilog to this style.
The methods and details for this collateral have not been agreed upon yet.

### Documentation

All lowRISC IP must conform to a common specification and documentation format.
lowRISC will release a template for IP specifications in a separate document for reference.
It is notable that register tooling auto-creates documentation material for register definitions, address maps, hardware interfaces, etc.
The hardware interfaces of this process is discussed later in this document.

## Comportable Peripheral Definition

All comportable IP peripherals must adhere to a minimum set of functionality in order to be compliant with the framework that is going to be set around it.
(An example framework is the [earlgrey top level design](../../../../hw/top_earlgrey/README.md).)
This includes several mandatory features as well as several optional ones.
It is notable that the framework contains designs that are neither the local host processor nor peripherals \- for example the power management unit, clock generators.
These are handled as special case designs with their own specifications.
Similarly the memory domain is handled separately and in its own specification.

Examples of peripherals that are expected to be in this category include ones with primary inputs and outputs (SPI, I2C, etc);
offload and specialty units (crypto, TRNG, key manager); timers; analog designs (temperature sensor); as well as bus hosts<sup>1</sup> (DMA).

<sup>1</sup>lowRISC is avoiding the fraught terms master/slave and defaulting to host/device where applicable.

### Feature List

All comportable designs must specify and conform to a list of mandatory features, and can optionally specify and conform to a list of optional features.
These are briefly summarized in the table below, and are covered individually in the sections that follow.
For most of these, the definition of the feature is in the form of a configuration file.
This file is specified later within this document.

| Feature | Mand/Opt | Description |
| ---     | ---      | --- |
| Clocking     | mandatory | Each peripheral must specify what its primary functional clock is, and any other clocks needed.  The primary clock is the one driving the bus the peripheral is receiving.  The clocking section lists the available clocks. Other clocks can be designated as needed. |
| Bus Interfaces | mandatory | A list of the bus interfaces that the peripheral supports. This must contain at least one device entry. More details in the Bus Interfaces section. |
| Available IO | optional  | Peripherals can optionally make connections to dedicated or multiplexed IO pins; the chip peripheral needs to indicate its module inputs and outputs that are available for this purpose. Details are available in the peripheral IO section below. |
| Registers    | mandatory | Each peripheral must define its collection of registers in the specified register format.  The registers are automatically generated in the form of hardware, software, and documentation collateral. Details are available in the register section. |
| Interrupts   | optional  | Peripherals have the option of generating signals that can be used to interrupt the primary processor.  These are designated as a list of signals, and each results in a single wire or bundled output that is sent to the processor to be gathered as part of its interrupt vector input.  Details can be found in the interrupt and alert section. |
| Alerts       | optional  | Peripherals have the option of generating signals that indicate a potential security threat. These are designated as a list of signals, and each results in a complementary signal pair that is sent to the alert handling module.  Details are found in the interrupt and alert section. |
| Inter Signal | optional  | Peripherals have the option of struct signals that connect from/to other peripherals, which are called as Inter-Module Signals in OpenTitan. Details are found in the inter module section.
| (more)       |           | More will come later, including special handling for testability, power management, device entropy, etc. |

![Typical Peripheral Block Diagram](comportability_diagram_peripheral.svg)

**Figure 1**: Typical peripheral communication channels within full chip framework.

In this diagram the auto-generated register submodule is shown within the peripheral IP, communicating with the rest of the chip framework using the TL-UL (see below) bus protocol.
This register block communicates with the rest of the peripheral logic to manage configuration and status communication with software.
Also shown is the mandatory clock, and the optional bus (TL-UL) host, interrupts, alerts, and chip IO.

## Peripheral Feature Details

### Configuration File

Each peripheral contains a configuration file that describes the peripheral features that are mandatory and optional in the above comportability feature list.
The configuration file format is given below.

### Clocking

Each peripheral specifies how it is clocked and reset.
This is done with the `clocking` element, whose value is a nonempty list of dictionaries.
Each dictionary (called a *clocking item*) defines a clock and reset signal.
The clock signal is the field called `clock`.
The reset signal is the field called `reset`.

One of the clocking items is called the *primary clock*.
If there is just one item, that is the primary clock.
If there are several, exactly one of the items' dictionaries should also have a boolean field called `primary` set to true.
This primary clock used to clock any device interfaces, indicating to the top level if asynchronous handling of the bus interface is needed.

Resets within the design are **asynchronous active low** (see below).
Special care will be required for security sensitive storage elements.
Further instructions on the handling of these storage elements will come at a later date.

For most blocks, each clocking item has one clock and one reset signal.
However, there are a few blocks where this might not be true (blocks that generate clocks or resets).
To allow these blocks to be described, the `clock` and `reset` fields of an item are optional.
However, the primary clock must have both.

#### Details and rationale for asynchronous active low reset strategy

Resets within the design are asynchronous active low, where the assertion of the reset is asynchronous to any clock, but deassertion is synchronized to the clock of the associated storage element.
The selection of asynchronous active low (as opposed to say synchronous active high) was made based upon a survey of existing design IP, comfort level of project team members, and through security analysis.
The conclusion roughly was the following:

1. Security storage elements might "leak" sensitive state content, and should be handled with care regardless of reset methodology.
By "care" an example would be to reset their value synchronously at a time after chip-wide reset, to a value that is randomized so that the Hamming distance between the register value and all zeros cannot produce information available to an attacker.
2. For control path and other storage elements, the selection of asynchronous active low vs. synchronous active high is often a "religious" topic, with both presenting pros and cons.
3. Asynchronous active low incurs slightly more area and requires more hand-holding, but is more common.
4. Synchronous active high is slightly more efficient, but requires the existence of a clock edge to take effect.

Based upon this and the fact that much of the team history was with asynchronous active low reset, we chose that methodology with added requirements that special care be applied for security state, the details of which will come at a later date.

### Bus Interfaces

Peripherals can connect to the chip bus.
All peripherals are assumed to have registers, and are thus required to expose at least one device interface on the chip bus.
Peripherals can act as a bus host on some occasions, though for full chip simplicity the preferred model is for the processor to be primary host.
An example of a peripheral that acts as a host is a DMA unit.

The arrangement of peripherals' device interfaces into a system-wide address map is controlled by a higher level full-chip configuration file.
Addresses within the block of addresses assigned to a device interface are defined by the peripheral's configuration file.

The `bus_interfaces` attribute in the configuration file should contain a list of dictionaries, describing the interfaces that the peripheral exposes.
The full syntax for an entry in the list looks like this:
```
{ protocol: "tlul", direction: "device", name: "my_interface" }
```

For each entry, the `protocol` field gives the protocol that the peripheral uses to connect to the bus.
All peripherals use TileLink-UL (TileLink-Uncached-Lite, aka TL-UL) as their interface to the framework.
To signify this, the peripheral must have a protocol of `tlul`.
The TileLink-UL protocol and its usage within lowRISC devices is given in the
[TileLink-UL Bus Specification](../../../../hw/ip/tlul/README.md).
As of this writing, there are no other options, but this field leaves an option for extension in the future.

Each entry must also contain a `direction`.
This must either be `host` or `device`.
All bus hosts must use the same clock as the defined primary host clock.
Each bus host is provided a 4-bit host ID to distinguish hosts within the system.
This is done by the framework in order to ensure uniqueness.
The use of the ID within the bus fabric is discussed in the bus specification.

An entry may also include a name.
This name is added as a prefix to the module's top-level port names.
This is optional unless there is another entry in the list with the same direction (in which case, the port names would collide).

### Available IO

Each peripheral has the option of designating signals (inputs, outputs, or inouts) available to be used for chip IO.
The framework determines for each signal if it goes directly to a dedicated chip pin or is multiplexed with signal(s) from other peripherals before reaching a pin.

Designation of available IO is given with the configuration file entries of `available_input_list`, `available_output_list`, and `available_inout_list`.
These can be skipped, or contain an empty list `[]`, or a comma-separated list of signal names.
Items on the input list of the form `name` incur a module input of the form `cio_name_i`.
Items on the output list of the form `name` incur a module output of the form `cio_name_o` as well as an output enable `cio_name_en_o`.
Items on the inout list of the form `name` incur all three.

#### Multiplexing Feature and Pad Control

In the top level chip framework there is a pin multiplexing unit (`pinmux`), for example the [Earlgrey pinmux](../../../../hw/top_earlgrey/ip_autogen/pinmux/README.md), which provides flexible assignment to/from peripheral IO and chip pin IO.
Comportable peripherals do not designate whether their available IO are hardwired to chip IO, or available for multiplexing.
That is done at the top level with an Hjson configuration file.
See the top level specification for information about that configuration file.

In addition, full pad control is not done by the peripheral logic, but is done, by the `pinmux` as well.
The `pinmux` module provides software configuration control over pad drive strength, pin mapping, pad type (push/pull, open drain, etc).

### Interrupts

Each peripheral has the option of designating output signals as interrupts destined for the local host processor.
These are non-security-critical signals sent to the processor for it to handle with its interrupt service routines.
The peripheral lists its collection of interrupts with the `interrupt_list` attribute in the configuration file.
Each item of the form `name` in the interrupt list expects a module output named `intr_name_o`.

See the section on [Interrupt Handling](#interrupt-handling) below, which defines details on register, hardware, and software uniformity for interrupts within the project.

### Alerts

Each peripheral has the option of designating output signals as security critical alerts destined for the hardware [alert handler module](../../../../hw/top_earlgrey/ip_autogen/alert_handler/README.md).
These are differential signals (to avoid single point of failure) sent to the alert handler for it to send to the processor for first-line defense handling, or hardware security response if the processor does not act.
The peripheral lists its collection of alerts with the `alert_list` attribute in the configuration file.
For each alert in the full system, a corresponding set of signals will be generated in the alert handler to carry out this communication between alert sender and handler.

See the section on [Alert Handling](#alert-handling) below, which defines details on register, hardware, and software uniformity for alerts within the project.

### Inter-module signal

The peripherals in OpenTitan have optional signals connecting between the peripherals other than the interrupts and alerts.
The peripheral lists its collection of inter-module signals with the `inter_signal_list` attribute in the configuration file.
The peripheral defines the type of inter-module signals.
The connection between the modules are defined in the top-level configuration file.

See the section on [Inter Signal Handling](#inter-signal-handling) below for detailed data structure in the configuration file.

### Security countermeasures

If this IP block is considered security-critical, it will probably have design features that try to mitigate against attacks like fault injection or side channel analysis.
These features can be loosely categorised and named with identifiers of the following form:

```
[UNIQUIFIER.]ASSET.CM_TYPE
```

Here, `ASSET` is the asset that is being protected.
This might be secret information like a key, or it might be internal state like a processor's control flow.
The countermeasure that is providing the protection is named with `CM_TYPE`.
The `UNIQUIFIER` label is optional and allows to add a custom prefix to make the identifier unique or more concise.

Below are a few examples for generic and more concise labels following this format:

```
LFSR.REDUN or MASKING_PRNG.LFSR.REDUN
FSM.SPARSE or HASHING_INTERFACE.FSM.SPARSE
INTERSIG.MUBI or ALERT.INTERSIG.MUBI
```

The following standardised assets are defined:

| Asset name | Intended meaning |
| --- | --- |
| KEY         | A key (secret data) |
| ADDR        | An address |
| DATA_REG    | A configuration data register that doesn't come from software (such as Keccak state) |
| DATA_REG_SW | A data holding register that is manipulated by software |
| CTRL_FLOW   | The control flow of software or a module |
| CTRL        | Logic used to steer hardware behavior |
| CONFIG      | Software-supplied configuration, programmed through the comportable register interface |
| LFSR        | A linear feedback shift register |
| RNG         | A random number generator |
| CTR         | A counter |
| FSM         | A finite state machine |
| MEM         | A generic data memory; volatile or non-volatile |
| CLK         | A clock |
| RST         | A reset signal |
| BUS         | Data transferred on a bus |
| INTERSIG    | A non-bus signal between two IP blocks |
| MUX         | A multiplexer that controls propagation of sensitive data |
| CONSTANTS   | A netlist constant |
| STATE       | An internal state signal (other than FSM state, which is covered by the FSM label) |
| TOKEN       | A cryptographic token |
| LOGIC       | Any logic. This is a very broad category: avoid if possible and give an instance or net name if not. |

The following standardised countermeasures are defined:

| Countermeasure name | Intended meaning | Commonly associated assets |
| --- | --- | --- |
| MUBI           | A signal is multi-bit encoded | CTRL, CONFIG, CONSTANTS, INTERSIG |
| SPARSE         | A signal is sparsely encoded  | FSM |
| DIFF           | A signal is differentially encoded | CTRL, CTR |
| REDUN          | There are redundant versions of the asset | ADDR, CTRL, CONFIG, CTR
| REGWEN         | A register write enable is used to protect the asset from write access | CONFIG, MEM
| REGWEN_MUBI    | A multi-bit encoded register write enable is used to protect the asset from write access | CONFIG, MEM
| SHADOW         | The asset has a shadow replica to cross-check against | CONFIG
| REGREN         | A register write enable is used to protect the asset from read access | CONFIG, MEM
| SCRAMBLE       | The asset is scrambled | CONFIG, MEM
| INTEGRITY      | The asset has integrity protection from a computed value such as a checksum | CONFIG, REG, MEM
| READBACK       | A readback check is performed to validate that the asset has been correctly modified or fetched | MEM
| ADDR_INFECTION | The asset is infected using the read address | MEM
| CONSISTENCY    | This asset is checked for consistency other than by associating integrity bits | CTRL, RST
| DIGEST         | Similar to integrity but more computationally intensive, implying a full hash function | CONFIG, REG, MEM
| LC_GATED       | Access to the asset is qualified by life-cycle state | REG, MEM, CONSTANTS, CONFIG
| BKGN_CHK       | The asset is protected with a continuous background health check |
| GLITCH_DETECT  | The asset is protected by an analog glitch detector | CTRL, FSM, CLK, RST
| SW_UNREADABLE  | The asset is not readable by software | MEM, KEY
| SW_UNWRITABLE  | The asset is not writable by software | MEM, KEY
| SW_NOACCESS    | The asset is not writable nor readable by software (SW_UNWRITABLE and SW_UNREADABLE at the same time) | MEM, KEY
| SIDELOAD       | The asset can be loaded without exposing it to software | KEY
| SEC_WIPE       | The asset is initialized or cleared using pseudo-random data | KEY, DATA_REG, MEM
| SCA            | A countermeasure that provides side-channel attack resistance |
| MASKING        | A more specific version of SCA where an asset is split into shares |
| LOCAL_ESC      | A local escalation event is triggered when an attack is detected |
| GLOBAL_ESC     | A global escalation event is triggered when an attack is detected |
| UNPREDICTABLE  | Behaviour is unpredictable to frustrate repeatable FI attacks |
| TERMINAL       | The asset goes into a terminal state that no longer responds to any stimulus |
| COUNT          | The number of operations or items processed is counted which can be checked by software to ensure the correct number have occurred |
| CM             | Catch-all for countermeasures that cannot be further specified. This is a very broad category: avoid if possible and give an instance or net name if not. |

## Register Handling

The definition and handling of registers is a topic all on its own, and is specified in its [own document](../../../../util/reggen/README.md).
All lowRISC peripheral designs must conform to this register specification.

## Configuration description Hjson

The description of the IP block and its registers is done in an Hjson file that is specified in the
[Register Tool document](../../../../util/reggen/README.md).
All lowRISC peripheral designs must conform to this configuration and register specification.

A description of Hjson (a variant of json) and the recommended style is in the [Hjson Usage and Style Guide](../../style_guides/hjson_usage_style.md).

### Configuration information in the file

The configuration part of the file has the following elements, with a comment as to if required or optional.
In this example, the IP name is `uart`, though the other configuration fields are contrived and not in-line with the expected functionality of a UART but are shown for edification.

```hjson
  {
    name: "uart",
    clocking: [
      {clock: "clk_fixed", reset: "rst_fixed_n", primary: true},
      {clock: "clk", reset: "rst_n"},
      {clock: "clk_lowpower", reset: "rst_lowpower_n"}
    ],
    bus_interfaces: [
      { protocol: "tlul", direction: "device", name: "regs" }
    ],
    available_input_list: [          // optional; default []
      { name: "rx", desc: "Receive bit" }
    ],
    available_output_list: [         // optional; default []
      { name: "tx", desc: "Transmit bit" }
    ],
    available_inout_list: [],        // optional; default []
    interrupt_list: [                // optional; default []
      // Interrupt type is 'event' if unspecified.
      { name: "tx_watermark",  desc: "raised if the transmit FIFO...", type: "status"}
      { name: "rx_watermark",  desc: "raised if the receive FIFO...", type: "status"}
      { name: "tx_overflow",   desc: "raised if the transmit FIFO..."}
      { name: "rx_overflow",   desc: "raised if the receive FIFO..."}
      { name: "rx_frame_err",  desc: "raised if a framing error..."}
      { name: "rx_break_err",  desc: "raised if break condition..."}
      { name: "rx_timeout",    desc: "raised if the receiver..."}
      { name: "rx_parity_err", desc: "raised if the receiver..."}
    ],
    alert_list: [                    // optional; default []
      { name: "fatal_uart_breach", desc: "Someone has attacked the ..."}
      { name: "recov_uart_frozen", desc: "The UART lines are frozen..." }
    ],
    inter_signal_list: [
      { name: "msg_fifo",
        struct: "fifo",
        package: "msg_fifo_pkg",
        type: "req_rsp",
        act: "req",
        width: 1
      }
      { name: "suspend",
        struct: "logic",
        package: "",
        type: "uni",
        act: "rcv",
        width: 1
      }
    ]
    regwidth: "32", // standard register width
    register: [
      // Register information...
    ]
  }
```

### Documentation Output

The following shows the expected documentation format for this example.

*Primary Clock:* `clk_fixed`

*Other clocks:* `clk, clk_lowpower`

*Bus Device Interfaces (TL-UL):* `regs_tl`

*Bus Host Interfaces (TL-UL): none*

*Peripheral Pins available for chip-level IO:*

| Pin name | direction | Description |
| --- | --- | --- |
| tx | output | Transmit bit |
| rx | input | Receive bit |

*Interrupts:*

| Intr Name | Description |
| --- | --- |
| `tx_watermark`  | Raised if the transmit FIFO is past the high water mark |
| `rx_watermark`  | Raised if the receive FIFO is past the high water mark |
| `tx_overflow`   | Raised if the transmit FIFO has overflowed |
| `rx_overflow`   | Raised if the receive FIFO has overflowed |
| `rx_frame_err`  | Raised if a framing error has been detected on receive |
| `rx_break_err`  | Raised if a break condition is detected on receive |
| `rx_timeout`    | Raised if the receiver has not received any characters programmable time period |
| `rx_parity_err` | Raised if the receiver has detected a parity error |

*Security alerts:*

| Alert name | Description |
| --- | --- |
| `fatal_uart_breach` | Someone has attacked the UART module |
| `recov_uart_frozen` | The UART lines are frozen and might be under attack |

### Specifying countermeasures

Countermeasure information can be specified in the register Hjson format.
This is done with a list with key `countermeasures`.
Each item is a dictionary with keys `name` and `desc`.
The `desc` field is a human-readable description of the countermeasure.
The `name` field should be either of the form `ASSET.CM_TYPE` or `INSTANCE.ASSET.CM_TYPE`.
Here, `ASSET` and `CM_TYPE` should be one of the values given in the tables in the [Security countermeasures](#security-countermeasures) section.
If specified, `INSTANCE` should name a submodule of the IP block holding the asset.
It can be used to disambiguate in situations such as where there are two different keys that are protected with different countermeasures.

Here is an example specification:
```hjson
  countermeasures: [
    {
      name: "BUS.INTEGRITY",
      desc: "End-to-end bus integrity scheme."
    }
    {
      name: "STATE.SPARSE",
      desc: "Sparse manufacturing state encoding."
    }
    {
      name: "MAIN.FSM.SPARSE",
      desc: "The main state FSM is sparsely encoded."
    }
  ]
```

## Interrupt Handling

Interrupts are critical and common enough to standardize across the project.
Where possible (exceptions for inherited IP that is too tricky to convert) all interrupts shall have common naming, hardware interfaces, and software interfaces.

### Conventions

Currently, all wired CIP interrupts in OpenTitan use active-high level-triggering.
(An alternate standard is the use of edge-triggered interrupts, which are not described here, but may be supported in a future release.)

![OpenTitan System Interrupt Architecture](ot_interrupt_arch.svg)

Interrupts sent to the processor are aggregated by a platform level interrupt controller (PLIC).
Within that logic there may be another level of control for enabling, prioritizing, and enumeration.
Specification of this control is defined in the rv_plic documentation of the corresponding toplevel design.

### Defining Interrupts

The `.hjson` [configuration file](#configuration-file) for a peripheral specifies interrupts with the field 'interrupt_list'.
See the [example](#configuration-information-in-the-file) file above for one possible use of this schema.
For each entry in 'interrupt_list', the following keys are defined:

| Key  | Kind     | Type   | Description of Value                                                          |
|------|----------|--------|-------------------------------------------------------------------------------|
| name | required | string | Name of the interrupt                                                         |
| desc | optional | string | Description of the interrupt                                                  |
| type | optional | string | Select between "Event" and "Status" types, default is "Event" if unspecified. |

### Interrupts per module

A peripheral generates a separate wired interrupt for each interrupt source, which are all routed to the target's interrupt controller.
All peripheral interrupts have equal severity, but may be classified into a hierarchy at a higher level, such as at a platform interrupt controller.
The determination of which input has interrupted the processor, sometimes referred to as "Disambiguation", is done primarily by querying the rv_plic claim/complete register (`CC`).
This is distinct from another possible model in which each peripheral would send only one interrupt, and the processor would disambiguate by querying the peripheral to figure out which interrupt was triggered.

### Register Creation

By default for every peripheral, three registers are **automatically** created to manage the interrupts (as defined in the 'interrupt_list' of the `.hjson` file).
These registers are named `INTR_STATE`, `INTR_ENABLE` and `INTR_TEST`, and are placed in that order automatically by the `reggen` tool at the top of the peripheral's address map.
There is one bitfield in each register per interrupt.
(It is currently an error if the `.hjson` defines more than 32 interrupts for each peripheral.)
The function of each register is explained in the following table.

| Name          | Offset | Desc                                                                                  |
|---------------|--------|---------------------------------------------------------------------------------------|
| `INTR_STATE`  | 0x0    | holds the current state of the interrupt (may be RO or W1C depending on "IntrT").     |
| `INTR_ENABLE` | 0x4    | enables/masks the output of INTR_STATE to create the wired interrupt signal `intr_o`. |
| `INTR_TEST`   | 0x8    | write-only (`wo`) register which asserts the interrupt for testing purposes.          |

The contents of the `INTR_STATE` register are not qualified by `INTR_ENABLE`, but rather show the raw state of all latched hardware interrupt events.

### CIP Interrupt Types

Interrupts are a mechanism for hardware to request attention from software, commonly as either a normal part of a system's operation or as a way to handle exceptional circumstances.
One way to design robust control flows and abstractions using interrupts is to model Interrupts + Interrupt Handlers as forming a handshaking interaction between hardware and software.
Hardware creates an interrupt request when a condition is true or an event occurs.
Software responds to this request, possibly performing some action to address the condition/event, then acknowledges the interrupt request as completed.
This request/acknowledge sequence is one way to mitigate the effects of non-determinism in a real system, such as race-conditions due to the inherent round-trip latency from signaling to handling, and the unknown latency of a core executing the handler for one of possibly many competing interrupt requests.

When creating an interrupt in a peripheral, we can identify two distinct behaviors a designer may choose to implement.

1. **Event** type: Whenever an instantaneous event occurs, trigger an interrupt request.
   The current interrupt can only be cleared by an acknowledgement from the handler (ack is a `W1C` operation to `INTR_STATE` in this mode).
2. **Status** type: So long as the input is persistently true, trigger interrupt requests, including immediately after the previous request has been acknowledged.

> The names *Event* and *Status* are OpenTitan terminology.
> Generic hardware `prim_intr_hw` is defined which generates interrupt requests for each type by using a parameter at the time of instantiation.

An instantaneous *Event* could be an error occurring, a counter value crossing a threshold, or a particular transition between two abstract states inside the peripheral.
A persistent *Status* might be any conditional expression evaluating truthfully, such as a counter value currently exceeds a threshold, or the system being in a particular abstract state, such as an error state it cannot recover from on its own.

Choosing to generate interrupts based on instantaneous events or persistent status signals can make it easier to write SW handlers that are simple and race-free.
For example, an event interrupt request implies that "the event happened at some point in the past (since we last acknowledged this interrupt)".
A status interrupt request means that "the condition is currently true".

#### Event Type Interrupt

Event type interrupts are latched indications of defined peripheral events that have occurred and have not yet been acknowledged by the processor.
For instance, the GPIO module might detect the rising or falling edge of one its inputs as an interrupt event.
Using level-triggered wired interrupts, this is signaled by latching `intr_o` high (request) when the event occurs, and resetting `intr_o` low (ack) when software has finished executing its handler.

> The generic component `prim_intr_hw` can generate the correct hardware when parameterized with `.IntrT("Event")`.

![Event Type Interrupt Hardware](event_intr_type.svg)

The event is latched into the corresponding bitfield of `INTR_STATE` when it occurs.
The event is cleared/acknowledged by a sw write of this bitfield, as `INTR_STATE` has **W1C** behaviour in this mode.
The waveform below shows the timing of the event occurrence, its latched value, and the clearing of the event by a SW handler.

```wavejson
{
  signal: [
    { name: 'Clock',             wave: 'p.............' },
    { name: 'hw_i',              wave: '0..10.........' },
    { name: 'INTR_ENABLE',       wave: '1.............' },
    { name: 'INTR_STATE',        wave: '0...1....0....' },
    { name: 'intr_o',            wave: '0....1....0...' },
    { name: 'SW w1c',            wave: '0.......10....' },
  ],
  head: {
    text: 'Event-Type Interrupt Latching and Clearing (output flop enabled)',
  },
  foot: {
    text: 'event signaled at cycle 3, cleared in cycle 8',
    tock: 0
  },
}
```

#### Status Type Interrupt

Status type interrupts create a wired level-triggered interrupt signal directly from the input signal from hardware (only qualified by `INTR_ENABLE`).
If the input signal is asserted, then the wired interrupt is constantly asserted, effectively issuing interrupt requests continuously.
With this interrupt type, the acknowledgement part of the req/ack handshake is an intervention from sw which causes the input signal from hardware to return to an inactive state.
This means that the wired interrupt does not deassert until the root cause of the hardware input signal is addressed.
Software cannot acknowledge this interrupt request using the `INTR_STATE` register, which has (`ro`) access permissions in this context.

> The generic component `prim_intr_hw` can generate the correct hardware when parameterized with `.IntrT("Status")`.

![Status Type Interrupt Hardware](status_intr_type.svg)

The waveform below shows the timing of the status type interrupt.

```wavejson
{
  signal: [
    { name: 'Clock',                  wave: 'p.............' },
    { name: 'hw_i',                   wave: '0..1......0...' },
    { name: 'INTR_ENABLE',            wave: '1.............' },
    { name: 'INTR_STATE',             wave: '0...1......0..' },
    { name: 'intr_o',                 wave: '0...1......0..' },
    { name: 'SW addresses the cause', wave: '0........10...' },
  ],
  head: {
    text: 'Status-Type Interrupt Setting and Clearing (output flop enabled)',
  },
  foot: {
    text: 'status lasts until processor addresses the cause',
    tock: 0
  },
}
```

If SW cannot address the root cause of the interrupt, or wishes to defer handling, it should mask the interrupt, either at the peripheral or at some point further up the tree such as at the PLIC.
Masking at the peripheral can be achieved by clearing the corresponding bit in `INTR_ENABLE`.

### Interrupt Hardware Implementation (Event Type)

Taking an interrupt `foo` as an example, the block diagram below shows one possible hardware implementation.
We assume that an internal signal (call it `event_foo`) indicates the detection of the event that is to trigger the interrupt.
The block diagram shows the interaction between that event, the three software-facing registers, and the output interrupt `intr_foo_o`.

![Example Interrupt HW](comportability_diagram_intr_hw.svg)

**Figure 2**: Example interrupt `foo` with its three registers and associated HW

In this figure the event is shown coming in from another part of the peripheral hardware.
The assumption is this event `foo` is one of multiple interrupt events in the design.
Within the register file, the event triggers the setting of the associated bit in the `INTR_STATE` register to `1`.
Additionally, a write of `1` of the associated `foo` bit of the `INTR_TEST` register can set the corresponding `INTR_STATE` bit.
The output of the `INTR_STATE` register becomes the outgoing interrupt to the processor after masking (ANDing) with the value of `INTR_ENABLE`.

Note that the handling of the `ro/rw1c` functionality of the `INTR_STATE` register allows software to control the clearing of the `INTR_STATE` content.
A write of `1` to the corresponding bit of `INTR_STATE` clears the latched value, but if the event itself is still active, the `INTR_STATE` register will return to true.
The hardware does not have the ability to clear the latched interrupt state, only software does.

## Alert Handling

Alerts are another critical and common implementation to standardize for all peripherals.
Unlike interrupts, there is no software component to alerts at the peripheral, though there is at the hardware alert handler.
See that [specification](../../../../hw/top_earlgrey/ip_autogen/alert_handler/README.md) for full details.
A general description of the handling of alerts at the hardware level is given here.

### Alerts per Module

Alerts are sent as a bundled output from a peripheral to the hardware alert handler.
Each peripheral can send zero or more alerts, where each is a distinguishable security threat.
Each alert originates in some internal event, and must be specially handled within the peripheral, and then within the alert handler module.

Alerts of comportable IPs in the system must be in either of the following two categories:

1. *Recoverable*, one-time triggered alerts.
This category is for regular alerts that are due to recoverable error conditions.
The alert sender transmits one single alert event when the corresponding error condition is asserted.

2. *Fatal* alerts that are continuously triggered until reset.
This category is for highly critical alerts that are due to terminal error conditions.
The alert sender continuously transmits alert events until the system is reset.

It is recommended that fatal alerts also trigger local security countermeasures, if they exist.
For example, a redundantly encoded FSM that is glitched into an invalid state is typically considered to be a fatal error condition.
In this case, a local countermeasure could be to move the FSM into a terminal error state in order to render the FSM inoperable until the next reset.

The table below lists a few common error conditions and the recommended alert type for each of those errors.

Error Event                                                             | Regular IRQ | Recoverable Alert | Fatal Alert
------------------------------------------------------------------------|-------------|-------------------|-------------
ECC correctable in NVM (OTP, Flash)                                     | (x)         | x                 |
ECC uncorrectable in Flash                                              | (x)         | x                 |
ECC uncorrectable in OTP                                                | (x)         |                   | x
Any ECC / Parity error in SRAMs or register files                       | (x)         |                   | x
Glitch detectors (e.g., invalid FSM encoding)                           | (x)         |                   | x
Incorrect usage of security IP (e.g., shadowed control register in AES) | (x)         | x                 |
Incorrect usage of regular IP                                           | x           |                   |

(x): optional

The column "Regular IRQ" indicates whether the corresponding error condition should also send out a regular IRQ.
A peripheral may optionally send out an IRQ for any alert event, depending on whether this is needed by the programming model to make forward progress.
Note that while alerts may eventually lead to a system wide reset, this is not guaranteed since the alert response depends on the alert handler configuration.

### Defining Alerts

The Hjson configuration file defined above specifies all that needs to be known about the alerts in the standard case.
The following sections specify what comes out of various tools based upon the simple list defined in the above example.

In terms of naming convention, alerts shall be given a meaningful name that is indicative of its cause.
Recoverable alerts must be prefixed with `recov_*`, whereas fatal alerts must be prefixed with `fatal_*`.
For instance, an uncorrectable parity error in SRAM could be named `fatal_parity_error`.

In cases where many diverse alert sources are bundled into one alert event (see [Alert Hardware Implementation](#alert-hardware-implementation)), it may sometimes be difficult to assign the alert event a meaningful and descriptive name.
In such cases, it is permissible to default the alert names to just `recov` and/or `fatal`.
Note that this implies that the peripheral does not expose more than one alert for that type.

### Test Alert Register Creation

For every peripheral, by default, one register named `ALERT_TEST` is **automatically** created.

`ALERT_TEST` is a write-only (`wo`) register that allows software to test the reporting of alerts in the alert handler.
Every alert of a peripheral has one field bit inside the `ALERT_TEST` register, and each field bit is meant to be connected to the test input of the corresponding `prim_alert_sender` (see next subsection).

### Alert Hardware Implementation

Internal events are sent active-high to a piece of IP within the peripheral called the `prim_alert_sender`.
One `prim_alert_sender` must be instantiated per distinct alert event, and the `IsFatal` parameter of the alert sender must be set to 1 for fatal alerts (this causes the alert sender to latch the alert until the next system reset).

It is up to the peripheral maintainer to determine what are distinct alert events;
multiple ones can be bundled depending upon the distinction required within the module (i.e.  high priority threat vs. low level threat).
As a general guideline, it is recommended that each peripheral bundles alert sources into one or two distinct alerts, for example one fatal and one recoverable alert.
This helps to keep the total number of alerts (and their physical impact) low at the system level.

It is recommended that comportable IPs with multiple bundled alerts expose a cause register for disambiguation, which is useful for debugging and crash dumps.
Cause registers for recoverable alerts must either be clearable by SW, or the HW must provide an automatic mechanism to clear them (e.g., upon starting a new transaction initiated by SW).
Cause registers for fatal alerts must not be clearable in any way and must hence be read-only.

The `prim_alert_sender` converts the event into a differentially encoded signal pair to be routed to the hardware alert handler, as dictated by the details in the
[alert handler specification](../../../../hw/top_earlgrey/ip_autogen/alert_handler/README.md).
The alert handler module is automatically generated to have enough alert ports to represent each alert declared in the different included peripheral IP configuration files.

## Inter Signal Handling

Inter-module signal is a term that describes bundled signals connecting instances in the top.
A few peripherals can be stand-alone such as GPIO and UART peripherals.
They don't need to talk with other modules other than reporting the interrupts to the main processor.
By contrast, many peripherals and the main processing unit in OpenTitan communicate between the modules.
For example, `flash_ctrl` sends requests to the flash macro for read/ program/ erase operations.

Inter-module signal aims to handle the connection by the tool [topgen](../../../../util/topgen/README.md)

### Defining the inter-module signal

The example configuration file above specifies two cases of inter-module signals, `msg_fifo` and `suspend`.

| Attribute | Mand/Opt  | Description |
| --------- | --------- | ----------- |
| name      | mandatory | `name` attribute specifies the port name of the inter-module signal. If the type is `req_rsp`, it indicates the peripheral has `name`_req , `name`_rsp ports (with `_i` and `_o` suffix) |
| struct    | mandatory | The `struct` field defines the signal's data structure. The inter-module signal is generally bundled into `struct packed` type. This `struct` is used with `package` for topgen tool to define the signal. If the inter-module signal is `logic` type, `package` field can be omitted. |
| package   | optional  |             |
| type      | mandatory | There are two types of inter-module signal. `req_rsp` is a connection that a module sends requests and the other module returns with responses. `uni` is one-way signal, which can be used as a broadcasting signal or signals that don't need the response. |
| act       | mandatory | `act` attribute pairs with the `type`. It specifies the input/output of the signal in the peripheral. `req_rsp` type can have `req`(requester) or `rsp`(responder) in `act` field. `uni` type can have `req` or `rcv`(receiver) in `act`. |
| width     | optional  | If `width` is not 1 or undefined, the port is defined as a vector of struct. It, then, can be connected to multiple peripherals. Currently, `logic` doesn't support the connection to multiple modules if `width` is not 1. |
