defmodule Mix.Tasks.Pyex.Bench do
  @shortdoc "Benchmark Pyex parse->eval loop with concurrent workers"
  @moduledoc """
  Runs multiple concurrent Pyex workers, each reporting stats separately.

      mix pyex.bench [--workers 4] [--interval 5] [--runtime 10]

  Options:
    --workers   Number of concurrent workers (default: 4)
    --interval  Seconds between reports (default: 5)
    --runtime   Total benchmark runtime in seconds (default: 10)

  Each worker simulates Stripe webhook signature verification:
  - Reads payload and signature from filesystem
  - Verifies HMAC-SHA256 signature (valid and invalid cases)
  - Parses JSON and extracts event data (on valid signatures only)
  """

  use Mix.Task

  @webhook_secret "whsec_test_secret_key_for_benchmarking_only"

  @default_payload ~s({"id":"evt_1234567890","object":"event","api_version":"2023-10-16","created":1699900000,"type":"invoice.payment_succeeded","data":{"object":{"id":"in_1234567890","object":"invoice","amount_due":2000,"amount_paid":2000,"amount_remaining":0,"currency":"usd","customer":"cus_1234567890","status":"paid"}}})

  def valid_signature do
    timestamp = "1699900000"
    signed_payload = timestamp <> "." <> @default_payload

    signature =
      :crypto.mac(:hmac, :sha256, @webhook_secret, signed_payload)
      |> Base.encode16(case: :lower)

    "t=" <> timestamp <> ",v1=" <> signature
  end

  def invalid_signature do
    timestamp = "1699900000"
    signed_payload = timestamp <> "." <> @default_payload

    signature =
      :crypto.mac(:hmac, :sha256, "whsec_wrong_secret", signed_payload)
      |> Base.encode16(case: :lower)

    "t=" <> timestamp <> ",v1=" <> signature
  end

  def missing_timestamp_signature do
    # Signature without timestamp
    "v1=5257a869e7ecebeda32affa62cdca3fa51cad7e77a0e56ff536d0ce8e108d8bd"
  end

  def missing_v1_signature do
    # Only v0 signature (should be ignored)
    "t=1699900000,v0=6ffbb59b2300aae63f272406069a9788598b792a944a07aba816edb039989a39"
  end

  def stale_timestamp_signature do
    # Timestamp from 1 year ago (definitely stale)
    # Jan 1, 2021
    timestamp = "1609459200"
    signed_payload = timestamp <> "." <> @default_payload

    signature =
      :crypto.mac(:hmac, :sha256, @webhook_secret, signed_payload)
      |> Base.encode16(case: :lower)

    "t=" <> timestamp <> ",v1=" <> signature
  end

  def invalid_timestamp_signature do
    # Non-numeric timestamp
    "t=not_a_number,v1=5257a869e7ecebeda32affa62cdca3fa51cad7e77a0e56ff536d0ce8e108d8bd"
  end

  def invalid_json_payload do
    # Malformed JSON
    "{invalid json"
  end

  @test_cases [
    {:valid, :valid_signature, @default_payload, "true"},
    {:invalid_signature, :invalid_signature, @default_payload, "false"},
    {:missing_timestamp, :missing_timestamp_signature, @default_payload, "false"},
    {:missing_v1, :missing_v1_signature, @default_payload, "false"},
    {:stale_timestamp, :stale_timestamp_signature, @default_payload, "false"},
    {:invalid_timestamp, :invalid_timestamp_signature, @default_payload, "false"},
    {:invalid_json, :valid_signature, :invalid_json_payload, "false"}
  ]

  @default_source ~S'''
  import json
  import hmac
  import time


  class StripeWebhookError(Exception):
      pass


  class SignatureVerificationError(StripeWebhookError):
      pass


  class InvalidPayloadError(StripeWebhookError):
      pass


  def parse_stripe_header(header):
      # Parse Stripe-Signature header into timestamp and signatures.
      # Returns tuple of (timestamp, signatures_dict) where signatures_dict
      # maps version (e.g., 'v1') to signature value.
      if not header:
          return None, {}
      
      parts = {}
      timestamp = None
      
      for element in header.split(','):
          element = element.strip()
          if '=' not in element:
              continue
              
          key, value = element.split('=', 1)
          key = key.strip()
          value = value.strip()
          
          if key == 't':
              timestamp = value
          elif key.startswith('v'):
              parts[key] = value
              
      return timestamp, parts


  def verify_signature(payload, sig_header, secret, tolerance_sec=300):
      # Verify Stripe webhook signature with timing attack protection
      # and replay attack prevention.
      #
      # Args:
      #     payload: The raw request body (string)
      #     sig_header: The Stripe-Signature header value (string)
      #     secret: The webhook endpoint secret (string)
      #     tolerance_sec: Max age of timestamp to accept (default 5 min)
      #
      # Returns:
      #     bool: True if signature is valid and fresh
      #
      # Raises:
      #     SignatureVerificationError: If signature is invalid or timestamp too old
      
      if not payload or not sig_header or not secret:
          raise SignatureVerificationError("Missing required parameters")
      
      timestamp, signatures = parse_stripe_header(sig_header)
      
      if not timestamp:
          raise SignatureVerificationError("Missing timestamp in signature header")
      
      if not signatures:
          raise SignatureVerificationError("No signatures found in header")
      
      # Check for v1 signature (current scheme)
      if 'v1' not in signatures:
          raise SignatureVerificationError("Missing v1 signature")
      
      # Verify timestamp freshness (replay protection)
      try:
          ts_int = int(timestamp)
          now = int(time.time())
          if abs(now - ts_int) > tolerance_sec:
              raise SignatureVerificationError(
                  "Timestamp too old: " + str(now - ts_int) + "s"
              )
      except ValueError:
          raise SignatureVerificationError("Invalid timestamp: " + str(timestamp))
      
      # Compute expected signature
      signed_payload = timestamp + "." + payload
      expected_sig = hmac.new(
          secret.encode('utf-8'),
          signed_payload.encode('utf-8'),
          'sha256'
      ).hexdigest()
      
      # Constant-time comparison against all provided signatures
      for version, signature in signatures.items():
          # Only check v1 (ignore v0 test signatures)
          if version != 'v1':
              continue
              
          if hmac.compare_digest(signature, expected_sig):
              return True
              
      raise SignatureVerificationError("Signature mismatch")


  def parse_event(payload):
      # Parse Stripe event payload from JSON.
      #
      # Args:
      #     payload: JSON string
      #
      # Returns:
      #     dict: Parsed event object
      #
      # Raises:
      #     InvalidPayloadError: If JSON is malformed
      try:
          return json.loads(payload)
      except json.JSONDecodeError as e:
          raise InvalidPayloadError("Invalid JSON: " + str(e))


  def extract_invoice_data(event):
      # Extract relevant invoice data from a Stripe event.
      #
      # Args:
      #     event: Parsed Stripe event dict
      #
      # Returns:
      #     dict: Extracted invoice data
      event_type = event.get('type')
      data_obj = event.get('data', {}).get('object', {})
      
      return {
          'event_type': event_type,
          'invoice_id': data_obj.get('id'),
          'amount_paid': data_obj.get('amount_paid'),
          'customer_id': data_obj.get('customer'),
          'currency': data_obj.get('currency'),
          'status': data_obj.get('status')
      }


  def handle_webhook(payload_path, sig_path, secret, expected_valid):
      # Main webhook handler - verifies signature and processes event.
      #
      # Args:
      #     payload_path: Path to payload file
      #     sig_path: Path to signature file
      #     secret: Webhook secret
      #     expected_valid: For testing - expected verification result
      #
      # Returns:
      #     dict: Processing result
      
      # Read files
      try:
          with open(payload_path, 'r') as f:
              payload = f.read()
      except IOError as e:
          raise StripeWebhookError("Failed to read payload: " + str(e))
          
      try:
          with open(sig_path, 'r') as f:
              sig_header = f.read().strip()
      except IOError as e:
          raise StripeWebhookError("Failed to read signature: " + str(e))
      
      # Verify signature
      try:
          is_valid = verify_signature(payload, sig_header, secret)
          
          # For testing: verify logic matches expectation
          if is_valid != expected_valid:
              raise ValueError(
                  "Logic error: expected " + str(expected_valid) + ", got " + str(is_valid)
              )
              
      except SignatureVerificationError:
          if expected_valid:
              raise  # Should have been valid
          return {'status': 'rejected', 'reason': 'invalid_signature'}
      
      # Parse and extract event data
      event = parse_event(payload)
      result = extract_invoice_data(event)
      result['status'] = 'processed'
      
      return result


  # Entry point for benchmark
  result = handle_webhook(
      '/webhook/payload.json',
      '/webhook/signature.txt',
      'whsec_test_secret_key_for_benchmarking_only',
      read_file('/webhook/expected.txt').strip() == 'true'
  )
  '''

  defmodule Worker do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      worker_id = Keyword.get(opts, :worker_id)
      source = Keyword.get(opts, :source)
      payload = Keyword.get(opts, :payload)
      interval = Keyword.get(opts, :interval, 5)
      runtime = Keyword.get(opts, :runtime, 10)
      coordinator = Keyword.get(opts, :coordinator)
      test_cases = Keyword.get(opts, :test_cases)

      _builtins = Pyex.Builtins.env()

      # Create filesystem with all test case files
      base_files = %{
        "webhook/payload.json" => payload,
        "webhook/expected_true.txt" => "true",
        "webhook/expected_false.txt" => "false"
      }

      test_files =
        Enum.reduce(test_cases, base_files, fn {name, sig_func, payload_val, _expected}, acc ->
          sig_val = apply(Mix.Tasks.Pyex.Bench, sig_func, [])

          payload_content =
            if is_atom(payload_val),
              do: apply(Mix.Tasks.Pyex.Bench, payload_val, []),
              else: payload_val

          acc
          |> Map.put("webhook/signature_#{name}.txt", sig_val)
          |> Map.put("webhook/payload_#{name}.json", payload_content)
        end)

      filesystem = Pyex.Filesystem.Memory.new(test_files)
      ctx = Pyex.Ctx.new(filesystem: filesystem)

      state = %{
        worker_id: worker_id,
        source: source,
        ctx: ctx,
        test_cases: test_cases,
        current_case_index: 0,
        count: 0,
        case_counts: %{},
        total_count: 0,
        interval: interval,
        runtime: runtime,
        coordinator: coordinator,
        start_time: System.monotonic_time(),
        interval_start: System.monotonic_time()
      }

      send(self(), :tick)
      Process.send_after(self(), :stop, runtime * 1000)
      {:ok, state}
    end

    @impl true
    def handle_info(:tick, state) do
      elapsed = System.monotonic_time() - state.interval_start
      elapsed_sec = System.convert_time_unit(elapsed, :native, :second)

      report = %{
        worker_id: state.worker_id,
        elapsed_sec: elapsed_sec,
        runs: state.count,
        case_counts: state.case_counts,
        runs_per_sec: div(state.count, state.interval)
      }

      send(state.coordinator, {:report, report})

      Process.send_after(self(), :tick, state.interval * 1000)

      {:noreply,
       %{
         state
         | count: 0,
           case_counts: %{},
           interval_start: System.monotonic_time()
       }}
    end

    @impl true
    def handle_info(:stop, state) do
      total_elapsed = System.monotonic_time() - state.start_time
      total_sec = System.convert_time_unit(total_elapsed, :native, :second)

      send(
        state.coordinator,
        {:done, state.worker_id, state.total_count, state.current_case_index, total_sec}
      )

      {:stop, :normal, state}
    end

    @impl true
    def handle_cast(:run, state) do
      # Get current test case
      test_cases = state.test_cases
      case_index = state.current_case_index
      {case_name, _sig_func, _payload_val, expected} = Enum.at(test_cases, case_index)

      # Set up file paths for this test case
      sig_file = "/webhook/signature_#{case_name}.txt"
      payload_file = "/webhook/payload_#{case_name}.json"
      expected_file = "/webhook/expected_#{expected}.txt"

      # Modify source to use correct files for this iteration
      modified_source =
        state.source
        |> String.replace("/webhook/signature.txt", sig_file)
        |> String.replace("/webhook/payload.json", payload_file)
        |> String.replace("/webhook/expected.txt", expected_file)

      case Pyex.run(modified_source, state.ctx) do
        {:ok, _, _} ->
          new_case_counts = Map.update(state.case_counts, case_name, 1, &(&1 + 1))
          next_index = rem(case_index + 1, length(test_cases))

          {:noreply,
           %{
             state
             | count: state.count + 1,
               case_counts: new_case_counts,
               total_count: state.total_count + 1,
               current_case_index: next_index
           }, {:continue, :loop}}

        {:error, _} ->
          # Count errors but continue
          new_case_counts = Map.update(state.case_counts, case_name, 1, &(&1 + 1))
          next_index = rem(case_index + 1, length(test_cases))

          {:noreply,
           %{
             state
             | count: state.count + 1,
               case_counts: new_case_counts,
               total_count: state.total_count + 1,
               current_case_index: next_index
           }, {:continue, :loop}}
      end
    end

    @impl true
    def handle_continue(:loop, state) do
      GenServer.cast(self(), :run)
      {:noreply, state}
    end
  end

  defmodule Coordinator do
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      workers = Keyword.get(opts, :workers, 4)
      interval = Keyword.get(opts, :interval, 5)
      runtime = Keyword.get(opts, :runtime, 10)
      caller = Keyword.get(opts, :caller)
      source = Keyword.get(opts, :source)
      payload = Keyword.get(opts, :payload)
      test_cases = Keyword.get(opts, :test_cases)

      state = %{
        workers: workers,
        interval: interval,
        runtime: runtime,
        caller: caller,
        source: source,
        payload: payload,
        test_cases: test_cases,
        worker_pids: [],
        reports: %{},
        completed: 0,
        results: []
      }

      {:ok, state, {:continue, :start_workers}}
    end

    @impl true
    def handle_continue(:start_workers, state) do
      pids =
        for i <- 1..state.workers do
          {:ok, pid} =
            Worker.start_link(
              worker_id: i,
              source: state.source,
              payload: state.payload,
              interval: state.interval,
              runtime: state.runtime,
              coordinator: self(),
              test_cases: state.test_cases
            )

          GenServer.cast(pid, :run)
          pid
        end

      {:noreply, %{state | worker_pids: pids}}
    end

    @impl true
    def handle_info({:report, report}, state) do
      reports = Map.put(state.reports, report.worker_id, report)

      memory = :erlang.memory(:total)
      memory_mb = div(memory, 1024 * 1024)

      IO.puts("\n[#{report.elapsed_sec}s | memory: #{memory_mb} MB]")

      reports
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.each(fn {id, r} ->
        case_counts_str =
          r.case_counts
          |> Enum.map(fn {name, count} -> "#{name}:#{count}" end)
          |> Enum.join(", ")

        IO.puts("  Worker #{id}: #{r.runs} runs (#{r.runs_per_sec}/sec) | #{case_counts_str}")
      end)

      total_runs = reports |> Map.values() |> Enum.map(& &1.runs) |> Enum.sum()

      # Aggregate case counts across all workers
      all_case_counts =
        reports
        |> Map.values()
        |> Enum.map(& &1.case_counts)
        |> Enum.reduce(%{}, fn counts, acc ->
          Map.merge(acc, counts, fn _k, v1, v2 -> v1 + v2 end)
        end)

      total_case_str =
        all_case_counts
        |> Enum.map(fn {name, count} -> "#{name}:#{count}" end)
        |> Enum.join(", ")

      IO.puts("  Total: #{total_runs} runs | #{total_case_str}")

      {:noreply, %{state | reports: reports}}
    end

    @impl true
    def handle_info({:done, worker_id, total_count, _case_index, total_sec}, state) do
      results = [{worker_id, total_count, total_sec} | state.results]
      completed = state.completed + 1

      if completed >= state.workers do
        IO.puts("\n--- Benchmark Complete ---")

        results
        |> Enum.sort_by(fn {id, _, _} -> id end)
        |> Enum.each(fn {id, count, sec} ->
          IO.puts("Worker #{id}: #{count} runs | #{div(count, sec)}/sec avg")
        end)

        grand_total = results |> Enum.map(fn {_, c, _} -> c end) |> Enum.sum()
        IO.puts("\nGrand total: #{grand_total} runs")

        send(state.caller, :done)
        {:stop, :normal, %{state | results: results, completed: completed}}
      else
        {:noreply, %{state | results: results, completed: completed}}
      end
    end
  end

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _positional, _} =
      OptionParser.parse(args,
        switches: [workers: :integer, interval: :integer, runtime: :integer],
        aliases: [w: :workers, i: :interval, r: :runtime]
      )

    workers = Keyword.get(opts, :workers, 4)
    interval = Keyword.get(opts, :interval, 5)
    runtime = Keyword.get(opts, :runtime, 10)

    IO.puts("Benchmarking: Stripe webhook signature verification")
    IO.puts("Workers: #{workers}")
    IO.puts("Report interval: #{interval}s")
    IO.puts("Total runtime: #{runtime}s")
    IO.puts("Testing: alternating valid and invalid signatures\n")

    {:ok, _pid} =
      Coordinator.start_link(
        workers: workers,
        interval: interval,
        runtime: runtime,
        caller: self(),
        source: @default_source,
        payload: @default_payload,
        test_cases: @test_cases
      )

    receive do
      :done -> :ok
    end
  end
end
