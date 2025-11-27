// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import {
  FHE,
  ebool,
  euint16,
  externalEuint16
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract EncryptedStakingPool is ZamaEthereumConfig {
  // -------- Ownable --------
  address public owner;

  modifier onlyOwner() {
    require(msg.sender == owner, "Not owner");
    _;
  }

  constructor() {
    owner = msg.sender;
  }

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    owner = newOwner;
  }

  // -------- Simple nonReentrant guard (future-proof for payable flows) --------
  uint256 private _locked = 1;

  modifier nonReentrant() {
    require(_locked == 1, "reentrancy");
    _locked = 2;
    _;
    _locked = 1;
  }

  // ---------------------------------------------------------------------------
  // Pool configuration (encrypted staking limit per pool)
  // ---------------------------------------------------------------------------

  /**
   * Each pool has:
   * - exists:        whether it has been configured.
   * - eStakeLimit:   encrypted maximum stake amount allowed for a single staker.
   *
   * NOTE:
   * - Units are arbitrary (e.g. "stake points" or token units with some scaling).
   * - Type is euint16 (0..65535); frontends can scale for larger ranges if needed.
   */
  struct PoolConfig {
    bool exists;
    euint16 eStakeLimit; // encrypted maximum stake allowed per staker
  }

  // poolId => PoolConfig
  mapping(uint256 => PoolConfig) private pools;

  event PoolCreated(uint256 indexed poolId);
  event PoolUpdated(uint256 indexed poolId);
  event PoolStakeLimitUpdated(uint256 indexed poolId);

  /**
   * Create a new staking pool with an encrypted stake limit.
   *
   * @param poolId        Arbitrary identifier (e.g. 1,2,3,...).
   * @param encStakeLimit External encrypted maximum stake (per staker).
   * @param proof         Coprocessor attestation for encStakeLimit.
   *
   * Frontend flow (high-level):
   * 1) Encrypt stake limit off-chain with Relayer SDK (createEncryptedInput).
   * 2) Get externalEuint16 + proof from Gateway.
   * 3) Call this function with encStakeLimit + proof.
   */
  function createPool(
    uint256 poolId,
    externalEuint16 encStakeLimit,
    bytes calldata proof
  ) external onlyOwner {
    require(!pools[poolId].exists, "Pool already exists");

    euint16 eLimit = FHE.fromExternal(encStakeLimit, proof);

    // Contract needs long-term access to this encrypted limit
    FHE.allowThis(eLimit);

    pools[poolId] = PoolConfig({
      exists: true,
      eStakeLimit: eLimit
    });

    emit PoolCreated(poolId);
    emit PoolStakeLimitUpdated(poolId);
  }

  /**
   * Update encrypted stake limit for an existing pool.
   * Pass zero-handle + empty proof to skip stake limit update.
   */
  function updatePool(
    uint256 poolId,
    externalEuint16 encStakeLimit,
    bytes calldata proof
  ) external onlyOwner {
    PoolConfig storage P = pools[poolId];
    require(P.exists, "Pool does not exist");

    // Optional update of stake limit:
    if (proof.length != 0) {
      euint16 eLimit = FHE.fromExternal(encStakeLimit, proof);
      FHE.allowThis(eLimit);
      P.eStakeLimit = eLimit;
      emit PoolStakeLimitUpdated(poolId);
    }

    emit PoolUpdated(poolId);
  }

  /**
   * Lightweight metadata getter (no FHE operations).
   */
  function getPoolMeta(uint256 poolId)
    external
    view
    returns (bool exists)
  {
    PoolConfig storage P = pools[poolId];
    return P.exists;
  }

  // ---------------------------------------------------------------------------
  // Staker positions (encrypted stake amount + encrypted accept/reject)
  // ---------------------------------------------------------------------------

  /**
   * For each (staker, poolId) pair we store:
   * - eAmount:   encrypted stake amount submitted by staker.
   * - eAccepted: encrypted accept flag:
   *                eAccepted = (eAmount <= pool.eStakeLimit)
   * - decided:   true if at least one submission was processed.
   */
  struct StakePosition {
    euint16 eAmount;
    ebool   eAccepted;
    bool    decided;
  }

  // staker => poolId => StakePosition
  mapping(address => mapping(uint256 => StakePosition)) private stakes;

  event EncryptedStakeSubmitted(
    address indexed staker,
    uint256 indexed poolId,
    bytes32 amountHandle,
    bytes32 acceptedHandle
  );

  event PublicStakeCertificateEnabled(
    address indexed staker,
    uint256 indexed poolId,
    bytes32 acceptedHandle
  );

  /**
   * Submit encrypted stake amount for a pool.
   *
   * High-level logic:
   * - The pool stores an encrypted stake limit L.
   * - The user submits an encrypted amount A.
   * - The contract computes (under FHE):
   *       accepted := (A <= L)
   *   using FHE.ge(L, A).
   *
   * Frontend flow (high-level):
   * 1) Encrypt stake amount off-chain with Relayer SDK (createEncryptedInput).
   * 2) Get externalEuint16 + proof from Gateway.
   * 3) Call this function with encAmount + proof.
   * 4) Use getMyStakeHandles(...) + userDecrypt(...) to display amount and accept/reject.
   */
  function submitEncryptedStake(
    uint256 poolId,
    externalEuint16 encAmount,
    bytes calldata proof
  ) external nonReentrant {
    PoolConfig storage P = pools[poolId];
    require(P.exists, "Pool does not exist");

    StakePosition storage S = stakes[msg.sender][poolId];

    // Ingest encrypted amount
    euint16 eAmount = FHE.fromExternal(encAmount, proof);

    // Authorize contract and staker on this ciphertext
    FHE.allowThis(eAmount);
    FHE.allow(eAmount, msg.sender);

    // Evaluate under FHE:
    // accepted := (amount <= stakeLimit) === FHE.ge(stakeLimit, amount)
    ebool eAccepted = FHE.ge(P.eStakeLimit, eAmount);

    // Persist position
    S.eAmount   = eAmount;
    S.eAccepted = eAccepted;
    S.decided   = true;

    // Ensure contract keeps rights on stored ciphertexts
    FHE.allowThis(S.eAmount);
    FHE.allowThis(S.eAccepted);

    // Allow staker to decrypt amount and accept/reject privately
    FHE.allow(S.eAmount, msg.sender);
    FHE.allow(S.eAccepted, msg.sender);

    emit EncryptedStakeSubmitted(
      msg.sender,
      poolId,
      FHE.toBytes32(S.eAmount),
      FHE.toBytes32(S.eAccepted)
    );
  }

  // ---------------------------------------------------------------------------
  // Optional: opt-in public participation certificate
  // ---------------------------------------------------------------------------

  /**
   * Allow the staker to turn their accept flag for a pool into a
   * publicly decryptable certificate.
   *
   * After calling this, anyone can call publicDecrypt on the acceptedHandle
   * from getStakeAcceptedHandlePublic(...) to verify that the staker's
   * encrypted amount was accepted into the pool (without revealing the amount).
   *
   * NOTE: This is irreversible from a privacy perspective.
   */
  function enablePublicStakeCertificate(uint256 poolId) external nonReentrant {
    StakePosition storage S = stakes[msg.sender][poolId];
    require(S.decided, "No stake for pool");

    // Make sure contract still has access before updating flags
    FHE.allowThis(S.eAccepted);

    // Make accept flag globally decryptable
    FHE.makePubliclyDecryptable(S.eAccepted);

    emit PublicStakeCertificateEnabled(
      msg.sender,
      poolId,
      FHE.toBytes32(S.eAccepted)
    );
  }

  // ---------------------------------------------------------------------------
  // Getters (handles only, no FHE ops)
  // ---------------------------------------------------------------------------

  /**
   * Returns encrypted handles for the caller's stake in a given pool:
   * - amountHandle:   encrypted amount (userDecrypt only).
   * - acceptedHandle: encrypted accept flag (userDecrypt; may also be public if
   *                   enablePublicStakeCertificate was called).
   * - decided:        whether any stake submission was processed.
   */
  function getMyStakeHandles(uint256 poolId)
    external
    view
    returns (bytes32 amountHandle, bytes32 acceptedHandle, bool decided)
  {
    StakePosition storage S = stakes[msg.sender][poolId];
    return (
      FHE.toBytes32(S.eAmount),
      FHE.toBytes32(S.eAccepted),
      S.decided
    );
  }

  /**
   * Returns the encrypted accept flag handle for a staker's pool position.
   *
   * - If the staker has NOT enabled a public certificate, only they (via
   *   userDecrypt and ACL) will be able to decrypt this handle.
   * - If they DID enable a public certificate, anyone can publicDecrypt it
   *   to verify that their encrypted stake was accepted into the pool.
   */
  function getStakeAcceptedHandlePublic(address staker, uint256 poolId)
    external
    view
    returns (bytes32 acceptedHandle, bool decided)
  {
    StakePosition storage S = stakes[staker][poolId];
    return (FHE.toBytes32(S.eAccepted), S.decided);
  }

  /**
   * Helper to expose the encrypted stake limit handle for a pool
   * (e.g. for analytics or off-chain verification flows).
   *
   * NOTE: This handle is not publicly decryptable by default.
   * Only parties with ACL rights (typically this contract) can use it.
   */
  function getPoolLimitHandle(uint256 poolId)
    external
    view
    onlyOwner
    returns (bytes32 stakeLimitHandle)
  {
    PoolConfig storage P = pools[poolId];
    require(P.exists, "Pool does not exist");
    return FHE.toBytes32(P.eStakeLimit);
  }
}
