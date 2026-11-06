## -----------------------------------------------------------------------------
## cmod_a7.xdc - Digilent Cmod A7-35T (xc7a35tcpg236-1)
## Pin names follow Digilent's Cmod-A7-Master.xdc
## (github.com/Digilent/digilent-xdc). Check against it before adding new pins.
## -----------------------------------------------------------------------------

## 12 MHz system clock
set_property -dict { PACKAGE_PIN L17 IOSTANDARD LVCMOS33 } [get_ports clk_12m]
create_clock -name sys_clk -period 83.333 -waveform {0 41.667} [get_ports clk_12m]

## Buttons (active high)
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports {btn[0]}]
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports {btn[1]}]

## LEDs
set_property -dict { PACKAGE_PIN A17 IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
set_property -dict { PACKAGE_PIN C16 IOSTANDARD LVCMOS33 } [get_ports {led[1]}]

## RGB LED (active low)
set_property -dict { PACKAGE_PIN B17 IOSTANDARD LVCMOS33 } [get_ports led0_b]
set_property -dict { PACKAGE_PIN B16 IOSTANDARD LVCMOS33 } [get_ports led0_g]
set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports led0_r]

## USB-UART (FT2232HQ channel B). Names are from the FTDI's point of view.
set_property -dict { PACKAGE_PIN J18 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]
set_property -dict { PACKAGE_PIN J17 IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]

## -----------------------------------------------------------------------------
## Timing exceptions for asynchronous / slow I/O
## -----------------------------------------------------------------------------
set_false_path -from [get_ports {btn[*] uart_txd_in}]
set_false_path -to   [get_ports {led[*] led0_* uart_rxd_out}]

## -----------------------------------------------------------------------------
## Configuration
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO                         [current_design]
set_property CONFIG_VOLTAGE 3.3                  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE     [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4     [current_design]
set_property CONFIG_MODE SPIx4                   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33      [current_design]
