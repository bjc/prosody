@echo off

set oldpath=%path%
set path=%path%;..;..\lualibs

del reports\*.report
lua test.lua %*

set path=%oldpath%
set oldpath=