.PHONY: project build test clean

# All targets resolve paths relative to this Makefile so `make -C ios <target>`
# from the repo root and `cd ios && make <target>` both work.
HERE := $(dir $(realpath $(firstword $(MAKEFILE_LIST))))
PROJECT := $(HERE)Tandas.xcodeproj
DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro,OS=latest

project:
	cd $(HERE) && xcodegen

build: project
	xcodebuild build \
		-project $(PROJECT) \
		-scheme Tandas \
		-destination '$(DESTINATION)' \
		| xcpretty

test: project
	xcodebuild test \
		-project $(PROJECT) \
		-scheme Tandas \
		-destination '$(DESTINATION)' \
		| xcpretty

clean:
	rm -rf $(HERE)Tandas.xcodeproj $(HERE).build $(HERE)DerivedData $(HERE)build
