FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o dnsmasq-exporter .

FROM alpine:3.20
COPY --from=builder /app/dnsmasq-exporter /usr/local/bin/dnsmasq-exporter
ENTRYPOINT ["dnsmasq-exporter"]
