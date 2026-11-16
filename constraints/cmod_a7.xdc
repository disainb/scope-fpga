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

## ADC08200 on DIP pins 26-36 (all bank 34). DIP pin 35 left free as a spacer.
##   ADC pin 13..16,19..22 = D7..D0, 23 = PD, 24 = CLK
set_property -dict { PACKAGE_PIN V2  IOSTANDARD LVCMOS33 } [get_ports {adc_d[0]}] ;# DIP 33 - ADC 22
set_property -dict { PACKAGE_PIN W2  IOSTANDARD LVCMOS33 } [get_ports {adc_d[1]}] ;# DIP 32 - ADC 21
set_property -dict { PACKAGE_PIN U1  IOSTANDARD LVCMOS33 } [get_ports {adc_d[2]}] ;# DIP 31 - ADC 20
set_property -dict { PACKAGE_PIN T2  IOSTANDARD LVCMOS33 } [get_ports {adc_d[3]}] ;# DIP 30 - ADC 19
set_property -dict { PACKAGE_PIN T1  IOSTANDARD LVCMOS33 } [get_ports {adc_d[4]}] ;# DIP 29 - ADC 16
set_property -dict { PACKAGE_PIN R2  IOSTANDARD LVCMOS33 } [get_ports {adc_d[5]}] ;# DIP 28 - ADC 15
set_property -dict { PACKAGE_PIN T3  IOSTANDARD LVCMOS33 } [get_ports {adc_d[6]}] ;# DIP 27 - ADC 14
set_property -dict { PACKAGE_PIN R3  IOSTANDARD LVCMOS33 } [get_ports {adc_d[7]}] ;# DIP 26 - ADC 13
set_property -dict { PACKAGE_PIN W3  IOSTANDARD LVCMOS33 } [get_ports adc_pd]     ;# DIP 34 - ADC 23
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 8 } [get_ports adc_clk] ;# DIP 36 - ADC 24

## -----------------------------------------------------------------------------
## Timing exceptions for asynchronous / slow I/O
## -----------------------------------------------------------------------------
set_false_path -from [get_ports {btn[*] uart_txd_in}]
set_false_path -to   [get_ports {led[*] led0_* uart_rxd_out}]

## ADC: the capture point is chosen at run time with the PH command (5 ns
## steps), so the board-level I/O timing is calibrated on the bench, not by STA.
set_false_path -from [get_ports {adc_d[*]}]
set_false_path -to   [get_ports {adc_clk adc_pd}]

## -----------------------------------------------------------------------------
## Configuration
## -----------------------------------------------------------------------------
set_property CFGBVS VCCO                         [current_design]
set_property CONFIG_VOLTAGE 3.3                  [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE     [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4     [current_design]
set_property CONFIG_MODE SPIx4                   [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 33      [current_design]
