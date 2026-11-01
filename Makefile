# Build products stay outside the project: folders on the Desktop carry Finder and
# iCloud attributes that make codesign reject test bundles.
SCRATCH := $(HOME)/Library/Caches/MediaShift/build

# Without Xcode, the Command Line Tools need to be told where the testing macros are.
DEVELOPER := $(or $(DEVELOPER_DIR),$(shell xcode-select -p))
TESTING_PLUGINS := $(DEVELOPER)/usr/lib/swift/host/plugins/testing
ifneq ($(wildcard $(TESTING_PLUGINS)),)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)
endif

.PHONY: build test app ffmpeg clean

build:
	swift build --scratch-path "$(SCRATCH)"

test:
	swift test --scratch-path "$(SCRATCH)" $(TEST_FLAGS)

ffmpeg:
	scripts/build-ffmpeg.sh

app:
	scripts/build-app.sh

clean:
	rm -rf "$(SCRATCH)" "$(SCRATCH)"-arm64 "$(SCRATCH)"-x86_64
