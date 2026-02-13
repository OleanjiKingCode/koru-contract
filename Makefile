# Include .env file if it exists
-include .env

# ============ Variables ============
ESCROW_ADDRESS ?= 0x0000000000000000000000000000000000000000

# ============ Help ============
.PHONY: help
help:
	@echo "Koru Escrow Contract - Available Commands"
	@echo ""
	@echo "Build & Test:"
	@echo "  make build          - Compile contracts"
	@echo "  make clean          - Clean build artifacts"
	@echo "  make test           - Run all tests"
	@echo "  make test-v         - Run tests with verbosity"
	@echo "  make test-gas       - Run tests with gas report"
	@echo "  make coverage       - Generate test coverage report"
	@echo "  make fuzz           - Run fuzz tests"
	@echo "  make invariant      - Run invariant tests"
	@echo ""
	@echo "Code Quality:"
	@echo "  make format         - Format code"
	@echo "  make lint           - Check formatting"
	@echo "  make snapshot       - Generate gas snapshot"
	@echo "  make slither        - Run Slither security analysis"
	@echo ""
	@echo "Deployment:"
	@echo "  make deploy-local   - Deploy to local Anvil node"
	@echo "  make deploy-sepolia - Deploy to Base Sepolia"
	@echo "  make deploy-base    - Deploy to Base Mainnet"
	@echo ""
	@echo "Local Development:"
	@echo "  make anvil          - Start local Anvil node"
	@echo "  make anvil-fork     - Start Anvil forking Base"
	@echo ""
	@echo "Contract Interactions:"
	@echo "  make info              - Get escrow info"
	@echo "  make pause             - Pause contract"
	@echo "  make unpause           - Unpause contract"
	@echo "  make check-initialized - Check if contract is initialized"
	@echo "  make initialize-sepolia ESCROW_ADDRESS=0x... FEE_RECIPIENT=0x... - Initialize proxy"

# ============ Build ============
.PHONY: build
build:
	forge build

.PHONY: clean
clean:
	forge clean

.PHONY: rebuild
rebuild: clean build

# ============ Test ============
.PHONY: test
test:
	forge test

.PHONY: test-v
test-v:
	forge test -vvv

.PHONY: test-vv
test-vv:
	forge test -vvvv

.PHONY: test-gas
test-gas:
	forge test --gas-report

.PHONY: coverage
coverage:
	forge coverage --report lcov
	@echo "Coverage report generated at lcov.info"
	@echo "View with: genhtml lcov.info -o coverage && open coverage/index.html"

.PHONY: fuzz
fuzz:
	forge test --match-contract Fuzz -vvv

.PHONY: invariant
invariant:
	forge test --match-contract Invariant -vvv

.PHONY: test-ci
test-ci:
	FOUNDRY_PROFILE=ci forge test

# ============ Code Quality ============
.PHONY: format
format:
	forge fmt

.PHONY: lint
lint:
	forge fmt --check

.PHONY: snapshot
snapshot:
	forge snapshot

.PHONY: slither
slither:
	slither . --config-file slither.config.json || true

# ============ Local Development ============
.PHONY: anvil
anvil:
	anvil

.PHONY: anvil-fork
anvil-fork:
	anvil --fork-url $(BASE_RPC_URL) --fork-block-number 20000000

# ============ Deployment ============
.PHONY: deploy-local
deploy-local:
	forge script script/Deploy.s.sol:DeployKoruEscrowLocal \
		--rpc-url http://localhost:8545 \
		--broadcast \
		-vvvv

.PHONY: deploy-sepolia
deploy-sepolia:
	@echo "Deploying to Base Sepolia..."
	forge script script/Deploy.s.sol:DeployKoruEscrow \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--verify \
		-vvvv

.PHONY: deploy-base
deploy-base:
	@echo "Deploying to Base Mainnet..."
	@echo "WARNING: This is a mainnet deployment!"
	@read -p "Are you sure? (y/N) " confirm && [ "$$confirm" = "y" ] || exit 1
	forge script script/Deploy.s.sol:DeployKoruEscrow \
		--rpc-url $(BASE_RPC_URL) \
		--broadcast \
		--verify \
		-vvvv

.PHONY: deploy-escrow-sepolia
deploy-escrow-sepolia:
	@echo "Deploying KoruEscrow to Base Sepolia..."
	@echo "Make sure FEE_RECIPIENT is set in .env"
	forge script script/Deploy.s.sol:DeployKoruEscrowWithAccount --rpc-url $(BASE_SEPOLIA_RPC_URL) --account KoruDeployerII --broadcast -vvvv

.PHONY: upgrade-escrow-sepolia
upgrade-escrow-sepolia:
	@echo "Upgrading KoruEscrow on Base Sepolia..."
	@echo "Proxy: $(ESCROW_ADDRESS)"
	forge script script/Upgrade.s.sol:UpgradeKoruEscrow --rpc-url $(BASE_SEPOLIA_RPC_URL) --account KoruDeployerII --broadcast -vvvv

.PHONY: deploy-base-testnet
deploy-base-testnet:
	@echo "Deploying KoruEscrow to Base Testnet (Sepolia)..."
	@echo "Make sure FEE_RECIPIENT is set in .env"
	forge script script/Deploy.s.sol:DeployKoruEscrowWithAccount --rpc-url $(BASE_SEPOLIA_RPC_URL) --account KoruDeployerII --broadcast -vvvv

# ============ Verification ============
.PHONY: verify
verify:
	forge verify-contract $(ESCROW_ADDRESS) src/KoruEscrow.sol:KoruEscrow \
		--chain-id 8453 \
		--etherscan-api-key $(BASESCAN_API_KEY)

.PHONY: verify-sepolia
verify-sepolia:
	forge verify-contract $(ESCROW_ADDRESS) src/KoruEscrow.sol:KoruEscrow \
		--chain-id 84532 \
		--etherscan-api-key $(BASESCAN_API_KEY)

# ============ Contract Interactions ============
.PHONY: info
info:
	@echo "Getting escrow info..."
	forge script script/Interactions.s.sol:GetEscrowInfo \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--sig "run(address,uint256)" $(ESCROW_ADDRESS) $(ESCROW_ID)

.PHONY: pause
pause:
	forge script script/Interactions.s.sol:PauseContract \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--sig "run(address)" $(ESCROW_ADDRESS)

.PHONY: unpause
unpause:
	forge script script/Interactions.s.sol:UnpauseContract \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--sig "run(address)" $(ESCROW_ADDRESS)

.PHONY: set-fee
set-fee:
	forge script script/Interactions.s.sol:SetFee \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--sig "run(address,uint256)" $(ESCROW_ADDRESS) $(NEW_FEE_BPS)

.PHONY: resolve-dispute
resolve-dispute:
	forge script script/Interactions.s.sol:ResolveDispute \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--sig "run(address,uint256,address)" $(ESCROW_ADDRESS) $(ESCROW_ID) $(WINNER)

# Base Sepolia USDC address
USDC_BASE_SEPOLIA ?= 0x036CbD53842c5426634e7929541eC2318f3dCF7e
# Default fee: 2.5% (250 basis points)
INIT_FEE_BPS ?= 250

.PHONY: initialize-sepolia
initialize-sepolia:
	@echo "Initializing KoruEscrow proxy on Base Sepolia..."
	@echo "Contract: $(ESCROW_ADDRESS)"
	@echo "USDC: $(USDC_BASE_SEPOLIA)"
	@echo "Fee BPS: $(INIT_FEE_BPS)"
	@echo "Fee Recipient: $(FEE_RECIPIENT)"
	cast send $(ESCROW_ADDRESS) \
		"initialize(address,uint256,address)" \
		$(USDC_BASE_SEPOLIA) \
		$(INIT_FEE_BPS) \
		$(FEE_RECIPIENT) \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--account KoruDeployerII

.PHONY: check-initialized
check-initialized:
	@echo "Checking if contract is initialized..."
	@echo "Owner:" && cast call $(ESCROW_ADDRESS) "owner()(address)" --rpc-url $(BASE_SEPOLIA_RPC_URL)
	@echo "Fee BPS:" && cast call $(ESCROW_ADDRESS) "feeBps()(uint96)" --rpc-url $(BASE_SEPOLIA_RPC_URL)
	@echo "Fee Recipient:" && cast call $(ESCROW_ADDRESS) "feeRecipient()(address)" --rpc-url $(BASE_SEPOLIA_RPC_URL)
	@echo "Paused:" && cast call $(ESCROW_ADDRESS) "paused()(bool)" --rpc-url $(BASE_SEPOLIA_RPC_URL)

# ============ Utilities ============
.PHONY: abi
abi:
	forge inspect KoruEscrow abi > out/KoruEscrow.abi.json
	@echo "ABI exported to out/KoruEscrow.abi.json"

.PHONY: storage
storage:
	forge inspect KoruEscrow storage-layout --pretty

.PHONY: size
size:
	forge build --sizes

# ============ Install Dependencies ============
.PHONY: install
install:
	forge install OpenZeppelin/openzeppelin-contracts --no-commit
	forge install foundry-rs/forge-std --no-commit

.PHONY: update
update:
	forge update
