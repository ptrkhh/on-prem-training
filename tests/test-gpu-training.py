#!/usr/bin/env python3
"""
Test GPU training with PyTorch
Verifies CUDA is available and GPU can run a simple training loop
"""

import torch
import torch.nn as nn
import torch.optim as optim
import time

print("=" * 60)
print("GPU Training Test")
print("=" * 60)
print()

# Check CUDA availability
print("PyTorch version:", torch.__version__)
print("CUDA available:", torch.cuda.is_available())

if not torch.cuda.is_available():
    print("ERROR: CUDA is not available!")
    exit(1)

print("CUDA version:", torch.version.cuda)
print("GPU count:", torch.cuda.device_count())
print("Current GPU:", torch.cuda.current_device())
print("GPU name:", torch.cuda.get_device_name(0))
print()

# Get GPU properties
gpu_props = torch.cuda.get_device_properties(0)
print("GPU Properties:")
print(f"  Total memory: {gpu_props.total_memory / 1e9:.2f} GB")
print(f"  Compute capability: {gpu_props.major}.{gpu_props.minor}")
print()

# Simple neural network
class SimpleNet(nn.Module):
    def __init__(self):
        super(SimpleNet, self).__init__()
        self.fc1 = nn.Linear(1024, 512)
        self.fc2 = nn.Linear(512, 256)
        self.fc3 = nn.Linear(256, 10)
        self.relu = nn.ReLU()

    def forward(self, x):
        x = self.relu(self.fc1(x))
        x = self.relu(self.fc2(x))
        x = self.fc3(x)
        return x

# Create model and move to GPU
print("Creating model...")
model = SimpleNet().cuda()
criterion = nn.CrossEntropyLoss()
optimizer = optim.Adam(model.parameters(), lr=0.001)

# Generate random training data
batch_size = 128
num_batches = 100

print(f"Training for {num_batches} batches...")
print()

start_time = time.time()

for batch_idx in range(num_batches):
    # Generate random input and target
    inputs = torch.randn(batch_size, 1024).cuda()
    targets = torch.randint(0, 10, (batch_size,)).cuda()

    # Forward pass
    optimizer.zero_grad()
    outputs = model(inputs)
    loss = criterion(outputs, targets)

    # Backward pass
    loss.backward()
    optimizer.step()

    if (batch_idx + 1) % 10 == 0:
        print(f"Batch {batch_idx + 1}/{num_batches}, Loss: {loss.item():.4f}")

end_time = time.time()
elapsed = end_time - start_time

print()
print(f"Training completed in {elapsed:.2f} seconds")
print(f"Throughput: {num_batches / elapsed:.2f} batches/sec")
print()

# Check GPU memory usage
print("GPU Memory:")
print(f"  Allocated: {torch.cuda.memory_allocated(0) / 1e9:.2f} GB")
print(f"  Reserved: {torch.cuda.memory_reserved(0) / 1e9:.2f} GB")
print()

print("=" * 60)
print("GPU Test PASSED ✓")
print("=" * 60)
