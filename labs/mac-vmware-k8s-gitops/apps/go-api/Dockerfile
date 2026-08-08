# syntax=docker/dockerfile:1.7
FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go test ./... && \
    CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/go-api .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/go-api /go-api
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/go-api"]

