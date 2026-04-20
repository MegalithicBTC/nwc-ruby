FROM ruby:3.4.9-trixie
LABEL project="nwc-ruby"

# Build dependencies for rbsecp256k1 native extension
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential automake pkg-config libtool libffi-dev libgmp-dev && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /gem

# Install gems (cached unless Gemfile/gemspec change)
COPY Gemfile nostr_wallet_connect.gemspec ./
COPY lib/nostr_wallet_connect/version.rb lib/nostr_wallet_connect/version.rb
RUN bundle install --jobs 16

# Copy gem source
COPY . .

CMD ["bundle", "exec", "rspec"]
