# lendingHW

### Week 12
```shell
# create dev chain
anvil

# add .env
# ALCHEMY_RPC_URL=""
# LOCAL_RPC_URL="http://localhost:8545"
# PRIVATE_KEY=""

# deploy compound
forge script script/Compound.s.sol:CompoundScript --rpc-url http://localhost:8545 --broadcast --verify -vvvv
```