# Use a minimal base image
FROM alpine:latest

# Install necessary runtime dependencies
RUN apk add --no-cache \
    ca-certificates \
    curl

# Create a non-root user
RUN addgroup -g 1001 -S puny && \
    adduser -S -D -H -u 1001 -s /sbin/nologin puny -G puny

# Copy the binary from the build artifacts
COPY artifacts/puny /usr/local/bin/puny

# Make the binary executable
RUN chmod +x /usr/local/bin/puny

# Create a writable home/config directory for the non-root user.
RUN mkdir -p /app && chown -R puny:puny /app
ENV HOME=/app

# Switch to non-root user
USER puny

# Set the working directory
WORKDIR /app

# Expose a port if needed (adjust based on your application)
# EXPOSE 8080

# Set the entrypoint
ENTRYPOINT ["/usr/local/bin/puny"]
