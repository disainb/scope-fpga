@echo off
REM Windows wrapper: build bitstream. Run from a "Vivado Tcl Shell" or a
REM command prompt where vivado.bat is on PATH (e.g. C:\AMDDesignTools\<ver>\Vivado\bin).
cd /d "%~dp0.."
if not exist build mkdir build
vivado -mode batch -nojournal -log build\vivado_build.log -source scripts\build.tcl
