FROM ruby:3.4.6-slim-bookworm AS base

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
  && apt-get install --no-install-recommends -y curl \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN (curl -sL https://deb.nodesource.com/setup_20.x | bash -)

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
    build-essential \
    netcat-openbsd \
    libmariadb-dev \
    libcap2-bin \
    nano \
    libyaml-dev \
    nodejs \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/*

RUN setcap 'cap_net_bind_service=+ep' /usr/local/bin/ruby

ENV PATH="/opt/postal/app/bin:${PATH}"

RUN useradd -r -d /opt/postal -m -s /bin/bash -u 999 postal
USER postal
RUN mkdir -p /opt/postal/app /opt/postal/config
WORKDIR /opt/postal/app

RUN gem install bundler -v 2.7.2 --no-doc

COPY --chown=postal Gemfile Gemfile.lock ./
RUN bundle install

COPY --chmod=0755 ./docker/wait-for.sh /docker-entrypoint.sh
COPY --chown=postal . .

# normalize line endings (fixes ruby \r issues)
RUN find . -type f -name "*.rb" -exec dos2unix {} \; || true
RUN find ./bin -type f -exec dos2unix {} \; || true
RUN chmod +x ./bin/*

ARG VERSION
ARG BRANCH
RUN if [ "$VERSION" != "" ]; then echo $VERSION > VERSION; fi \
  && if [ "$BRANCH" != "" ]; then echo $BRANCH > BRANCH; fi

ENV POSTAL_CONFIG_FILE_PATH=/config/postal.yml

ENTRYPOINT [ "/docker-entrypoint.sh" ]
# this is the fix: run all services
CMD ["postal", "web-server"]
# ci target - skip asset compilation
FROM base AS ci

# full target - default
FROM base AS full

RUN RAILS_GROUPS=assets bundle exec rake assets:precompile
RUN touch /opt/postal/app/public/assets/.prebuilt

USER root

CMD ["bash", "/opt/postal/app/docker/run-all.sh"]