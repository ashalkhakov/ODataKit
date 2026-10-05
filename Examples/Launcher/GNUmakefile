# ODataLauncher: the chooser the Linux AppImage opens, between the
# Workbench and the desktop Device app (GNUstep only: a Mac has each app
# as its own bundle, nothing to choose between).
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

APP_NAME = ODataLauncher
ODataLauncher_OBJC_FILES = main.m OLAppDelegate.m
ODataLauncher_RESOURCE_FILES = ../Workbench/Workbench.png
ODataLauncher_APPLICATION_ICON = Workbench.png
ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 -fconstant-string-class=NSConstantString -fobjc-exceptions

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/application.make
-include GNUmakefile.postamble
