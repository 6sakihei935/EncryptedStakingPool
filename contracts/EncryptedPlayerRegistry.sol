// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PartnerTariffGate
 * @notice Confidential eligibility gate for partner tariffs on Zama FHEVM.
 *
 *  - Admin defines an encrypted policy per tariff (planId):
 *      * minKycLevel   (u8)
 *      * minTenureDays (u16)
 *      * minTradeVolumeUsd (u32)
 *      * minPassRules  (u8)   // number of predicates that must pass
 *
 *  - User submits encrypted profile features; contract evaluates privately and
 *    returns an encrypted decision (ebool). The user gets decrypt rights.
 *
 *  Notes:
 *   - Uses only official Zama libraries.
 *   - No FHE ops in view/pure.
 *   - Access control via FHE.allow / FHE.allowThis / FHE.allowTransient.
 *   - Use FHE.makePubliclyDecryptable to reveal policy or decisions if desired.
 */

import {
    FHE,
    ebool,
    euint8,
    euint16,
    euint32,
    externalEuint8,
    externalEuint16,
    externalEuint32
} from "@fhevm/solidity/lib/FHE.sol";

import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract PartnerTariffGate is ZamaEthereumConfig {
    /* ------------------------------ Ownable ------------------------------ */
    address public owner;
    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }

    constructor() { owner = msg.sender; }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Zero owner");
        owner = newOwner;
    }

    /* ------------------------------ Storage ----------------------------- */
    struct Policy {
        bool    exists;
        euint8  minKycLevel;         // e.g., 0..5
        euint16 minTenureDays;       // account age
        euint32 minTradeVolumeUsd;   // rolling volume in USD cents or scaled
        euint8  minPassRules;        // 1..3
    }

    // Encrypted policy per tariff plan
    mapping(uint256 => Policy) private _policies;

    // Per-user encrypted decision cache (optional convenience)
    mapping(uint256 => mapping(address => ebool)) private _eligibility;

    /* -------------------------------- Events ---------------------------- */
    event PolicySet(uint256 indexed planId);
    event PolicyCleared(uint256 indexed planId);
    event EligibilityEvaluated(uint256 indexed planId, address indexed user, bytes32 decisionHandle);

    /* ------------------------------ Metadata ---------------------------- */
    function version() external pure returns (string memory) {
        return "PartnerTariffGate/1.0.0";
    }

    function hasPolicy(uint256 planId) external view returns (bool) {
        return _policies[planId].exists;
    }

    /* ------------------------------ Admin: set policy (encrypted) ------------------------------ */
    function setPolicyEncrypted(
        uint256          planId,
        externalEuint8   minKycLevelExt,
        externalEuint16  minTenureDaysExt,
        externalEuint32  minTradeVolumeUsdExt,
        externalEuint8   minPassRulesExt,
        bytes calldata   proof
    ) external onlyOwner {
        require(planId != 0, "Bad planId");
        require(proof.length > 0, "Empty proof");
        Policy storage p = _policies[planId];
        p.exists = true;

        { euint8 v = FHE.fromExternal(minKycLevelExt, proof);        FHE.allowThis(v); p.minKycLevel = v; }
        { euint16 v = FHE.fromExternal(minTenureDaysExt, proof);     FHE.allowThis(v); p.minTenureDays = v; }
        { euint32 v = FHE.fromExternal(minTradeVolumeUsdExt, proof); FHE.allowThis(v); p.minTradeVolumeUsd = v; }
        { euint8 v = FHE.fromExternal(minPassRulesExt, proof);       FHE.allowThis(v); p.minPassRules = v; }

        emit PolicySet(planId);
    }

    /* ------------------------------ Admin: set policy (plaintext, dev/demo only) ------------------------------ */
    function setPolicyPlain(
        uint256 planId,
        uint8   minKycLevel,
        uint16  minTenureDays,
        uint32  minTradeVolumeUsd,
        uint8   minPassRules
    ) external onlyOwner {
        require(planId != 0, "Bad planId");
        Policy storage p = _policies[planId];
        p.exists = true;

        { euint8 v = FHE.asEuint8(minKycLevel);            FHE.allowThis(v); p.minKycLevel = v; }
        { euint16 v = FHE.asEuint16(minTenureDays);         FHE.allowThis(v); p.minTenureDays = v; }
        { euint32 v = FHE.asEuint32(minTradeVolumeUsd);     FHE.allowThis(v); p.minTradeVolumeUsd = v; }
        { euint8 v = FHE.asEuint8(minPassRules);            FHE.allowThis(v); p.minPassRules = v; }

        emit PolicySet(planId);
    }

    function makePolicyPublic(uint256 planId) external onlyOwner {
        Policy storage p = _policies[planId];
        require(p.exists, "No policy");
        FHE.makePubliclyDecryptable(p.minKycLevel);
        FHE.makePubliclyDecryptable(p.minTenureDays);
        FHE.makePubliclyDecryptable(p.minTradeVolumeUsd);
        FHE.makePubliclyDecryptable(p.minPassRules);
    }

    function clearPolicy(uint256 planId) external onlyOwner {
        Policy storage p = _policies[planId];
        require(p.exists, "No policy");
        p.exists = false;
        emit PolicyCleared(planId);
    }

    /* ------------------------------ Eligibility evaluation ------------------------------ */
    /// @notice Evaluate eligibility for msg.sender using encrypted inputs.
    /// @param planId   The partner tariff id.
    /// @param kycLevelExt       externalEuint8: caller's KYC level.
    /// @param tenureDaysExt     externalEuint16: account age (days).
    /// @param volumeUsdExt      externalEuint32: rolling trade volume in USD units (pick a scaling, e.g., cents or 1e-6).
    /// @param proof   Coprocessor attestation for the packed inputs.
    /// @return decisionCt  ebool: 1 = eligible, 0 = not eligible (access granted to caller + this).
    function evaluateEligibilityEncrypted(
        uint256          planId,
        externalEuint8   kycLevelExt,
        externalEuint16  tenureDaysExt,
        externalEuint32  volumeUsdExt,
        bytes calldata   proof
    ) external returns (ebool decisionCt) {
        Policy storage pol = _policies[planId];
        require(pol.exists, "No policy");
        require(proof.length > 0, "Empty proof");

        euint8 passed = FHE.asEuint8(0);

        // Rule 1: KYC level >= minKycLevel
        {
            euint8 kyc = FHE.fromExternal(kycLevelExt, proof);
            ebool ok = FHE.ge(kyc, pol.minKycLevel);
            passed = FHE.add(passed, FHE.select(ok, FHE.asEuint8(1), FHE.asEuint8(0)));
        }

        // Rule 2: Tenure days >= minTenureDays
        {
            euint16 t = FHE.fromExternal(tenureDaysExt, proof);
            ebool ok = FHE.ge(t, pol.minTenureDays);
            passed = FHE.add(passed, FHE.select(ok, FHE.asEuint8(1), FHE.asEuint8(0)));
        }

        // Rule 3: Trade volume >= minTradeVolumeUsd
        {
            euint32 v = FHE.fromExternal(volumeUsdExt, proof);
            ebool ok = FHE.ge(v, pol.minTradeVolumeUsd);
            passed = FHE.add(passed, FHE.select(ok, FHE.asEuint8(1), FHE.asEuint8(0)));
        }

        decisionCt = FHE.ge(passed, pol.minPassRules);
        // Grant access to caller and this contract for later usage
        FHE.allow(decisionCt, msg.sender);
        FHE.allowThis(decisionCt);

        // Cache per user for UX (optional)
        _eligibility[planId][msg.sender] = decisionCt;

        emit EligibilityEvaluated(planId, msg.sender, FHE.toBytes32(decisionCt));
        return decisionCt;
    }

    /// @notice Get the stored eligibility handle for msg.sender (if cached).
    function getMyEligibilityHandle(uint256 planId) external view returns (bytes32) {
        ebool h = _eligibility[planId][msg.sender];
        return FHE.toBytes32(h);
    }

    /// @notice User can make their own eligibility decision publicly decryptable.
    function makeMyEligibilityPublic(uint256 planId) external {
        ebool h = _eligibility[planId][msg.sender];
        // Require that a decision exists (non-zero handle). This is a soft check since handle 0 is unlikely.
        require(FHE.toBytes32(h) != bytes32(0), "No decision");
        FHE.makePubliclyDecryptable(h);
    }

    /// @notice Admin may reveal a user's eligibility (opt-in policies may prefer the user endpoint above).
    function adminMakeEligibilityPublic(uint256 planId, address user) external onlyOwner {
        ebool h = _eligibility[planId][user];
        require(FHE.toBytes32(h) != bytes32(0), "No decision");
        FHE.makePubliclyDecryptable(h);
    }

    /* ------------------------------ Debug utilities (optional) ------------------------------ */
    function selfTestProof8(externalEuint8 ext, bytes calldata proof) external returns (bytes32) {
        euint8 v = FHE.fromExternal(ext, proof);
        FHE.allowThis(v);
        return FHE.toBytes32(v);
    }

    function selfTestProof16(externalEuint16 ext, bytes calldata proof) external returns (bytes32) {
        euint16 v = FHE.fromExternal(ext, proof);
        FHE.allowThis(v);
        return FHE.toBytes32(v);
    }

    function selfTestProof32(externalEuint32 ext, bytes calldata proof) external returns (bytes32) {
        euint32 v = FHE.fromExternal(ext, proof);
        FHE.allowThis(v);
        return FHE.toBytes32(v);
    }
}
