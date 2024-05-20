FROM 563770389081.dkr.ecr.eu-west-1.amazonaws.com/intermediate:27 as intermediate

# The base image used for all images
FROM ubuntu:20.04

ENV DEBIAN_FRONTEND="noninteractive"

RUN apt-get update -qq && \
  apt-get install -y --no-install-recommends \
  python3 \
  python3-venv \
  python3-pip \
  python3-dev \
  # required by psycopg2 at build and runtime
  libpq-dev \
  # required for health check
  curl \
  && apt-get autoremove -y

# Make sure that all security updates are installed
RUN apt-get update && apt-get dist-upgrade -y --no-install-recommends

RUN update-alternatives --install /usr/bin/python python /usr/bin/python3 100 \
   && update-alternatives --install /usr/bin/pip pip /usr/bin/pip3 100

# Create rasa user and group
RUN useradd -rm -d /app -s /sbin/nologin -g root -u 1001 rasa && groupadd -g 1001 rasa

FROM rasa/rasa:base-poetry-1.1.13

# install poetry
ENV POETRY_VERSION 1.1.13
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH "/root/.local/bin:${PATH}"

# The base builder image used for all images
FROM rasa/rasa:base-poetry-1.1.13

RUN apt-get update -qq && \
  apt-get install -y --no-install-recommends \
  build-essential \
  wget \
  openssh-client \
  graphviz-dev \
  pkg-config \
  git-core \
  openssl \
  libssl-dev \
  libffi7 \
  libffi-dev \
  libpng-dev \
  && apt-get autoremove -y

# Make sure that all security updates are installed
RUN apt-get update && apt-get dist-upgrade -y --no-install-recommends

# The default Docker image
FROM rasa/rasa:base-builder-3f26326da9e19d8f5b2be68a8dd625490688e821328ecc454cadcf3f8f7999e4-poetry-1.1.13 as builder
# copy files
COPY . /build/

# change working directory
WORKDIR /build

# install dependencies
RUN python -m venv /opt/venv && \
  . /opt/venv/bin/activate && \
  pip install --no-cache-dir -U "pip==22.*" -U "wheel>0.38.0" && \
  poetry install --no-dev --no-root --no-interaction && \
  poetry build -f wheel -n && \
  pip install --no-deps dist/*.whl && \
  rm -rf dist *.egg-info

# start a new build stage
FROM rasa/rasa:base-poetry-1.1.13 as runner

# copy everything from /opt
COPY --from=builder /opt/venv /opt/venv

# make sure we use the virtualenv
ENV PATH="/opt/venv/bin:$PATH"

# set HOME environment variable
ENV HOME=/app

# update permissions & change user to not run as root
WORKDIR /app
RUN chgrp -R 0 /app && chmod -R g=u /app && chmod o+wr /app

## Download needed apt packages and aws to be able to upload to s3
USER root

COPY --from=intermediate /usr/local/share/ca-certificates /usr/local/share/ca-certificates

RUN [ `dpkg --print-architecture` = "amd64" ] && CPU_ARCH="x86_64" || CPU_ARCH="aarch64" && \
    apt-get update -y && \
    apt-get install --no-install-recommends --no-install-suggests -y unzip gettext-base jq vim busybox ca-certificates && \
    for i in $(busybox --list); do ln -sf /usr/bin/busybox /usr/local/bin/$i; done && \
    apt-get purge --auto-remove -y && rm -rf /var/lib/apt/lists/* /var/cache/apt/* && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-${CPU_ARCH}.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf aws awscliv2.zip && \
    update-ca-certificates && \
    apt-get clean && \
    apt-get purge --auto-remove -y && \
    rm -rf /tmp/* /var/cache/apt/* /var/lib/apt/lists/*

## Create custom entrypoint
COPY ./src/conf/entrypoints/entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

## Copy over RASA config templates
COPY ./src/conf/credentials.template /app/credentials.template
COPY ./src/conf/endpoints.template /app/endpoints.template
RUN chmod 644 /app/credentials.template && \
    chmod 644 /app/endpoints.template

COPY ./rasa-extras extras

RUN sed -i 's/20.3.0/21.12.1/g' extras/requirements.txt
RUN pip install -r extras/requirements.txt

## Official image throws errors, below is a workaround
RUN mkdir /.config && \
    chown -R 1001 /.config && \
    chmod -R 775 /.config
USER 1001
ENV MPLCONFIGDIR=/app/.config
RUN mkdir -p /app/.config/
RUN mkdir -p /app/training

USER 1001

# create a volume for temporary data
VOLUME /tmp

# change shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# the entry point
EXPOSE 5005
ENTRYPOINT ["rasa"]
CMD ["--help"]