###############################################
#
# Makefile
#
###############################################

.DEFAULT_GOAL := build

# `test` is also a directory name in this repo. Without this, make sees the
# directory, decides the target is up to date, and silently runs nothing.
.PHONY: build clean test bench cli doc doc-serve validate

# Build the package.
build:
	zig build

# Clean the build artifacts.
clean:
	rm -rf .zig-cache zig-out

# Run the complete registered test graph.
test:
	zig build test

# Run the general, diagnostic, and AOT benchmark suites.
bench:
	zig build benchmark -Doptimize=ReleaseFast
	zig build bench-diagnostic -Doptimize=ReleaseFast
	zig build bench-aot -Doptimize=ReleaseFast

# Render a sample chat template through the CLI.
cli:
	zig build cli

# Generate the API documentation into zig-out/docs.
doc:
	zig build docs

# Serve the generated docs at http://localhost:8000 (ctrl-c to stop).
doc-serve: doc
	-open http://localhost:8000
	cd zig-out/docs && python3 -m http.server 8000

# Full validation from a clean tree. Sub-makes rather than prerequisites so the
# order is guaranteed even under `make -j`, and so a failure stops the run.
validate:
	$(MAKE) clean
	$(MAKE) build
	$(MAKE) test
	$(MAKE) bench
	$(MAKE) cli
