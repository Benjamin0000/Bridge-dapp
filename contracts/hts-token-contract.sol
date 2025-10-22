//0xe8C85D68B840c6c5A880D5E19B81F3AfE87e2404 
//0x00000000000000000000000000000000006c6456 <== hts token address

// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// Hedera system contracts (HTS precompile helpers)
import "https://github.com/hashgraph/hedera-smart-contracts/blob/main/contracts/system-contracts/hedera-token-service/HederaTokenService.sol";
import "https://github.com/hashgraph/hedera-smart-contracts/blob/main/contracts/system-contracts/hedera-token-service/IHederaTokenService.sol";
import "https://github.com/hashgraph/hedera-smart-contracts/blob/main/contracts/system-contracts/HederaResponseCodes.sol";

/// @title Vault for Native (HBAR) and HTS Tokens (Fungible only)
/// @notice Minimal vault supporting native deposits and HTS fungible tokens
//contract in POC
contract Vault is HederaTokenService {
    address public owner;
    address public admin;

    /* ========== EVENTS ========== */
    event NativeDeposited(address indexed from, uint256 amount, uint256 contractBalance);
    event HTSDeposited(address indexed token, address indexed from, int64 amount);
    event WithdrawExecuted(address indexed to, uint256 nativeAmount, address indexed token, int64 tokenAmount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event TokenAssociated(address indexed token, int responseCode);
    event TokenDissociated(address indexed token, int responseCode);

    /* ========== MODIFIERS ========== */
    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyAdmin() { //for realyer bot 
        require(msg.sender == admin, "Only admin");
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    constructor() payable {
        owner = msg.sender;
        admin = msg.sender;
        emit AdminUpdated(address(0), msg.sender);
    }

    /* ========== RECEIVE / FALLBACK ========== */
    receive() external payable {
        emit NativeDeposited(msg.sender, msg.value, address(this).balance);
    }
    fallback() external payable {
        // accept funds
    }

    /* ========== DEPOSITS ========== */

    /// @notice Deposit native HBAR (simple payable helper)
    function depositNative() external payable returns (uint256 contractBalance) {
        require(msg.value > 0, "Must send >0");
        contractBalance = address(this).balance;
        emit NativeDeposited(msg.sender, msg.value, contractBalance);
    }

    /// @notice Deposit HTS fungible token into vault.
    /// @dev Sender must be associated with the token and have sufficient balance. This call
    ///      attempts to transfer from msg.sender to this contract using HTS precompile.
    /// @param token HTS token address (solidity-formatted)
    /// @param amount amount to deposit (in lowest denomination, int64)
    function depositHTS(address token, int64 amount) external returns (int responseCode) {
        require(token != address(0), "token address zero");
        require(amount > 0, "amount must be >0");

        //none suported HTS token must undergo a swap back to native token to maintain liquidity. 
        //will be deployed in v2 for production. 

        // Transfer HTS token from sender to contract
        responseCode = HederaTokenService.transferToken(token, msg.sender, address(this), amount);
        require(responseCode == HederaResponseCodes.SUCCESS, string(abi.encodePacked("HTS deposit failed: ", _intToString(responseCode))));

        emit HTSDeposited(token, msg.sender, amount);
    }

    /* ========== ASSOCIATION HELPERS ========== */

    /// @notice Associate this contract with an HTS token. Contract must have HBAR balance to cover assoc fee.
    /// @param token HTS token address
    function associateTokenToVault(address token) external onlyOwner returns (int responseCode) {
        require(token != address(0), "token zero");
        responseCode = HederaTokenService.associateToken(address(this), token);
        emit TokenAssociated(token, responseCode);
        require(responseCode == HederaResponseCodes.SUCCESS, string(abi.encodePacked("assoc failed: ", _intToString(responseCode))));
    }

    /// @notice Dissociate this contract from an HTS token (must have zero balance for that token).
    function dissociateTokenFromVault(address token) external onlyOwner returns (int responseCode) {
        require(token != address(0), "token zero");
        responseCode = HederaTokenService.dissociateToken(address(this), token);
        emit TokenDissociated(token, responseCode);
        require(responseCode == HederaResponseCodes.SUCCESS, string(abi.encodePacked("dissoc failed: ", _intToString(responseCode))));
    }

    /* ========== WITHDRAWALS (ADMIN ONLY) ========== */

    /// @notice Withdraw native HBAR and/or an HTS fungible token from the vault (admin only).
    /// @param to recipient address (payable for native)
    /// @param nativeAmount native HBAR amount in wei (use 0 to skip)
    /// @param token HTS token address (use address(0) if skipping token)
    /// @param tokenAmount HTS amount as int64 (use 0 to skip)
    function withdraw(
        address payable to,
        uint256 nativeAmount,
        address token,
        int64 tokenAmount
    )
        external
        onlyAdmin
        returns (bool sentNative, bool sentHTS)
    {
        require(to != address(0), "recipient zero");

        // Native HBAR withdraw
        if (nativeAmount > 0) {
            require(address(this).balance >= nativeAmount, "insufficient native balance");
            (sentNative, ) = to.call{value: nativeAmount}("");
            require(sentNative, "native transfer failed");
        } else {
            sentNative = true;
        }

        //token swap may occur to get users desired token. 
        //will be deployed in v2 for production. 

        // HTS fungible withdraw
        if (tokenAmount > 0) {
            require(token != address(0), "token zero");
            int response = HederaTokenService.transferToken(token, address(this), to, tokenAmount);
            require(response == HederaResponseCodes.SUCCESS, string(abi.encodePacked("HTS transfer failed: ", _intToString(response))));
            sentHTS = true;
        } else {
            sentHTS = true;
        }

        emit WithdrawExecuted(to, nativeAmount, token, tokenAmount);
    }

    /* ========== ADMIN/OWNER ========== */

    /// @notice Owner can change admin
    function setAdmin(address newAdmin) external onlyOwner {
        require(newAdmin != address(0), "admin zero");
        address old = admin;
        admin = newAdmin;
        emit AdminUpdated(old, newAdmin);
    }

    /* ========== VIEW HELPERS ========== */

    /// @notice Get contract native HBAR balance
    function nativeBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /* ========== RESCUE (OWNER) ========== */

    function rescueNative(address payable to, uint256 amount) external onlyOwner {
        require(to != address(0), "to zero");
        (bool s, ) = to.call{value: amount}("");
        require(s, "rescue native failed");
    }

    function rescueHTS(address token, address to, int64 amount) external onlyOwner {
        require(token != address(0), "token zero");
        require(to != address(0), "to zero");
        int response = HederaTokenService.transferToken(token, address(this), to, amount);
        require(response == HederaResponseCodes.SUCCESS, string(abi.encodePacked("rescue HTS failed: ", _intToString(response))));
    }

    /* ========== INTERNAL HELPERS ========== */

    // Convert int -> string for revert/debug messages
    function _intToString(int value) internal pure returns (string memory) {
        if (value == 0) return "0";
        bool negative = value < 0;
        uint temp = uint(negative ? -value : value);
        bytes memory buffer;
        while (temp != 0) {
            buffer = abi.encodePacked(bytes1(uint8(48 + temp % 10)), buffer);
            temp /= 10;
        }
        if (negative) {
            return string(abi.encodePacked("-", buffer));
        } else {
            return string(buffer);
        }
    }
}
