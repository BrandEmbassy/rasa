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

FROM rasa:base-localdev

# install poetry
ENV POETRY_VERSION 1.1.13
RUN curl -sSL https://install.python-poetry.org | python3 -
ENV PATH "/root/.local/bin:${PATH}"

# The base builder image used for all images
FROM rasa:base-poetry-1.1.13

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
FROM rasa:base-builder-localdev as builder
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
FROM rasa:base-localdev as runner

# copy everything from /opt
COPY --from=builder /opt/venv /opt/venv

# make sure we use the virtualenv
ENV PATH="/opt/venv/bin:$PATH"

# set HOME environment variable
ENV HOME=/app

# update permissions & change user to not run as root
WORKDIR /app
RUN chgrp -R 0 /app && chmod -R g=u /app && chmod o+wr /app
USER 1001

# create a volume for temporary data
VOLUME /tmp

# change shell
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# the entry point
EXPOSE 5005
ENTRYPOINT ["rasa"]
CMD ["--help"]