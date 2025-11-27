# Private Staking Pool

Privacy-preserving staking pool where each participant is accepted or rejected based on **encrypted stake limits**.
Stake amounts, limits, and accept/reject flags are **never revealed on-chain in cleartext** — all comparisons happen under FHE.

Built on **Zama FHEVM** with the **Relayer SDK** (`userDecrypt` / `publicDecrypt`) + a minimal browser frontend (no bundler).

---

## ✨ Key Features

* **Encrypted per-user limit check**
  Each pool has a hidden max stake limit. Stakers submit an **encrypted amount**, and the contract checks *“amount ≤ limit”* fully under FHE.

* **Private accept / reject decisions**
  The contract stores only encrypted decisions. The staker decrypts their own status via `userDecrypt` – nobody else sees it.

* **Optional public certificate**
  A staker can opt-in to a **public acceptance certificate** for a given pool. Anyone can then verify the encrypted accept flag via `publicDecrypt`.

* **No BigInt crashes in the browser**
  The frontend is hardened for `userDecrypt` / `publicDecrypt`:

  * Safe JSON logging for objects containing `BigInt`
  * Explicit normalization of decrypted values (`bigint | number | boolean | string`)

* **Straightforward UX**
  Single-page UI:

  * Admin: configure encrypted pool limit
  * Staker: submit encrypted stake & decrypt decision
  * Public: verify opt-in acceptance certificates

---

## 🧠 How the staking decision works

### Concepts

* `poolId` – ID of a staking pool (`uint256`).
* `limit` – per-staker stake limit for a pool (`uint16`, encrypted on-chain).
* `amount` – user’s encrypted stake amount (`uint16`).
* `accepted` – encrypted boolean flag (`ebool`): `true` if accepted into the pool.

### Flow

1. **Pool setup (admin / owner)**

   * Admin chooses a pool ID (e.g. `1`).
   * Enters a clear limit value (e.g. `1000`).
   * Frontend:

     * Calls Relayer SDK → `createEncryptedInput(CONTRACT_ADDRESS, ownerAddress)`.
     * Adds the limit as `add16(limit)`.
     * Sends `handles[0]` + `inputProof` into `createPool` or `updatePool`.
   * Contract:

     * Ingests encrypted limit as `euint16`.
     * Stores it in the `pools[poolId]` config.

2. **Staker submits encrypted stake**

   * Staker chooses a pool ID and a stake amount (e.g. `500`).
   * Frontend:

     * Encrypts stake with `createEncryptedInput(CONTRACT_ADDRESS, stakerAddress)`.
     * Calls `submitEncryptedStake(poolId, encAmount, proof)`.
   * Contract:

     * Reads encrypted amount `eAmount`.
     * Compares **inside FHEVM**:

       ```solidity
       ebool eAccepted = FHE.le(eAmount, eLimit);
       ```
     * Stores:

       * `eAmount` (encrypted amount)
       * `eAccepted` (encrypted decision)
       * `decided = true`
     * Grants ACL so that:

       * The contract can continue to operate on these ciphertexts.
       * The staker can decrypt them off-chain via `userDecrypt`.

3. **Staker decrypts result (private)**

   * Frontend calls:

     * `getMyStakeHandles(poolId)` → `{ amountHandle, acceptHandle, decided }`
     * Relayer SDK `userDecrypt` with those handles.
   * Relayer returns decrypted values (may be `bigint | number | boolean | string`):

     * `amount` – their clear stake amount
     * `accepted` – clear boolean-like value
   * Frontend normalizes:

     ```js
     const isAccepted = normalizeDecryptedValue(accepted) !== 0n;
     ```
   * UI shows:

     * “Last decrypted amount: X”
     * “Decision: accepted into the pool” or “rejected (above hidden limit)”

4. **Optional public certificate**

   * Staker who is accepted can call `enablePublicStakeCertificate(poolId)`.
   * Contract marks `eAccepted` as **publicly decryptable** for that staker & pool.
   * Anyone can:

     * Fetch handle via `getStakeAcceptedHandlePublic(address, poolId)`.
     * Call `publicDecrypt` on that handle using the Relayer SDK.
     * See if the staker is accepted or not – without learning any stake amount.

---

## 🖥️ UI Overview & Usage

The app is a single static HTML file (`index.html`) that you can serve over HTTPS.

### Header

* **Title** – “Private Staking Pool”
* **Network** – actual `chainId` your wallet is connected to (e.g. `0xaa36a7` for Sepolia)
* **You** – short version of your connected address
* **Contract** – short version of `0xd9780aF46cCE6e1d6803CF0ca40c27E332Fc526e`
* **Connect wallet** button:

  * Connects to MetaMask (or any EIP-1193 wallet)
  * Ensures Sepolia via `wallet_switchEthereumChain`

---

### 1. Pool Selector

Card: **“Pool selector”**

* **Active pool (input)**
  A `uint256` pool ID. The same ID is used for:

  * Admin pool config
  * Staking
  * Decrypting your result
  * Checking public certificates

* **Check on-chain** button
  Calls `getPoolMeta(poolId)` and shows:

  * `Pool #X: configured` or
  * `Pool #X: not configured`

**Usage:**

1. Enter `poolId` (e.g. `1`).
2. Click **“Check on-chain”**.
3. Move to admin/staking sections for that pool.

---

### 2. Admin · Configure pool limit

Card: **“Pool limit (admin)”**

Visible for any address, but only the contract owner can send transactions.

Fields:

* **Stake limit per staker (uint16 · encrypted)**

  * Clear integer value (0–65535).
  * This never goes on-chain; it is encrypted in the browser.

* **Encrypt & set limit** button

  * If the pool does not exist:

    * Calls `createPool(poolId, encLimit, proof)`
  * If it already exists:

    * Calls `updatePool(poolId, encLimit, proof)`

Owner detection:

* On connect, frontend fetches `owner()` and compares to `msg.sender`.
* Chip shows `Role: owner` or `Role: viewer`.

**Usage:**

1. Connect wallet as contract owner.
2. Select a pool ID in **Pool selector**.
3. Enter a limit (e.g. `1000`).
4. Click **“Encrypt & set limit”**.
5. Wait for tx confirmation – UI shows “Pool created…” or “Pool limit updated…”.

---

### 3. Staker · Submit encrypted stake

Card: **“Submit encrypted stake”**

Fields:

* **Stake amount (uint16 · encrypted)**

  * Value in arbitrary “units”, range `0–65535`.
  * Only used to encrypt; never exposed as cleartext on-chain.

* **Encrypt & submit** button

  * Encrypts the value via Relayer SDK.
  * Calls `submitEncryptedStake(poolId, encAmount, proof)`.

Status messages show pending tx and confirmation.

**Usage:**

1. Connect wallet as any user.
2. Select pool ID in **Pool selector**.
3. Enter stake amount (e.g. `500`).
4. Click **“Encrypt & submit”**.
5. Wait for confirmation.

---

### 4. Staker · Decrypt my result

Card: **“My encrypted position”**

Fields & actions:

* **Decrypt my stake (signed)** button

  * Calls `getMyStakeHandles(poolId)` → `{ amountHandle, acceptHandle, decided }`.
  * If `decided == false`, shows “No stake recorded…”.
  * Builds a `userDecrypt` request:

    * Generates ephemeral keypair.
    * Creates EIP712 payload using `relayer.createEIP712(...)`.
    * Signs with `signTypedData`.
  * Calls `relayer.userDecrypt(...)`.

* **Last decrypted amount**

  * Shows clear `amount` from `userDecrypt`.

* **Last decrypted decision**

  * Shows human-readable result:

    * “accepted into the pool”
    * “rejected (above hidden limit)”

* **Handles**

  * Shows raw encrypted handles for amount & decision (for debugging / inspection).

**Usage:**

1. Connect with the same wallet that submitted the stake.
2. Ensure the same `poolId` is selected.
3. Click **“Decrypt my stake (signed)”**.
4. Approve EIP-712 signature in your wallet.
5. Read your amount and decision – visible only to you.

---

### 5. Public participation proof (optional)

Card: **“Public participation proof (optional)”**

Two main flows:

#### a) Make my accept flag public

* **Make my accept flag public for active pool** button:

  * Calls `enablePublicStakeCertificate(poolId)`.
  * Contract:

    * Marks your `eAccepted` flag as publicly decryptable.
  * UI:

    * Status “Public certificate enabled ✓”
    * Header chip: `Certificate: public`

> This is irreversible from a privacy perspective for that decision.

#### b) Verify someone else’s certificate

Inputs:

* **Staker address**
* **Pool ID**
* **Check certificate** button:

  * Calls `getStakeAcceptedHandlePublic(staker, poolId)` → `{ acceptHandle, decided }`.
  * If `decided` is false or handle is zero-like, shows:

    * “No decision recorded or certificate not enabled.”
  * Otherwise:

    * Calls `publicDecrypt` via Relayer SDK.
    * Normalizes value with `normalizeDecryptedValue`.
    * Shows:

      * `Certificate: stake accepted (true)` or
      * `Certificate: stake rejected (false)`.
    * Displays raw handle as well.

---

## 🧱 Project Structure

This is a minimal, static project (no bundler, no framework):

```text
.
├─ index.html        # Single-page app (HTML + CSS + JS)
└─ README.md         # Project documentation (this file)
```

Everything (layout, logic, integration with Relayer + ethers) lives inside `index.html`.

---

## 🚀 Getting Started

### 1. Prerequisites

* Node.js (for running a simple HTTPS dev server)
* MetaMask or another EIP-1193 compatible wallet
* Funds on **Sepolia** testnet (if you want to actually send txs)

### 2. Clone the repo

```bash
git clone <your-repo-url>.git
cd <your-repo-name>
```

### 3. Serve `index.html` over HTTPS

`userDecrypt` / `publicDecrypt` work best (and are often required) over HTTPS.

Simplest dev option with `http-server`:

```bash
npm install -g http-server

# generate a self-signed cert or use existing
# then:
http-server . -S -C cert.pem -K key.pem -p 3443
```

Then open:

```text
https://localhost:3443/index.html
```

> If you don’t use a local proxy, the frontend automatically talks to:
>
> * `https://relayer.testnet.zama.org`
> * `https://gateway.testnet.zama.org`

If you do run a local proxy on `localhost:3443`, it will instead target:

* `https://localhost:3443/relayer`
* `https://localhost:3443/gateway`

---

## 🔧 Configuration

All config lives in the `<script type="module">` block of `index.html`:

```js
const CONTRACT_ADDRESS = "0xd9780aF46cCE6e1d6803CF0ca40c27E332Fc526e";
const CHAIN_ID_HEX = "0xaa36a7"; // Sepolia
```

If you redeploy:

1. Update `CONTRACT_ADDRESS`.
2. Ensure the ABI in `ABI = [...]` matches your contract.
3. If you run Relayer / Gateway locally behind a proxy:

   * Keep the `HAS_LOCAL_PROXY` detection logic:

     ```js
     const ORIGIN = window.location.origin;
     const HAS_LOCAL_PROXY =
       ORIGIN.includes("localhost:3443") || ORIGIN.includes("127.0.0.1:3443");
     ```

---

## 🧩 FHE / Relayer Integration Details

* Uses `relayer-sdk-js`:

  ```js
  import {
    initSDK,
    createInstance,
    SepoliaConfig,
    generateKeypair
  } from "https://cdn.zama.org/relayer-sdk-js/0.3.0-5/relayer-sdk-js.js";
  ```

* **Encryption (inputs)**:

  * For both limit and amount:

    ```js
    const buf = relayer.createEncryptedInput(CONTRACT_ADDRESS, userAddress);
    buf.add16(value);
    const { handles, inputProof } = await buf.encrypt();
    ```
  * The handle + proof are passed to contract methods that expect external encrypted values.

* **userDecrypt flow**:

  * Generate ephemeral keypair.
  * Construct EIP-712 payload via `createEIP712`.
  * Sign with `signTypedData`.
  * Call `userDecrypt` with:

    * pairs (handles + contract address)
    * private/public keys
    * signature, contract list, user, timestamps.

* **publicDecrypt flow**:

  * For public certificates, simply call `publicDecrypt`:

    ```js
    await relayer.publicDecrypt([{ handle, contractAddress: CONTRACT_ADDRESS }]);
    ```

---

## 🛡️ BigInt & Decrypt Output Handling

Two key helpers make the frontend robust against `BigInt`:

### 1. Safe JSON stringify

```js
const safeStringify = (obj) =>
  JSON.stringify(obj, (k, v) => (typeof v === "bigint" ? v.toString() + "n" : v), 2);

function appendLog(...parts) {
  const msg = parts.map(x =>
    typeof x === "string" ? x : (() => { try { return safeStringify(x); } catch { return String(x); } })()
  ).join(" ");
  console.log("[log]", msg);
}
```

> This ensures you never hit **“Do not know how to serialize a BigInt”** when logging `userDecrypt` / `publicDecrypt` responses.

### 2. Normalizing decrypted values

```js
function normalizeDecryptedValue(v) {
  if (v == null) return null;
  if (typeof v === "boolean") return v ? 1n : 0n;
  if (typeof v === "bigint" || typeof v === "number") return BigInt(v);
  if (typeof v === "string") return BigInt(v);
  return BigInt(v.toString());
}
```

You always compare on the normalized `bigint`:

```js
const isAccepted = normalizeDecryptedValue(acceptedRaw) !== 0n;
```

This pattern works even if the Relayer returns booleans or numeric strings.

---

## 🚧 Limitations & Future Work

* **No pool-wide aggregated totals**
  This example focuses only on **per-staker accept/reject** based on a hidden limit. Aggregated encrypted totals are possible but not implemented here.

* **Single chain (Sepolia)**
  Hardcoded for Sepolia (`0xaa36a7`). Multi-chain support would require extra config.

* **No complex pool logic**
  There is no locking period, rewards distribution, or unbonding logic – the goal is to demonstrate **private admission decisions** under FHE.

---

## 📜 License

You can use and adapt this code for your own experiments with Zama FHEVM and private staking logic.
Add your favorite license (MIT, Apache-2.0, etc.) here depending on your repo policy.
