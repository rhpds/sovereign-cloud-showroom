.PHONY: build clean serve stop reset help

# Default target
.DEFAULT_GOAL := help

# Build the Antora site
build:
	@echo "Starting build process..."
	@echo "Removing old site..."
	@rm -rf ./www/*
	@echo "Building new site..."
	@npx antora --fetch default-site.yml
	@echo "Build process complete. Check the ./www folder for the generated site."
	@echo "To view the site locally, run: make serve"
	@echo "If already running then browse to http://localhost:8080/index.html"

# Clean the build artifacts
clean:
	@echo "Removing old site..."
	@rm -rf ./www/*
	@echo "Old site removed"

# Serve the site locally
serve:
	@echo "Starting serve process..."
	@podman run -d --rm --name showroom-httpd -p 8080:8080 \
		-v "./www:/var/www/html/:z" \
		registry.access.redhat.com/ubi9/httpd-24:1-301
	@echo "Serving lab content on http://localhost:8080/index.html"

# Stop the local server
stop:
	@echo "Stopping serve process..."
	@podman kill showroom-httpd || true
	@echo "Stopped serve process."

# Reset: clean, build, and serve
reset:
	@echo "Killing pod..."
	@podman kill showroom-httpd || true
	@echo "Removing old site..."
	@rm -rf ./www/*
	@echo "Old site removed"
	@echo "Building new site"
	@npx antora --fetch default-site.yml
	@echo "Starting serve process..."
	@podman run -d --rm --name showroom-httpd -p 8080:8080 \
		-v "./www:/var/www/html/:z" \
		registry.access.redhat.com/ubi9/httpd-24:1-301
	@echo "Serving lab content on http://localhost:8080/index.html"

# Help target
help:
	@echo "Available targets:"
	@echo "  make build   - Build the Antora site"
	@echo "  make clean   - Remove build artifacts"
	@echo "  make serve   - Start local server on http://localhost:8080"
	@echo "  make stop    - Stop the local server"
	@echo "  make reset   - Clean, build, and serve the site"
	@echo "  make help    - Show this help message"
