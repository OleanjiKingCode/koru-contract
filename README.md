# Koru Escrow Contract

A secure escrow contract for the Koru platform, enabling trustless payments for chat sessions on Base.

## Overview

KoruEscrow handles USDC deposits for paid chat sessions with the following flow:

1. **Depositor** creates an escrow, locking USDC for a specific recipient
2. **Recipient** has 24 hours to accept (by replying to the chat)
3. After acceptance, **Depositor** has 48 hours to release or dispute
4. **Recipient** can withdraw after release or after the 48-hour window

### State Diagram

```
PENDING ──────────────────────────────────────────────────────┐
   │                                                          │
   │ (recipient accepts within 24hrs)        (24hrs pass, no accept)
   ▼                                                          │
ACCEPTED ───────────────────────────┐                         │
   │              │                 │                         │
   │              │                 │                         │
(depositor    (48hrs pass)    (depositor                      │
 releases)                     disputes)                      │
   │              │                 │                         │
   ▼              │                 ▼                         │
RELEASED          │            DISPUTED                       │
   │              │                 │                         │
   │              │            (admin resolves)               │
   │              │                 │                         │
   └──────────────┴─────────────────┴─────────────────────────┘
                           │
                           ▼
                      COMPLETED / EXPIRED
```

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Node.js 18+ (for tooling)

### Installation

```bash
# Clone and enter directory
cd koru-contracts

# Install dependencies
make install

# Build
make build

# Run tests
make test
```

### Configuration

Copy the environment file and fill in your values:

```bash
cp env.example .env
```

Required variables:
- `DEPLOYER_PRIVATE_KEY` - Private key for deployment
- `FEE_RECIPIENT` - Address to receive platform fees
- `BASE_SEPOLIA_RPC_URL` - RPC URL for Base Sepolia
- `BASE_RPC_URL` - RPC URL for Base Mainnet
- `BASESCAN_API_KEY` - API key for contract verification

## Usage

### Run Tests

```bash
# All tests
make test

# With gas report
make test-gas

# Fuzz tests
make fuzz

# Invariant tests
make invariant

# Coverage report
make coverage
```

### Deploy

```bash
# Local (Anvil)
make anvil          # Terminal 1
make deploy-local   # Terminal 2

# Base Sepolia
make deploy-sepolia

# Base Mainnet
make deploy-base
```

### Contract Interactions

```bash
# Get escrow info
ESCROW_ADDRESS=0x... ESCROW_ID=0 make info

# Pause contract (emergency)
ESCROW_ADDRESS=0x... make pause

# Resolve dispute
ESCROW_ADDRESS=0x... ESCROW_ID=0 WINNER=0x... make resolve-dispute
```

## Contract Architecture

### Files

```
src/
├── KoruEscrow.sol          # Main contract
├── interfaces/
│   └── IKoruEscrow.sol     # Interface with events & types
└── libraries/
    └── Errors.sol          # Custom errors
```

### Key Functions

| Function | Caller | Description |
|----------|--------|-------------|
| `createEscrow()` | Depositor | Lock USDC for a recipient |
| `accept()` | Recipient | Accept the escrow (first chat reply) |
| `release()` | Depositor | Release funds immediately |
| `dispute()` | Depositor | Raise a dispute |
| `withdraw()` | Either | Withdraw available funds |
| `resolveDispute()` | Admin | Resolve disputed escrow |

### Events (for Subgraph)

- `EscrowCreated` - New escrow created
- `EscrowAccepted` - Recipient accepted
- `EscrowReleased` - Depositor released funds
- `EscrowWithdrawn` - Funds withdrawn
- `EscrowDisputed` - Dispute raised
- `DisputeResolved` - Dispute resolved
- `BalanceChanged` - User balance changed (for tracking stats)

## Security

### Features

- **Reentrancy Protection** - Custom reentrancy guard
- **Access Control** - Role-based modifiers
- **Pausable** - Emergency pause functionality
- **Safe Transfers** - Uses OpenZeppelin SafeERC20
- **Custom Errors** - Gas-efficient error handling

### Audits

⚠️ This contract has not been audited. Use at your own risk.

## Gas Optimization

- Custom errors instead of require strings (~50 gas saved per revert)
- Tight variable packing in structs
- View functions for state checks
- Minimal storage writes

## License

MIT
