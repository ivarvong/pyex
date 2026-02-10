import Config

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {Pyex.Trace, []}

config :logger, level: :warning
