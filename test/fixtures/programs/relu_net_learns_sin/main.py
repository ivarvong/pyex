"""A ReLU net learns sin on [0, pi/2] — the training loop, in plain floats.

No autodiff, no objects: just forward pass, loss, gradient, weight update.
The shape of how every neural net (LLMs included) trains, small enough to
read in one sitting.
"""
import math


# ── Training data ────────────────────────────────────────────────────
# 100 evenly-spaced points on [0, pi/2] and the sine of each.

HALF_PI = math.pi / 2
N_SAMPLES = 100

inputs = [i * HALF_PI / (N_SAMPLES - 1) for i in range(N_SAMPLES)]
targets = [math.sin(x) for x in inputs]


# ── Network ──────────────────────────────────────────────────────────
# Eight ReLU units in parallel, summed by a learned linear output:
#
#     hidden_j(x)     = relu(slope_j * x + bias_j)
#     prediction(x)   = output_bias + Σ output_weight_j * hidden_j(x)
#
# Each unit contributes a kinked-line segment; together they
# approximate the sine curve as a piecewise-linear function.

N_HIDDEN = 8

# Mild structural init so training has a head start:
#   - slopes at 1.0 (identity-like)
#   - biases place each ReLU knee at a different x along the input range
#   - output weights are a small symmetric spread around zero, which
#     breaks unit-to-unit symmetry without needing a PRNG (a uniform
#     random init works just as well; deterministic values keep this
#     script's output identical across Python implementations)
#   - output bias is zero
slopes = [1.0] * N_HIDDEN
biases = [-j * HALF_PI / N_HIDDEN for j in range(N_HIDDEN)]
output_weights = [(j - (N_HIDDEN - 1) / 2) * 0.02 for j in range(N_HIDDEN)]
output_bias = 0.0


# ── Training loop ────────────────────────────────────────────────────
# Full-batch gradient descent: accumulate gradients across every
# sample, take one SGD step per epoch.

LEARNING_RATE = 0.05
N_EPOCHS = 1000

for epoch in range(N_EPOCHS):
    grad_slopes = [0.0] * N_HIDDEN
    grad_biases = [0.0] * N_HIDDEN
    grad_output_weights = [0.0] * N_HIDDEN
    grad_output_bias = 0.0
    sum_sq_error = 0.0

    for x, target in zip(inputs, targets):
        # FORWARD PASS
        pre_activations = [slopes[j] * x + biases[j] for j in range(N_HIDDEN)]
        activations = [z if z > 0 else 0.0 for z in pre_activations]  # ReLU
        prediction = output_bias + sum(
            output_weights[j] * activations[j] for j in range(N_HIDDEN)
        )

        # LOSS — this sample's contribution to sum-squared error.
        error = prediction - target
        sum_sq_error += error * error

        # BACKWARD PASS — chain rule from loss back to each parameter.
        # dLoss/d(prediction) = error
        grad_output_bias += error
        for j in range(N_HIDDEN):
            grad_output_weights[j] += error * activations[j]
            if activations[j] > 0:  # ReLU gate: gradient passes only when the unit was active
                grad_slopes[j] += error * output_weights[j] * x
                grad_biases[j] += error * output_weights[j]

    # WEIGHT UPDATE — SGD step on the batch gradient.
    # The 2/N scale converts d(SSE)/dθ into d(MSE)/dθ.
    grad_scale = 2.0 / N_SAMPLES
    output_bias -= LEARNING_RATE * grad_scale * grad_output_bias
    for j in range(N_HIDDEN):
        slopes[j] -= LEARNING_RATE * grad_scale * grad_slopes[j]
        biases[j] -= LEARNING_RATE * grad_scale * grad_biases[j]
        output_weights[j] -= LEARNING_RATE * grad_scale * grad_output_weights[j]

    if epoch % 500 == 0 or epoch == N_EPOCHS - 1:
        rms = math.sqrt(sum_sq_error / N_SAMPLES)
        print(f"  epoch {epoch:4d}   rms={rms:.3e}")


# ── Final evaluation ─────────────────────────────────────────────────
# Compute residuals against the truth and report final RMS.  After
# 1000 epochs the net fits sin to roughly 1.5e-2 RMS — a 50× reduction
# from the initial state.  More epochs continue to refine the fit.

residuals = []
for x, target in zip(inputs, targets):
    prediction = output_bias + sum(
        output_weights[j] * max(0.0, slopes[j] * x + biases[j])
        for j in range(N_HIDDEN)
    )
    residuals.append(target - prediction)

final_rms = math.sqrt(sum(r * r for r in residuals) / len(residuals))
print(f"\nfinal rms={final_rms:.3e}")
