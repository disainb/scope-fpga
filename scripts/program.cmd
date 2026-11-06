@echo off
REM Windows wrapper: load build\cmod_top.bit over JTAG (volatile).
REM Usage:  program.cmd           -> JTAG load
REM         program.cmd flash     -> write Quad-SPI flash
REM         program.cmd flash <cfgmem_part>
cd /d "%~dp0.."
if not exist build mkdir build
if /I "%1"=="flash" (
    vivado -mode batch -nojournal -log build\vivado_flash.log -source scripts\flash.tcl -tclargs %2
) else (
    vivado -mode batch -nojournal -log build\vivado_prog.log -source scripts\program.tcl
)
