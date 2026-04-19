FROM ubuntu:22.04 AS builder

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY CMakeLists.txt .
COPY main.cpp .

RUN mkdir build && cd build && \
    cmake .. && \
    make

FROM ubuntu:22.04

WORKDIR /app

COPY --from=builder /app/build/telemetry_server .

EXPOSE 8080

CMD ["./telemetry_server"]
