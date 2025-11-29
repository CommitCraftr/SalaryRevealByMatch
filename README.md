# SalaryRevealByMatch — Private Salary Reveal by Matching Role & Region (Zama FHEVM)

> **SalaryRevealByMatch** is a Zama FHEVM‑powered protocol that lets people **publish their salary fully encrypted**, then selectively reveal it **only to peers with the same role and region**. Both inputs and comparisons happen under FHE — the chain never sees plaintext salaries or attributes.

---

## ✨ TL;DR

* 💰 **Publish salary posts privately**: a user encrypts their salary, role ID and region ID and stores them on‑chain as FHE ciphertexts.
* 🧩 **Reveal only on attribute match**: another user submits their encrypted `(roleId, regionId)`; if it matches the post, they get a decryptable handle to the salary.
* 🕵️ **No plaintext branching**: role/region checks and conditional reveal are implemented entirely with homomorphic operations (`FHE.eq`, `FHE.and`, `FHE.select`).
* 🔑 **Fine‑grained access control**: the post owner can grant extra read access or make the salary publicly decryptable.
* 🧱 **Composable primitive**: can be embedded into salary surveys, HR tools, DAO salary transparency experiments, or privacy‑preserving benchmarking platforms.

---

## 📚 Project Overview

### Problem

Talking about salaries is hard:

* people want **fair benchmarks**, but don’t want to doxx themselves;
* public salary disclosures can leak sensitive career or negotiation information;
* centralized platforms require trust in an operator who sees raw data.

We’d like a pattern where:

* **everyone keeps their salary encrypted** on‑chain;
* you only learn someone’s salary when you **truly share the same context** (role & region);
* comparisons and access control are enforced by the **smart contract itself**, under FHE.

### Solution: SalaryRevealByMatch

**SalaryRevealByMatch** is an on‑chain primitive for **context‑gated salary reveal**:

1. A user creates a **salary post** with:

   * encrypted salary (`euint32`), e.g. in minor units (cents / smallest token units);
   * encrypted `roleId` (`euint16`), e.g. numeric code for role or level;
   * encrypted `regionId` (`euint16`), e.g. numeric code for geo / market.
2. Another user sends their own encrypted `(roleId, regionId)`.
3. The contract checks **equality under encryption** and returns an encrypted value:

   * if both role & region match → encrypted salary;
   * otherwise → encrypted `0`.
4. Using the Zama Relayer SDK, the requester can decrypt this value **only if they were granted access** to the resulting ciphertext.

The protocol never stores or processes salaries, roles, or regions in plaintext.

---

## 🧮 Protocol & Data Model

### Storage

```solidity
struct Post {
    address owner;        // post owner
    euint32 salary;       // encrypted salary (e.g., in minor units)
    euint16 roleId;       // encrypted role code
    euint16 regionId;     // encrypted region code
    uint64  createdAt;    // timestamp (for UX)
    bool    set;
}

uint256 public nextPostId;
mapping(uint256 => Post) private posts;
```

For each post `id` we store:

* `owner` — the EOA or contract that owns the post;
* `salary` — encrypted `uint32` salary value;
* `roleId` — encrypted `uint16` role code;
* `regionId` — encrypted `uint16` region code;
* `createdAt` — timestamp of publication in seconds;
* `set` — flag to ensure the post exists.

### Salary range & clamping

Salaries are imported from off‑chain via `externalEuint32 encSalary` and an FHE attestation:

```solidity
euint32 salary  = FHE.fromExternal(encSalary, attestation);

// Optional clamp: [0, maxCap]
euint32 maxCap = FHE.asEuint32(100_000_000);
salary = FHE.min(FHE.max(salary, FHE.asEuint32(0)), maxCap);
```

This ensures all salaries lie in a bounded numeric domain without revealing exact values.

### Matching logic: role & region

When a requester wants to see a salary, they submit:

```solidity
function revealIfMatch(
    uint256 id,
    externalEuint16 requesterRole,
    externalEuint16 requesterRegion,
    bytes calldata attestation
) external returns (bytes32 handle)
```

1. Import requester inputs from the FHE gateway:

   ```solidity
   euint16 rRole   = FHE.fromExternal(requesterRole, attestation);
   euint16 rRegion = FHE.fromExternal(requesterRegion, attestation);
   ```

2. Compute equality under encryption:

   ```solidity
   ebool roleEq   = FHE.eq(rRole, P.roleId);
   ebool regionEq = FHE.eq(rRegion, P.regionId);
   ebool ok = FHE.and(roleEq, regionEq);
   ```

3. Conditionally select the value to reveal:

   ```solidity
   euint32 reveal = FHE.select(ok, P.salary, FHE.asEuint32(0));
   ```

* If `(roleId, regionId)` match: `reveal` encrypts the true salary.
* If not: `reveal` encrypts `0`.

4. Assign access to the resulting ciphertext:

   ```solidity
   FHE.allow(reveal, msg.sender);  // requester
   FHE.allowThis(reveal);          // contract
   FHE.allow(reveal, P.owner);     // post owner
   ```

5. Return an opaque handle:

   ```solidity
   handle = FHE.toBytes32(reveal);
   ```

This `handle` can then be decrypted off‑chain via Zama’s Relayer SDK.

> **Note:** since `0` is a valid numeric value, the protocol itself does not distinguish between "no match" and "salary is exactly 0". In practice, frontends can treat `0` as "no reveal" for realistic salary scales.

---

## 🔐 Access Control & Privacy Model

### Who can see what?

**The blockchain and the contract DO NOT know:**

* actual salary numbers;
* actual role/region codes in plaintext;
* which requests resulted in a real match.

**The contract and the chain DO know:**

* that a post exists and who owns it (`owner`);
* when it was created (`createdAt`);
* that a `revealIfMatch` call happened (via `SalaryRevealed` event) and which handle was produced;
* that certain addresses received ACLs to specific ciphertexts.

All sensitive values are stored only as encrypted integers (`euint16`, `euint32`) or opaque handles (`bytes32`).

### Owner utilities

The post owner can manage access:

* `grantPostAccess(id, to)` — gives `to` read access to salary, role, and region ciphertexts.
* `makeSalaryPublic(id)` — makes the salary ciphertext **publicly decryptable** for anyone (via `FHE.makePubliclyDecryptable`).

Opaque getter helpers:

* `salaryHandle(id)` — handle for the stored salary.
* `roleHandle(id)` — handle for encrypted role.
* `regionHandle(id)` — handle for encrypted region.

These are useful for audits, off‑chain analytics, or advanced UX flows.

---

## 🖥️ Frontend & UX (suggested flows)

A typical dApp UI for this contract can reuse the same layout as the liquidity scoring demo, with adapted sections:

### 1. Publish Salary Post

Fields:

* **Salary** — numeric input; frontend converts to minor units and sends as `externalEuint32`.
* **Role** — dropdown or input mapped to a numeric `roleId` (e.g., `1 = Backend Engineer L3`).
* **Region** — dropdown mapped to numeric `regionId` (e.g., `1 = US, 2 = EU`, etc.).

Flow:

1. User connects wallet.
2. Frontend calls Relayer SDK:

   * `createEncryptedInput(contractAddress, userAddress)`;
   * adds `salary`, `roleId`, `regionId` as encrypted inputs (`add32`/`add16`, depending on SDK support);
   * obtains `handles` and `inputProof`.
3. Calls `publish(encSalary, encRoleId, encRegionId, attestation)`.
4. Displays new `postId` and link for sharing.

### 2. Reveal Salary If Match

Fields:

* **Post ID** — numeric ID of the salary post.
* **Your role** — same encoding scheme as the publisher.
* **Your region** — same encoding scheme.

Flow:

1. Frontend encrypts `requesterRole` and `requesterRegion` via Relayer SDK.
2. Calls `revealIfMatch(postId, encRole, encRegion, attestation)`.
3. Receives `revealHandle` (`bytes32`).
4. Uses Relayer SDK to decrypt it, depending on access mode:

   * `publicDecrypt([handle])` if the salary was made public;
   * `userDecrypt(...)` with EIP‑712 if the requester has private access.
5. If decrypted value is non‑zero, display it as the salary in chosen units.

### 3. Owner Tools

For each `postId`:

* **Grant access**:

  * input: `to` address;
  * call: `grantPostAccess(id, to)`.
* **Make salary public**:

  * call: `makeSalaryPublic(id)`;
  * any user can then decrypt via `publicDecrypt`.

### 4. Diagnostics / Dev Tools

For development and debugging, a Logs panel (as in the scoring UI) can:

* print all Relayer SDK operations and transaction hashes;
* allow copying logs to clipboard;
* toggle verbose mode for EIP‑712 payloads and FHE handles.

---

## 🚶‍♀️ Step‑by‑Step Usage

### As a salary publisher

1. **Connect wallet** on the dApp.
2. Go to **Publish Salary** section.
3. Enter your salary, role, and region; the frontend encrypts them via Relayer SDK.
4. Confirm the `publish` transaction.
5. Save the returned `postId` and share it with people you want to compare with.

### As a requester (peer)

1. Open the dApp and connect wallet.
2. Go to **Reveal If Match** section.
3. Enter `postId`, your role, and your region using the same encoding scheme.
4. Frontend calls `revealIfMatch` and shows you a decrypted number if there is a match.

### As a post owner

1. Use **Owner Tools** to:

   * grant additional access via `grantPostAccess` (e.g., to auditors or HR);
   * later make your salary public via `makeSalaryPublic` if desired.

---

## 🏗️ Project Structure (suggested)

```text
.
├── contracts/
│   └── SalaryRevealByMatch.sol         # Core FHEVM contract
├── frontend/
│   └── index.html                      # Single‑page demo UI (wallet + Relayer SDK)
├── scripts/                            # (optional) deploy & setup helpers
│   └── deploy.ts / deploy.js
├── README.md                           # This file
└── package.json / foundry.toml / ...   # Tooling (Hardhat / Foundry / etc.)
```

### Contract: `SalaryRevealByMatch.sol`

Key points:

* Inherits `ZamaEthereumConfig` and uses the official Zama FHEVM library:

  ```solidity
  import { FHE, ebool, euint16, euint32, externalEuint16, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
  import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";
  ```

* All sensitive fields (`salary`, `roleId`, `regionId`) are FHE types (`euint32`, `euint16`).

* Matching and conditional logic use only FHE operations (`FHE.eq`, `FHE.and`, `FHE.select`).

* Access control uses `FHE.allow`, `FHE.allowThis`, `FHE.makePubliclyDecryptable`.

* Getters never reveal plaintext — they only return `bytes32` handles that must be decrypted off‑chain.

### Frontend: `index.html`

* Plain HTML + CSS layout with sections:

  * **Publish Salary Post**
  * **Reveal If Match**
  * **Owner Utilities**
  * **Logs / Debug**
* Uses `ethers@6` for wallet and contract interaction.
* Uses Zama Relayer SDK (`createInstance`, `createEncryptedInput`, `publicDecrypt`, `userDecrypt`) to:

  * encrypt salary/role/region on the client side;
  * decrypt gated salary values returned by `revealIfMatch`.

---

## 🚀 Possible Extensions

* **Multi‑attribute matching**: extend to additional dimensions (seniority, company size, stack).
* **Range queries**: encode buckets (e.g., `50k–60k`) and compute aggregated encrypted stats for groups.
* **DAO‑driven salary transparency**: integrate with governance to decide when and how to make salaries public.
* **Reputation & anti‑spam**: combine with FHE‑based proofs, soulbound tokens, or Sybil‑resistant identity for higher‑quality data.

---

## 📄 License

The contract is released under the MIT license:

```solidity
// SPDX-License-Identifier: MIT
```

You are free to use, modify, and integrate **SalaryRevealByMatch** in your own Zama FHEVM projects under MIT terms.
