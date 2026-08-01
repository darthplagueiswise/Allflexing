# Provider bridges compiled into the single AllFLEXing target. ElleKit itself
# remains the Substrate-compatible framework supplied inside the signed app;
# these files are the in-dylib adapters, typed slots, and embedded fishhook.
ALLFLEXING_HOOK_PROVIDER_SOURCES := \
	$(ALLFLEXING_ROOT)/FLEXCHookEngine.m \
	$(ALLFLEXING_ROOT)/FLEXHooking.m \
	$(ALLFLEXING_ROOT)/FLEXSymbolRebind.m \
	$(ALLFLEXING_ROOT)/flex_fishhook.c

ALLFLEXING_EMBEDDED_FISHHOOK_SOURCES := \
	$(ALLFLEXING_ROOT)/flex_fishhook.c
