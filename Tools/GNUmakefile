# The command-line tools, on the libraries at the repository root (built
# there first; the umbrella GNUmakefile builds and installs these after
# them):
#   ois-model   a Core Data model, and classes, from a service's $metadata
#               (ois-model https://services.odata.org/V4/Northwind/Northwind.svc/ Northwind.xcdatamodeld)
#   ois-filter  an NSPredicate as an OData $filter, over the Catalog example's
#               model (ois-filter 'unitPrice > 20 AND discontinued == NO')
ifeq ($(GNUSTEP_MAKEFILES),)
$(error Set GNUSTEP_MAKEFILES (source GNUstep.sh).)
endif

include $(GNUSTEP_MAKEFILES)/common.make

CC = clang
OBJC = clang

TOOL_NAME = ois-model ois-filter
ois-model_OBJC_FILES = ois-model.m
ois-filter_OBJC_FILES = ois-filter.m
INCLUDES = -I../Source/ODataKit/include -I../Source/ODataKit/include/ODataKit \
	-I../Source/ODataIncrementalStore/include -I../Source/ODataIncrementalStore/include/ODataIncrementalStore \
	-I../Source/OTelKit/include -I../Source/OTelKit/include/OTelKit
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_INCLUDE_DIRS = $(INCLUDES)))
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_LIB_DIRS = -L../obj))
$(foreach tool,$(TOOL_NAME),$(eval $(tool)_TOOL_LIBS = -lODataIncrementalStore -lOTelKit -lODataKit -lCoreData -ldispatch))

ADDITIONAL_OBJCFLAGS += -fobjc-arc -fblocks -fobjc-runtime=gnustep-2.0 \
	-fconstant-string-class=NSConstantString -fobjc-exceptions

-include GNUmakefile.preamble
include $(GNUSTEP_MAKEFILES)/tool.make
-include GNUmakefile.postamble

# ois-filter's model, compiled by FreeCoreData's momc (Core Data loads
# compiled models only), beside it.
MOMC ?= momc
after-all:: Catalog.momd
Catalog.momd: ../Examples/Catalog/Catalog.xcdatamodeld
	rm -rf $@ && $(MOMC) $< $@

after-clean::
	rm -rf Catalog.momd

# The one check of ois-filter: the predicate in its usage, translated.
check:: all
	@got=$$(LD_LIBRARY_PATH="$(CURDIR)/../obj$${LD_LIBRARY_PATH:+:$$LD_LIBRARY_PATH}" ./$(GNUSTEP_OBJ_DIR_NAME)/ois-filter 'unitPrice > 20 AND discontinued == NO'); \
	  want='UnitPrice gt 20 and Discontinued eq false'; \
	  [ "$$got" = "$$want" ] || { echo "check: ois-filter printed '$$got', expected '$$want'"; exit 1; }; \
	  echo "ois-filter: $$got"
