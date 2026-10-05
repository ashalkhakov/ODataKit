# clang + libobjc2 + gnustep-base + FreeCoreData.
# Does not need gnustep-make.
#
# Install FreeCoreData first: https://github.com/ashalkhakov/FreeCoreData
#
#   make
#   ./ois-filter 'unitPrice > 20 AND discontinued == NO'
#
# GCC's libobjc will not work. clang is required.

# `?=` would never fire: make predefines CC as cc.
ifeq ($(origin CC),default)
CC = clang
endif
SRC_DIR = Source
LIBS_ = ODataKit ODataIncrementalStore OTelKit HTTPServerKit ODataService ODataSync
GCDWebServer_DIR = ThirdParty/GCDWebServer
include $(GCDWebServer_DIR)/GCDWebServer.make
INC = $(foreach l,$(LIBS_),-I$(SRC_DIR)/$(l)/include -I$(SRC_DIR)/$(l)/include/$(l))
HTTPSERVERKIT_VERSION ?= $(shell git describe --tags --always 2>/dev/null || echo dev)

ifeq ($(findstring gcc,$(CC)),gcc)
$(error OIS requires clang + libobjc2. GCC's libobjc is the old fragile runtime.)
endif

GNUSTEP_FLAGS := $(shell gnustep-config --objc-flags 2>/dev/null)
GNUSTEP_LIBS  := $(shell gnustep-config --base-libs 2>/dev/null)

ifeq ($(strip $(GNUSTEP_FLAGS)),)
  GNUSTEP_FLAGS = -I/usr/include/GNUstep -DGNUSTEP -DGNUSTEP_BASE_LIBRARY=1
  GNUSTEP_LIBS  = -lgnustep-base -lobjc -lpthread
endif

GNUSTEP_LIBS += -lCoreData -ldispatch

# ODataSync's peers: Avahi's dns_sd compatibility library (Bonjour).
DNSSD_CFLAGS := $(shell pkg-config --cflags avahi-compat-libdns_sd 2>/dev/null || echo -I/usr/include/avahi-compat-libdns_sd)
DNSSD_LIBS := $(shell pkg-config --libs avahi-compat-libdns_sd 2>/dev/null || echo -ldns_sd)

OBJCFLAGS = $(GNUSTEP_FLAGS) \
	-fobjc-runtime=gnustep-2.0 \
	-fobjc-arc \
	-fblocks \
	-fconstant-string-class=NSConstantString \
	-fobjc-exceptions \
	-fPIC \
	-Wall -Wno-unused-parameter \
	$(INC)

KIT_SRCS = $(wildcard $(SRC_DIR)/ODataKit/*.m)
CLIENT_SRCS = $(wildcard $(SRC_DIR)/ODataIncrementalStore/*.m)
TRACE_SRCS = $(wildcard $(SRC_DIR)/OTelKit/*.m)
# What differs from system to system is in each library's linux/ (and
# apple/, the Xcode project's): this is Linux's.
HOST_SRCS = $(wildcard $(SRC_DIR)/HTTPServerKit/*.m) $(wildcard $(SRC_DIR)/HTTPServerKit/linux/*.m)
SERVICE_SRCS = $(wildcard $(SRC_DIR)/ODataService/*.m)
SYNC_SRCS = $(wildcard $(SRC_DIR)/ODataSync/*.m) $(wildcard $(SRC_DIR)/ODataSync/linux/*.m)
SRCS = $(KIT_SRCS) $(CLIENT_SRCS) $(TRACE_SRCS) $(HOST_SRCS) $(SERVICE_SRCS) $(SYNC_SRCS)
GCDWebServer_OBJS = $(GCDWebServer_OBJC_FILES:.m=.o)

OBJS = $(SRCS:.m=.o)

.PHONY: all clean test

all: libODataKit.so libODataIncrementalStore.so libOTelKit.so libHTTPServerKit.so libODataService.so libODataSync.so ois-filter ois-model Catalog.momd

libODataKit.so: $(KIT_SRCS:.m=.o)
	$(CC) -shared -o $@ $^ $(GNUSTEP_LIBS)

libODataIncrementalStore.so: $(CLIENT_SRCS:.m=.o) libODataKit.so libOTelKit.so
	$(CC) -shared -o $@ $(CLIENT_SRCS:.m=.o) -L. -lODataKit -lOTelKit $(GNUSTEP_LIBS)

libOTelKit.so: $(TRACE_SRCS:.m=.o)
	$(CC) -shared -o $@ $^ $(GNUSTEP_LIBS)

libHTTPServerKit.so: $(HOST_SRCS:.m=.o) $(GCDWebServer_OBJS) libOTelKit.so
	$(CC) -shared -o $@ $(HOST_SRCS:.m=.o) $(GCDWebServer_OBJS) -L. -lOTelKit $(GNUSTEP_LIBS) -lgnutls $(GCDWebServer_LIBS)

libODataService.so: $(SERVICE_SRCS:.m=.o) libODataKit.so libHTTPServerKit.so
	$(CC) -shared -o $@ $(SERVICE_SRCS:.m=.o) -L. -lHTTPServerKit -lOTelKit -lODataKit $(GNUSTEP_LIBS)

libODataSync.so: $(SYNC_SRCS:.m=.o) libODataService.so libODataIncrementalStore.so libOTelKit.so libODataKit.so
	$(CC) -shared -o $@ $(SYNC_SRCS:.m=.o) -L. -lODataService -lHTTPServerKit -lODataIncrementalStore -lOTelKit -lODataKit $(GNUSTEP_LIBS) \
	  -lgnutls -lcurl $(DNSSD_LIBS)

$(SRC_DIR)/ODataSync/%.o: $(SRC_DIR)/ODataSync/%.m
	$(CC) $(OBJCFLAGS) -I$(SRC_DIR)/ODataSync $(DNSSD_CFLAGS) -c $< -o $@

$(SRC_DIR)/HTTPServerKit/%.o: $(SRC_DIR)/HTTPServerKit/%.m
	$(CC) $(OBJCFLAGS) $(GCDWebServer_INCLUDE_DIRS) -DHTTPSERVERKIT_VERSION='"$(HTTPSERVERKIT_VERSION)"' -c $< -o $@

$(SRC_DIR)/%.o: $(SRC_DIR)/%.m
	$(CC) $(OBJCFLAGS) -c $< -o $@

$(GCDWebServer_DIR)/%.o: $(GCDWebServer_DIR)/%.m
	$(CC) $(OBJCFLAGS) $(GCDWebServer_INCLUDE_DIRS) -c $< -o $@

ois-filter: Tools/ois-filter.m libODataIncrementalStore.so
	$(CC) $(OBJCFLAGS) -o $@ Tools/ois-filter.m -L. -lODataIncrementalStore -lODataKit -lOTelKit $(GNUSTEP_LIBS)

# A Core Data model from a service's $metadata:
#   ./ois-model https://services.odata.org/V4/Northwind/Northwind.svc/ Northwind.xcdatamodeld
ois-model: Tools/ois-model.m libODataIncrementalStore.so
	$(CC) $(OBJCFLAGS) -o $@ Tools/ois-model.m -L. -lODataIncrementalStore -lODataKit -lOTelKit $(GNUSTEP_LIBS)

# FreeCoreData's model compiler (make -C Tools/momc install there).
MOMC ?= momc

# Rebuilt every time: a directory's mtime does not follow its contents.
.PHONY: Catalog.momd
Catalog.momd: Examples/Catalog/Catalog.xcdatamodeld
	$(MOMC) $< $@

# XCTest bundle needs gnustep-make. This target documents the entry point.
test:
	$(MAKE) -C Tests run-tests

clean:
	rm -f $(OBJS) $(GCDWebServer_OBJS) libODataKit.so libODataIncrementalStore.so libOTelKit.so libHTTPServerKit.so libODataService.so libODataSync.so ois-filter ois-model
	rm -rf Catalog.momd
