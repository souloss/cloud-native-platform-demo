FROM golang:1.27-alpine AS build
ARG SERVICE
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY catalog ./catalog
COPY orders ./orders
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags='-s -w' -o /out/service ./${SERVICE}

FROM alpine:3.22
COPY --from=build /out/service /service
RUN adduser -D -u 10001 app
USER app
ENTRYPOINT ["/service"]
