nums = [2,4,6,8]
print(all(n%2==0 for n in nums), any(n>7 for n in nums))
print(max(nums, key=lambda x:-x), min(["bb","a","ccc"], key=len))
