"""
os.getcwd() returns a string; os.chdir() accepts a path without raising.
Exercises: os module path functions.
"""
import os

cwd = os.getcwd()
print(isinstance(cwd, str))
print(len(cwd) > 0)

# chdir should not raise
os.chdir(".")
after = os.getcwd()
print(isinstance(after, str))
print(len(after) > 0)

# os.path functions still work
print(os.path.basename("/foo/bar.txt"))
print(os.path.dirname("/foo/bar.txt"))
