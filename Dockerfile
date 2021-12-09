# setup build arguments for version of dependencies to use
ARG DOCKER_GEN_VERSION=0.7.6
ARG FOREGO_VERSION=0.16.1

# Use a specific version of golang to build both binaries
FROM golang:1.17.5 as gobuilder

# Build docker-gen from scratch
FROM gobuilder as dockergen

ARG DOCKER_GEN_VERSION

RUN git clone https://github.com/jwilder/docker-gen \
   && cd /go/docker-gen \
   && git -c advice.detachedHead=false checkout $DOCKER_GEN_VERSION \
   && go mod download \
   && CGO_ENABLED=0 GOOS=linux go build -ldflags "-X main.buildVersion=${DOCKER_GEN_VERSION}" ./cmd/docker-gen \
   && go clean -cache \
   && mv docker-gen /usr/local/bin/ \
   && cd - \
   && rm -rf /go/docker-gen

# Build forego from scratch
# Because this relies on golang workspaces, we need to use go < 1.8. 
FROM gobuilder as forego

# Download the sources for the given version
ARG FOREGO_VERSION
ADD https://github.com/jwilder/forego/archive/v${FOREGO_VERSION}.tar.gz sources.tar.gz

# Move the sources into the right directory
RUN tar -xzf sources.tar.gz && \
   mkdir -p /go/src/github.com/ddollar/ && \
   mv forego-* /go/src/github.com/ddollar/forego

# Install the dependencies and make the forego executable
WORKDIR /go/src/github.com/ddollar/forego/
RUN go get -v ./... && \
   CGO_ENABLED=0 GOOS=linux go build -o forego .

# Build the final image
FROM nginx:1.19.10
LABEL maintainer="Nicolas Duchon <nicolas.duchon@gmail.com> (@buchdag)"

# Install wget and install/updates certificates
RUN apt-get update \
 && apt-get install -y -q --no-install-recommends \
    ca-certificates \
    wget \
 && apt-get clean \
 && rm -r /var/lib/apt/lists/*


# Configure Nginx and apply fix for very long server names
RUN echo "daemon off;" >> /etc/nginx/nginx.conf \
 && sed -i 's/worker_processes  1/worker_processes  auto/' /etc/nginx/nginx.conf \
 && sed -i 's/worker_connections  1024/worker_connections  10240/' /etc/nginx/nginx.conf

# Install Forego + docker-gen
COPY --from=forego /go/src/github.com/ddollar/forego/forego /usr/local/bin/forego
COPY --from=dockergen /usr/local/bin/docker-gen /usr/local/bin/docker-gen

# Add DOCKER_GEN_VERSION environment variable
# Because some external projects rely on it
ARG DOCKER_GEN_VERSION
ENV DOCKER_GEN_VERSION=${DOCKER_GEN_VERSION}

COPY network_internal.conf /etc/nginx/

COPY . /app/
WORKDIR /app/

ENV DOCKER_HOST unix:///tmp/docker.sock

VOLUME ["/etc/nginx/certs", "/etc/nginx/dhparam"]

ENTRYPOINT ["/app/docker-entrypoint.sh"]
CMD ["forego", "start", "-r"]
