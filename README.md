# Encrypted Player Registry · Zama FHEVM

A minimal demo dApp that showcases how to build a privacy‑preserving player registry on top of the **Zama FHEVM**.

Each player registers with:

* a **public name** stored in plaintext (for leaderboards / UX), and
* a **fully homomorphic encrypted age** stored as an `euint8` in the smart contract.

The age is never revealed on-chain in clear form. The player can decrypt their own age off‑chain using the **Relayer SDK 0.2.0** and an EIP‑712 signature.

---

## Tech stack

* **Smart contract**: Solidity `^0.8.24`

  * `@fhevm/solidity` (Zama FHE library)
  * `SepoliaConfig` from Zama FHEVM config
* **Frontend**: single‑page HTML app

  * `@zama-fhe/relayer-sdk` **0.2.0** (browser build)
  * `ethers` **v6** (ESM, `BrowserProvider`, `Contract`)
* **Network**: Sepolia FHEVM (testnet)
* **Tooling**: Hardhat + hardhat‑deploy (backend), static web server (frontend)

Frontend entry point lives at:

```text
frontend/public/index.html
```

---

## Main idea

The dApp demonstrates a simple pattern for Zama FHEVM:

1. The user encrypts sensitive data (age) **in the browser** using the Relayer SDK.
2. The encrypted value is sent to the smart contract as an `externalEuint8` handle + `proof`.
3. The contract converts this into an `euint8` and stores it in state.
4. The user can later:

   * Inspect the **encrypted age handle** on-chain, and
   * Use **userDecrypt** with an EIP‑712 signature to recover their age off‑chain.

This pattern is reusable for any “profile with private fields” system.

---

## Smart contract overview

Contract name: `EncryptedPlayerRegistry`

Key properties:

* Uses only official Zama FHE Solidity library:

  * `import { FHE, euint8, externalEuint8 } from "@fhevm/solidity/lib/FHE.sol";`
* Extends `SepoliaConfig` for the FHEVM network configuration.
* Encrypted fields are always stored as `euint8` and **never decrypted on-chain**.
* Access control over ciphertexts is handled via:

  * `FHE.allowThis(ciphertext)`
  * `FHE.allow(ciphertext, user)`
  * `FHE.makePubliclyDecryptable(ciphertext)` for opt‑in public auditability.

### Storage

```solidity
struct Player {
    bool exists;   // registration flag
    string name;   // public display name
    euint8 age;    // encrypted age
}

mapping(address => Player) private _players;
address public owner;
```

* `name` is stored in the clear.
* `age` is an encrypted `euint8`.

### Public / player functions

* `registerEncrypted(string name, externalEuint8 ageExt, bytes proof)`

  * Encrypt age in the browser using the Relayer SDK.
  * Call this function with the encrypted handle and proof.
  * Contract:

    * calls `FHE.fromExternal(ageExt, proof)` → `euint8` ciphertext;
    * stores it in `_players[msg.sender].age`;
    * uses `FHE.allowThis` and `FHE.allow(ciphertext, msg.sender)`.

* `registerPlain(string name, uint8 agePlain)`

  * Dev/demo helper.
  * Converts plaintext `agePlain` into ciphertext using `FHE.asEuint8` on-chain.

* `updateName(string newName)`

  * Updates only the public `name` field.

* `updateAgeEncrypted(externalEuint8 newAgeExt, bytes proof)`

  * Updates only the encrypted age.

* `isRegistered(address player) -> bool`

  * Returns whether a player has a profile.

* `getPlayer(address player) -> (bool exists, string name, bytes32 ageHandle)`

  * Returns profile metadata and the encrypted age handle (`bytes32`).
  * `ageHandle` can be fed to public decryption or user decryption off-chain.

* `getMyAgeHandle() -> bytes32`

  * Convenience method to fetch the `bytes32` handle for `msg.sender`’s age.

* `makeMyAgePublic()`

  * Calls `FHE.makePubliclyDecryptable(_players[msg.sender].age)`.
  * Allows anyone to call `publicDecrypt` on the ciphertext.

### Owner/admin functions

* `owner` / `transferOwnership(address newOwner)`

  * Standard ownership pattern.

* `makePlayerAgePublic(address player)`

  * For audits / demos, owner can force a player’s age to be publicly decryptable.

* `clearPlayer(address player)`

  * Logically clears a player profile.
  * Sets `exists = false`, wipes `name`, and replaces age with `FHE.asEuint8(0)`.
  * Avoids using `delete` on `euint8` (not supported).

---

## Frontend overview

The frontend is a single `index.html` with:

* A **three‑column layout**:

  * Player onboarding (name + encrypted age).
  * “My profile” section (view profile, update name/age, decrypt age).
  * Owner console (mark ages public / clear profiles).
* A **dark neon UI** designed to be visually distinct from other demos.
* Uses **Relayer SDK 0.2.0** and **ethers v6** via ESM CDNs.

Key flows:

### 1. Connect wallet & Relayer

* Uses `BrowserProvider(window.ethereum)` from ethers v6.
* Automatically switches to Sepolia (chain id `0xaa36a7`).
* Initializes the Relayer with:

```ts
await initSDK();
relayer = await createInstance({
  ...SepoliaConfig,
  relayerUrl: "https://relayer.testnet.zama.cloud",
  network: window.ethereum,
  debug: true,
});
```

### 2. Encrypted registration

* User enters `name` + `age`.
* Frontend calls:

```ts
const input = relayer.createEncryptedInput(CONTRACT_ADDRESS, user);
input.add8(age);                      // age is uint8
const { handles, inputProof } = await input.encrypt();

await contract.registerEncrypted(name, handles[0], inputProof);
```

### 3. Decrypting age (userDecrypt)

* Frontend calls `getMyAgeHandle()`.
* Generates an ephemeral keypair with `generateKeypair()`.
* Builds EIP‑712 data via `relayer.createEIP712(...)`.
* Uses `signer.signTypedData(...)` (EIP‑712) and then:

```ts
const pairs = [{ handle, contractAddress: CONTRACT_ADDRESS }];
const result = await relayer.userDecrypt(
  pairs,
  kp.privateKey,
  kp.publicKey,
  sig.replace("0x", ""),
  [CONTRACT_ADDRESS],
  user,
  startTs,
  daysValid,
);
```

* Displays the decrypted age **only in the UI**, never sending it back on-chain.

---

## Project layout

A minimal layout (simplified):

```text
.
├── contracts/
│   └── EncryptedPlayerRegistry.sol
├── frontend/
│   └── public/
│       └── index.html   # the SPA described above
├── deploy/
│   └── universal-deploy.ts
├── hardhat.config.ts
├── package.json
└── README.md
```

---

## Installation & setup

### 1. Clone & install dependencies

```bash
git clone &lt;this-repo-url&gt;
cd &lt;this-repo-folder&gt;

# Install backend deps (Hardhat, hardhat-deploy, etc.)
npm install
```

If the frontend uses its own `package.json` inside `frontend/`, also run:

```bash
cd frontend
npm install
cd ..
```

### 2. Environment variables (Hardhat)

In the project root, create a `.env` file (or update an existing one):

```bash
SEPOLIA_RPC_URL=https://&lt;your-sepolia-rpc&gt;
PRIVATE_KEY=0x&lt;your_deployer_private_key&gt;

# Optional for universal-deploy
CONTRACT_NAME=EncryptedPlayerRegistry
CONSTRUCTOR_ARGS='[]'
```

> **Note:** never commit real private keys to Git. Use environment variables or a secure secret manager.

### 3. Compile & deploy the contract

```bash
npx hardhat clean
npx hardhat compile
npx hardhat deploy --network sepolia
```

If you use the provided `universal-deploy.ts` script, it will pick up `CONTRACT_NAME` and `CONSTRUCTOR_ARGS` automatically.

Make sure the deployed address matches the one used by the frontend (`CONTRACT_ADDRESS` constant in `index.html`).

---

## Running the frontend

Since the frontend is a static HTML SPA using WASM and `Cross-Origin-Opener-Policy`, you should serve it via a local HTTP server (not via `file://`).

From the project root:

```bash
cd frontend/public

# Simple option: use serve (no config needed)
npx serve .

# or, if you prefer http-server
# npx http-server .
```

Then open the printed URL in your browser (e.g. [http://localhost:3000](http://localhost:3000) or [http://127.0.0.1:8080](http://127.0.0.1:8080)).

Requirements:

* Browser with EIP‑1193 wallet (MetaMask, Rabby…) connected to **Sepolia**.
* Zama FHEVM RPC configured in your wallet / Hardhat.

---

## How to use the dApp

1. **Connect wallet**

   * Click **“Connect wallet”** in the header.
   * Approve network switch to Sepolia if prompted.

2. **Register as a player**

   * In **“Player onboarding”** panel:

     * Enter a public display name.
     * Enter your age (0–255).
     * Click **“Encrypt & register”**.
   * Wait for the transaction to confirm.

3. **Inspect your profile**

   * In **“My profile”** panel, click **“Load my profile”**.
   * You will see:

     * Your name, and
     * Your encrypted age handle (`bytes32`).

4. **Decrypt your age**

   * Click **“Private decrypt via Relayer”**.
   * Sign the EIP‑712 message in your wallet.
   * The decrypted age will appear as a pill in the UI, visible only in your browser.

5. **Owner tools (optional)**

   * If connected as `owner`:

     * Use **“Make age public”** for a target address to enable public decryption.
     * Use **“Clear profile”** to logically clear a user profile.

---



---

## License

MIT — feel free to fork, adapt and extend for your own Zama FHEVM demos.
