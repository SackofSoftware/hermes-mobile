# Hermes Mobile — common dev tasks.
# `make run` builds and launches the app on a simulator; `make test` runs the suite.

.PHONY: setup generate test build run run-device clean

setup: ## Resolve deps and generate the Xcode project
	tuist install
	tuist generate --no-open

generate: ## Regenerate the Xcode project
	tuist generate --no-open

test: ## Run the HermesKit test suite (streamed output)
	./scripts/test.sh

build: ## Build the app for an iOS Simulator (no signing)
	xcodebuild build -workspace HermesMobile.xcworkspace -scheme HermesMobile \
		-configuration Debug -destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO -quiet

run: ## Build, install, and launch on a simulator (SIM_NAME overrides device)
	./scripts/run-sim.sh

run-device: ## Build, install, and launch on a connected device (needs DEVELOPMENT_TEAM)
	./scripts/run-device.sh

clean: ## Remove generated project and build artifacts
	rm -rf HermesMobile.xcodeproj HermesMobile.xcworkspace Derived .build
