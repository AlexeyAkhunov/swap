package swap

import (
    "context"
    "math/big"
    "testing"
    "github.com/ethereum/go-ethereum/accounts/abi/bind"
    "github.com/ethereum/go-ethereum/accounts/abi/bind/backends"
    "github.com/ethereum/go-ethereum/core"
    "github.com/ethereum/go-ethereum/core/types"
    "github.com/ethereum/go-ethereum/crypto"
)

var (
    one_Ether = big.NewInt(0).Exp(big.NewInt(10), big.NewInt(18), nil)

    // Generate a new random account and a funded simulator
    deployer_key, _ = crypto.GenerateKey()
    deployer = bind.NewKeyedTransactor(deployer_key)

    alice_key, _ = crypto.GenerateKey()
    alice = bind.NewKeyedTransactor(alice_key)
    )

func newTestBackend() *backends.SimulatedBackend {
    return backends.NewSimulatedBackend(core.GenesisAlloc{
        deployer.From: {Balance: big.NewInt(10000000000)},
        alice.From: {Balance: big.NewInt(0).Mul(one_Ether, big.NewInt(100))}, // Alice has 100 ETH
        })
}

func mustDeploy(t *testing.T) (*backends.SimulatedBackend, *ChannelBook) {
    b := newTestBackend()
    _, _, cb, err := DeployChannelBook(deployer, b)
    if err != nil {
        t.Errorf("Could not deploy ChannelBook contract")
    }
    b.Commit()
    return b, cb    
}

func commitAndGetReceipt(t *testing.T, b *backends.SimulatedBackend, tx *types.Transaction, err error) (*types.Receipt) {
    if err != nil {
        t.Errorf("Error calling bindings", err)
    }
    b.Commit()
    ctx := context.Background()
    r, err := b.TransactionReceipt(ctx, tx.Hash())
    if err != nil || r == nil {
        t.Errorf("Could not get tx receipt for %v", tx.Hash())
    }
    return r
}

func TestRegisterAlice(t *testing.T) {
    b, cb := mustDeploy(t)
    tx, err := cb.Register_as_member(&bind.TransactOpts{From: alice.From, Signer: alice.Signer, Value: one_Ether})
    r := commitAndGetReceipt(t, b, tx, err)
    if r.Status != types.ReceiptStatusSuccessful {
        t.Errorf("Alice could not register as member, tx failed")
    }
}

func TestInsufficientRegistrationDeposit(t *testing.T) {
    b, cb := mustDeploy(t)
    tx, err := cb.Register_as_member(&bind.TransactOpts{From: alice.From, Signer: alice.Signer, Value: big.NewInt(0).Sub(one_Ether, big.NewInt(1000))})
    r := commitAndGetReceipt(t, b, tx, err)
    if r.Status == types.ReceiptStatusSuccessful {
        t.Errorf("Should have failed due to insufficient registration deposit")
    }
}

func TestLargerRegistrationDeposit(t *testing.T) {
    b, cb := mustDeploy(t)
    tx, err := cb.Register_as_member(&bind.TransactOpts{From: alice.From, Signer: alice.Signer, Value: big.NewInt(0).Add(one_Ether, big.NewInt(1000))})
    r := commitAndGetReceipt(t, b, tx, err)
    if r.Status != types.ReceiptStatusSuccessful {
        t.Errorf("Alice could not register as member, tx failed")
    }
    d, err := cb.Deposits_returned(&bind.CallOpts{}, alice.From)
    if err != nil {
        t.Errorf("Could not read returned deposits for Alice", err)
    }
    if d.Cmp(big.NewInt(1000)) != 0 {
        t.Errorf("Incorrect returned deposits. Wanted: %d, got: %d", big.NewInt(1000), d)
    }
}
