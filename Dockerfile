FROM ruby:3.3.6-bookworm
RUN apt-get update && apt-get install -y --no-install-recommends default-libmysqlclient-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile ./
RUN bundle install
COPY . .
CMD ["bundle", "exec", "ruby", "runner.rb"]
