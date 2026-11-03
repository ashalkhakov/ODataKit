# The Workbench's parts a host compiles in, relative to Examples/Workbench/:
# the connection to a service (presets, $metadata, the store, sign-in), the
# built-in service (the Catalog, in process), the wire log, traces, results
# and queries, and their XIBs. The Workbench's own GNUmakefile builds the
# app from them and its window; UDCode's OData extension
# (../../UDCodeExtension/GNUmakefile) compiles them into its bundle, the
# Catalog model with them (WORKBENCH_CATALOG).
WORKBENCH_KIT_OBJC_FILES = \
	WBConnection.m \
	WBExchangeLog.m \
	WBQuery.m \
	WBQueryPanel.m \
	WBResults.m \
	WBSignInPanel.m \
	WBTraces.m \
	WorkbenchEngine.m \
	WorkbenchModel.m \
	WorkbenchSupport.m
WORKBENCH_KIT_RESOURCE_FILES = \
	WBQueryPanel.xib \
	WBSignInPanel.xib \
	WBTraces.xib \
	WBTraceWindow.xib
# The built-in service's model, compiled by FreeCoreData's momc on GNUstep.
WORKBENCH_CATALOG = ../Catalog/Catalog.xcdatamodeld
