.PHONY: project build test clean

project:
	cd $(dir $(realpath $(firstword $(MAKEFILE_LIST)))) && xcodegen

build: project
	xcodebuild build \
		-project ios/Tandas.xcodeproj \
		-scheme Tandas \
		-destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
		| xcpretty

test: project
	xcodebuild test \
		-project ios/Tandas.xcodeproj \
		-scheme Tandas \
		-destination 'platform=iOS Simulator,name=iPhone 15 Pro,OS=latest' \
		| xcpretty

clean:
	rm -rf ios/Tandas.xcodeproj ios/.build ios/DerivedData ios/build
