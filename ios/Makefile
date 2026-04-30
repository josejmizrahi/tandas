.PHONY: project build test clean

# All targets resolve paths relative to this Makefile so `make -C ios <target>`
# from the repo root and `cd ios && make <target>` both work.
HERE := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
PROJECT := $(HERE)Tandas.xcodeproj
DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro,OS=latest

# Use xcpretty if installed (gem install xcpretty), otherwise raw xcodebuild output.
BEAUTIFY := $(shell command -v xcpretty 2>/dev/null || echo cat)

project:
	cd $(HERE) && xcodegen

build: project
	set -o pipefail; xcodebuild build \
		-project $(PROJECT) \
		-scheme Tandas \
		-destination '$(DESTINATION)' \
		| $(BEAUTIFY)

test: project
	set -o pipefail; xcodebuild test \
		-project $(PROJECT) \
		-scheme Tandas \
		-destination '$(DESTINATION)' \
		| $(BEAUTIFY)

clean:
	rm -rf $(HERE)Tandas.xcodeproj $(HERE).build $(HERE)DerivedData $(HERE)build
