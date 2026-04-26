"""
statistics module: mean, median, stdev, variance, mode.
Exercises: statistics stdlib module implementation.
"""
import statistics

data = [1, 2, 3, 4, 5]

print(statistics.mean(data))
print(statistics.median(data))
print(statistics.median([1, 100, 2]))
print(round(statistics.stdev(data), 4))
print(round(statistics.variance(data), 4))
print(statistics.mode([1, 2, 2, 3, 3, 3]))
print(statistics.mean([10, 20, 30]))
print(statistics.median_low([1, 2, 3, 4]))
print(statistics.median_high([1, 2, 3, 4]))
