FROM elixir:1.19-otp-28

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy dependency files first for layer caching
COPY mix.exs mix.lock ./
COPY .formatter.exs ./

# Fetch and compile dependencies
RUN mix deps.get
RUN mix compile

# Copy the rest of the application
COPY lib/ lib/
COPY demo/ demo/
COPY config/ config/

# Final compile after source copy
RUN mix compile

EXPOSE 4000

CMD ["mix", "run", "demo/eval_server.exs"]
