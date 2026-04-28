bench = fn name, source ->
  Pyex.run!(source)

  times =
    for _ <- 1..20 do
      {us, _} = :timer.tc(fn -> Pyex.run!(source) end)
      us
    end

  sorted = Enum.sort(times)
  p50 = Enum.at(sorted, 9)
  p90 = Enum.at(sorted, 17)
  IO.puts("  #{name}: p50=#{Float.round(p50 / 1000, 1)}ms p90=#{Float.round(p90 / 1000, 1)}ms")
end

IO.puts("deque benchmarks (n=4000, 20 runs each)\n")

bench.("append loop", """
from collections import deque
d = deque()
for i in range(4000):
    d.append(i)
""")

bench.("queue (append + popleft)", """
from collections import deque
d = deque()
for i in range(4000):
    d.append(i)
total = 0
while d:
    total += d.popleft()
total
""")

bench.("pop loop", """
from collections import deque
d = deque()
for i in range(4000):
    d.append(i)
total = 0
while d:
    total += d.pop()
total
""")

bench.("bounded sliding window maxlen=100", """
from collections import deque
d = deque(maxlen=100)
for i in range(4000):
    d.append(i)
""")

bench.("appendleft loop", """
from collections import deque
d = deque()
for i in range(4000):
    d.appendleft(i)
""")
