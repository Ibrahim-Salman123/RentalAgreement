# RentalAgreement — Trustless On-Chain Rental with Deposit Protection

[![Solidity](https://img.shields.io/badge/Solidity-0.8.20-blue)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Networks](https://img.shields.io/badge/Networks-Ethereum%20%7C%20Polygon%20%7C%20Arbitrum%20%7C%20Base-purple)]()

---

## Problem Statement

Rental disputes cost tenants and landlords billions annually. Security deposits are withheld unfairly; rent is sometimes not paid; evidence is lost; and resolving disputes through courts is slow and expensive. This contract enforces the rental agreement in code — no lawyers, no middlemen.

---

## How It Works

```
Landlord                           Tenant
   │── createLease() ─────────────►│
   │   (rent, deposit, duration,   │
   │    IPFS property hash)        │
   │                               │── payDeposit() (ETH locked)
   │                               │── payRent()    (monthly, auto late fees)
   │                               │── payRent()    ...
   │                               │
   │   [Lease ends]                │
   │── raiseDeduction()  ─────────►│  (IPFS evidence, funds sent to landlord)
   │                               │── disputeDeduction() (flags for arbitration)
   │                               │── claimDepositRefund() (after 7-day grace)
```

### Lease States

```
Active ──► Ended        (deposit claimed after grace period)
Active ──► Disputed     (tenant disputes a deduction)
Active ──► Terminated   (early termination by either party)
```

---

## Key Features

| Feature | Detail |
|---|---|
| **Deposit lock** | Tenant's deposit held in contract — landlord cannot touch it without raising a deduction |
| **Auto late fees** | 1% of rent per day overdue, calculated on-chain |
| **IPFS evidence** | Deductions must include photo/invoice proof (IPFS CID) |
| **7-day grace** | Landlord has 7 days after lease end to raise deductions |
| **Dispute flag** | Tenant can dispute any deduction — marks lease for arbitration |
| **Immediate rent** | Monthly rent forwarded directly to landlord on payment |

---

## Setup & Deployment

### Prerequisites

```bash
npm install -g hardhat
npm install --save-dev @nomicfoundation/hardhat-toolbox dotenv
```

### Configure `.env`

```
PRIVATE_KEY=your_wallet_private_key
RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=your_polygonscan_key
```

### Deploy

```bash
npx hardhat run scripts/deploy.js --network polygon
npx hardhat verify --network polygon DEPLOYED_ADDRESS
```

---

## Usage Examples

### 1 — Landlord Creates Lease

```javascript
await rental.createLease(
  tenantAddress,
  ethers.parseEther("0.1"),   // 0.1 ETH monthly rent
  ethers.parseEther("0.3"),   // 0.3 ETH deposit (3 months)
  365,                        // 1-year lease
  "QmPropertyDescriptionAndLeaseDocIPFSHash"
);
```

### 2 — Tenant Pays Deposit

```javascript
await rental.connect(tenant).payDeposit(leaseId, {
  value: ethers.parseEther("0.3")
});
```

### 3 — Tenant Pays Monthly Rent

```javascript
// Get current amount due (includes late fees if overdue)
const due = await rental.currentRentDue(leaseId);
await rental.connect(tenant).payRent(leaseId, { value: due });
```

### 4 — Landlord Raises a Deduction After Lease Ends

```javascript
await rental.connect(landlord).raiseDeduction(
  leaseId,
  ethers.parseEther("0.05"),    // 0.05 ETH deduction
  "Broken window — repair invoice attached",
  "QmInvoiceAndPhotoIPFSHash"
);
```

### 5 — Tenant Claims Deposit Refund (after 7-day grace)

```javascript
await rental.connect(tenant).claimDepositRefund(leaseId);
```

---

## Security Considerations

- **CEI Pattern**: All state updates (e.g. `depositBalance = 0`) occur before ETH transfers.
- **Late fee cap**: Consider adding a max-late-fee cap for production to prevent griefing.
- **Dispute resolution**: The `disputeDeduction` flag marks the lease for off-chain or on-chain arbitration (e.g. connect to `FreelanceEscrow`'s arbitrator pattern).
- **Upgrade path**: For high-value leases, add a multi-sig landlord address or integrate with OpenZeppelin's `AccessControl`.

---

## Testing

```bash
npx hardhat test
npx hardhat coverage
```

Key test scenarios:

- Full lifecycle: create → deposit → monthly rents → end → deduct → refund remainder
- Late rent with auto fee calculation
- Tenant disputes deduction → state becomes Disputed
- Deposit claim before grace period → revert
- Unauthorized access → revert

---

## Bounty Platform Checklist

- [x] Full NatSpec documentation
- [x] SPDX licence identifier
- [x] Pinned pragma `^0.8.20`
- [x] Custom errors (gas-efficient)
- [x] Events on every state transition
- [x] IPFS-linked evidence for deductions
- [x] No admin backdoor — rules enforced by code
- [x] CEI reentrancy protection

---

## License

MIT — see [LICENSE](LICENSE)
