from functools import reduce
nums = [1,2,3,4,5]
print(reduce(lambda a,b: a+b, nums), reduce(lambda a,b: a*b, nums, 1))
