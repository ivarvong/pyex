class Point:
    def __init__(self, x, y):
        self.x, self.y = x, y
    def __repr__(self):
        return f"Point({self.x}, {self.y})"
    def __eq__(self, o):
        return (self.x, self.y) == (o.x, o.y)
print([Point(1,2), Point(3,4)])
print(Point(1,2) == Point(1,2))
