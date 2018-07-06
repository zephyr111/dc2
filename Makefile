DC=ldc2

.PHONY: all release debug

all: release

release:
	dub build -q --compiler=$(DC) --build=release-nobounds

debug:
	dub build -q --compiler=$(DC) --build=debug

