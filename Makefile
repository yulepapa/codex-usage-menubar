.PHONY: build universal install uninstall test test-live clean

build:
	./Scripts/build.sh

universal:
	ARCHS="arm64 x86_64" ./Scripts/build.sh

install:
	./Scripts/install.sh

uninstall:
	./Scripts/uninstall.sh

test:
	./Scripts/test.sh

test-live:
	LIVE=1 ./Scripts/test.sh

clean:
	rm -rf .build
