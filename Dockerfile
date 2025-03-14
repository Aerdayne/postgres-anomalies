FROM ruby:3.4.1-slim-bullseye

ENV HOME /postgres_anomalies
RUN mkdir -p $HOME
WORKDIR $HOME

ENV BUNDLE_JOBS 8
ENV BUNDLE_RETRY 3
ENV PATH "/app/local/ruby/3.4/bin:${PATH}"
ENV GEM_HOME /app/local/ruby/3.4

RUN apt-get update && apt-get install -y build-essential libpq-dev postgresql bash

RUN gem update --system
RUN gem install bundler:2.3.12

COPY . $HOME

RUN bundle install
