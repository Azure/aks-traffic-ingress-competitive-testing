# Build stage
FROM mcr.microsoft.com/oss/go/microsoft/golang:1.23 AS builder

WORKDIR /app

# Copy go mod files
COPY go.mod ./

# Copy source code
COPY main.go ./

# Build the application
RUN CGO_ENABLED=0 GOOS=linux go build -o server

# Final stage
FROM gcr.io/distroless/static:nonroot

WORKDIR /app

# Copy binary from builder
COPY --from=builder /app/server .

# Set PORT environment variable (can be overridden)
ENV PORT=3333

# Expose the port
EXPOSE 3333

# Run the application
CMD ["./server"]
