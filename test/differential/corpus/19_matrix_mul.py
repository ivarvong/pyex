A, B = [[1,2],[3,4]], [[5,6],[7,8]]
C = [[sum(A[i][k]*B[k][j] for k in range(2)) for j in range(2)] for i in range(2)]
print(C)
