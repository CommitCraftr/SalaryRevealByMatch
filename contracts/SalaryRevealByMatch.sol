// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/* Zama FHEVM */
import { FHE, ebool, euint16, euint32, externalEuint16, externalEuint32 } from "@fhevm/solidity/lib/FHE.sol";
import { ZamaEthereumConfig } from "@fhevm/solidity/config/ZamaConfig.sol";


contract SalaryRevealByMatch is ZamaEthereumConfig {
    /* ─────────────────────────────
       Storage
       ───────────────────────────── */
    struct Post {
        address owner;        // post owner
        euint32 salary;       // encrypted salary (e.g., in minor units)
        euint16 roleId;       // encrypted role code
        euint16 regionId;     // encrypted region code
        uint64  createdAt;    // timestamp (for UX)
        bool    set;
    }

    uint256 public nextPostId;
    mapping(uint256 => Post) private posts; // id => Post

    /* ─────────────────────────────
       Events
       ───────────────────────────── */
    event PostPublished(uint256 indexed id, address indexed owner);
    event AccessGranted(uint256 indexed id, address indexed to);
    event SalaryRevealed(uint256 indexed id, address indexed requester, bytes32 revealHandle);
    event SalaryMadePublic(uint256 indexed id);

    /* ─────────────────────────────
       Publish: owner creates a salary post
       ───────────────────────────── */
    function publish(
        externalEuint32 encSalary,
        externalEuint16 encRoleId,
        externalEuint16 encRegionId,
        bytes calldata attestation
    ) external returns (uint256 id) {
        // Import external ciphertexts (attestation checked by the library/host contracts)
        euint32 salary  = FHE.fromExternal(encSalary, attestation);
        euint16 role    = FHE.fromExternal(encRoleId, attestation);
        euint16 region  = FHE.fromExternal(encRegionId, attestation);

        // Optional sanity clamp: salary = max(0, min(salary, 100_000_000)) — adjustable bound
        // to limit domain and mitigate accidental outliers without revealing plaintext.
        euint32 maxCap = FHE.asEuint32(100_000_000); // e.g., 1e8 (choose units on frontend)
        salary = FHE.min(FHE.max(salary, FHE.asEuint32(0)), maxCap);

        id = nextPostId++;
        Post storage P = posts[id];
        P.owner    = msg.sender;
        P.salary   = salary;
        P.roleId   = role;
        P.regionId = region;
        P.createdAt = uint64(block.timestamp);
        P.set = true;

        // Persist ACLs for later use by this contract and the owner
        FHE.allowThis(P.salary);
        FHE.allowThis(P.roleId);
        FHE.allowThis(P.regionId);
        FHE.allow(P.salary, msg.sender);
        FHE.allow(P.roleId, msg.sender);
        FHE.allow(P.regionId, msg.sender);

        emit PostPublished(id, msg.sender);
    }

    /* ─────────────────────────────
       Reveal path: requester submits their (role, region) and gets a gated handle
       ───────────────────────────── */
    function revealIfMatch(
        uint256 id,
        externalEuint16 requesterRole,
        externalEuint16 requesterRegion,
        bytes calldata attestation
    ) external returns (bytes32 handle) {
        Post storage P = posts[id];
        require(P.set, "no post");

        // Import requester inputs
        euint16 rRole   = FHE.fromExternal(requesterRole, attestation);
        euint16 rRegion = FHE.fromExternal(requesterRegion, attestation);

        // ok = (rRole == P.roleId) && (rRegion == P.regionId)
        ebool roleEq   = FHE.eq(rRole, P.roleId);
        ebool regionEq = FHE.eq(rRegion, P.regionId);
        ebool ok = FHE.and(roleEq, regionEq);

        // reveal = ok ? P.salary : 0  (no branching on plaintext)
        euint32 reveal = FHE.select(ok, P.salary, FHE.asEuint32(0));

        // Access: requester + contract; owner also allowed for transparency/auditing
        FHE.allow(reveal, msg.sender);
        FHE.allowThis(reveal);
        FHE.allow(reveal, P.owner);

        handle = FHE.toBytes32(reveal);
        emit SalaryRevealed(id, msg.sender, handle);
    }

    /* ─────────────────────────────
       Owner utilities
       ───────────────────────────── */
    function grantPostAccess(uint256 id, address to) external {
        Post storage P = posts[id];
        require(P.set, "no post");
        require(msg.sender == P.owner, "not owner");
        require(to != address(0), "bad addr");
        FHE.allow(P.salary, to);
        FHE.allow(P.roleId, to);
        FHE.allow(P.regionId, to);
        emit AccessGranted(id, to);
    }

    function makeSalaryPublic(uint256 id) external {
        Post storage P = posts[id];
        require(P.set, "no post");
        require(msg.sender == P.owner, "not owner");
        FHE.makePubliclyDecryptable(P.salary);
        emit SalaryMadePublic(id);
    }

    /* ─────────────────────────────
       Minimal getters (opaque)
       ───────────────────────────── */
    function ownerOf(uint256 id) external view returns (address) {
        return posts[id].owner;
    }

    function createdAt(uint256 id) external view returns (uint64) {
        return posts[id].createdAt;
    }

    /// @notice Returns an opaque handle to the stored salary (caller must have ACL to decrypt).
    function salaryHandle(uint256 id) external view returns (bytes32) {
        require(posts[id].set, "no post");
        return FHE.toBytes32(posts[id].salary);
    }

    /// @notice (optional) Opaque handles for metadata — useful for audits or off-chain checks.
    function roleHandle(uint256 id) external view returns (bytes32) {
        require(posts[id].set, "no post");
        return FHE.toBytes32(posts[id].roleId);
    }

    function regionHandle(uint256 id) external view returns (bytes32) {
        require(posts[id].set, "no post");
        return FHE.toBytes32(posts[id].regionId);
    }

    /* ─────────────────────────────
       Diagnostics (non-production helpers)
       ───────────────────────────── */
    function version() external pure returns (string memory) {
        return "SalaryRevealByMatch/1.0.0";
    }
}
