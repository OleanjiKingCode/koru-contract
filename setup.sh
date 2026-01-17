#!/bin/bash

# Koru Contracts Setup Script
# Run this after cloning to install all dependencies

set -e

echo "🔧 Setting up Koru Contracts..."

# Check if forge is installed
if ! command -v forge &> /dev/null; then
    echo "❌ Foundry not found. Please install it first:"
    echo "   curl -L https://foundry.paradigm.xyz | bash"
    echo "   foundryup"
    exit 1
fi

echo "✅ Foundry found: $(forge --version)"

# Install dependencies
echo ""
echo "📦 Installing dependencies..."

# Initialize git if not already
if [ ! -d ".git" ]; then
    git init
fi

# Install forge-std
echo "   Installing forge-std..."
forge install foundry-rs/forge-std --no-commit

# Install OpenZeppelin
echo "   Installing OpenZeppelin contracts..."
forge install OpenZeppelin/openzeppelin-contracts --no-commit

# Build
echo ""
echo "🔨 Building contracts..."
forge build

# Run tests
echo ""
echo "🧪 Running tests..."
forge test

echo ""
echo "✅ Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Copy env.example to .env and fill in your values"
echo "  2. Run 'make help' to see available commands"
echo "  3. Run 'make test' to run the test suite"
