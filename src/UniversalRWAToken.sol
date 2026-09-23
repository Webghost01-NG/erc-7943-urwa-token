// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165, IERC7943Fungible} from "./IERC7943Fungible.sol";

/// @notice A deliberately scoped ERC-20 implementation of ERC-7943 uRWA controls.
contract UniversalRWAToken is IERC7943Fungible {
    error NotAdmin(address caller);
    error ZeroAddress();
    error InsufficientBalance(address account, uint256 available, uint256 required);
    error InsufficientAllowance(address owner, address spender, uint256 available, uint256 required);
    error SourceNotFrozen(address account);

    enum RejectionReason {
        SenderNotAllowed,
        ReceiverNotAllowed,
        InsufficientUnfrozenBalance
    }

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event AllowlistUpdated(address indexed account, bool allowed);
    event TransferRejected(address indexed from, address indexed to, uint256 amount, RejectionReason reason);

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    address public immutable admin;

    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _allowlisted;
    mapping(address => uint256) private _frozenTokens;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin(msg.sender);
        _;
    }

    constructor(string memory name_, string memory symbol_, uint256 initialSupply) {
        name = name_;
        symbol = symbol_;
        admin = msg.sender;
        _allowlisted[msg.sender] = true;
        emit AllowlistUpdated(msg.sender, true);
        _mint(msg.sender, initialSupply);
    }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _transferWithCompliance(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (!_validateTransfer(from, to, amount)) {
            _emitTransferRejection(from, to, amount);
            return false;
        }

        uint256 currentAllowance = _allowances[from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) {
                revert InsufficientAllowance(from, msg.sender, currentAllowance, amount);
            }
            unchecked {
                _allowances[from][msg.sender] = currentAllowance - amount;
            }
            emit Approval(from, msg.sender, _allowances[from][msg.sender]);
        }
        _move(from, to, amount);
        return true;
    }

    /// @notice Admin-controlled allow-list used as the assignment's compliance policy.
    function setAllowlisted(address account, bool allowed) external onlyAdmin {
        if (account == address(0)) revert ZeroAddress();
        _allowlisted[account] = allowed;
        emit AllowlistUpdated(account, allowed);
    }

    function isAllowlisted(address account) external view returns (bool) {
        return _allowlisted[account];
    }

    /// @notice Course-friendly full-address freeze. It also freezes future received tokens.
    function freeze(address account) external onlyAdmin returns (bool) {
        return _setFrozenTokens(account, type(uint256).max);
    }

    /// @notice Course-friendly full unfreeze.
    function unfreeze(address account) external onlyAdmin returns (bool) {
        return _setFrozenTokens(account, 0);
    }

    /// @notice ERC-7943 amount-based freeze primitive. `amount` intentionally may exceed balance.
    function setFrozenTokens(address account, uint256 amount) external onlyAdmin returns (bool) {
        return _setFrozenTokens(account, amount);
    }

    function getFrozenTokens(address account) external view returns (uint256 amount) {
        return _frozenTokens[account];
    }

    function canSend(address account) public view returns (bool allowed) {
        return _allowlisted[account];
    }

    function canReceive(address account) public view returns (bool allowed) {
        return _allowlisted[account];
    }

    function canTransfer(address from, address to, uint256 amount) public view returns (bool allowed) {
        if (!canSend(from) || !canReceive(to)) return false;
        return amount <= _unfrozenBalance(from);
    }

    /// @notice Administrative recovery from a frozen account to an allow-listed address.
    function forcedTransfer(address from, address to, uint256 amount) external onlyAdmin returns (bool) {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (_frozenTokens[from] == 0) revert SourceNotFrozen(from);
        if (!canReceive(to)) revert ERC7943CannotReceive(to);

        uint256 balance = _balances[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);

        uint256 effectiveFrozen = _effectiveFrozenBalance(from, balance);
        if (effectiveFrozen != 0) {
            uint256 remainingFrozen = effectiveFrozen > amount ? effectiveFrozen - amount : 0;
            _frozenTokens[from] = remainingFrozen;
            emit Frozen(from, remainingFrozen);
        }

        _move(from, to, amount);
        emit ForcedTransfer(from, to, amount);
        return true;
    }

    /// @notice Privileged minting is limited to compliant recipients in this scoped implementation.
    function mint(address to, uint256 amount) external onlyAdmin returns (bool) {
        if (!canReceive(to)) revert ERC7943CannotReceive(to);
        _mint(to, amount);
        return true;
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IERC165).interfaceId || interfaceId == type(IERC7943Fungible).interfaceId;
    }

    function _transferWithCompliance(address from, address to, uint256 amount) private returns (bool) {
        if (!_validateTransfer(from, to, amount)) {
            _emitTransferRejection(from, to, amount);
            return false;
        }
        _move(from, to, amount);
        return true;
    }

    function _validateTransfer(address from, address to, uint256 amount) private view returns (bool) {
        return canTransfer(from, to, amount);
    }

    function _emitTransferRejection(address from, address to, uint256 amount) private {
        RejectionReason reason;
        if (!canSend(from)) {
            reason = RejectionReason.SenderNotAllowed;
        } else if (!canReceive(to)) {
            reason = RejectionReason.ReceiverNotAllowed;
        } else {
            reason = RejectionReason.InsufficientUnfrozenBalance;
        }
        emit TransferRejected(from, to, amount, reason);
    }

    function _setFrozenTokens(address account, uint256 amount) private returns (bool) {
        if (account == address(0)) revert ZeroAddress();
        _frozenTokens[account] = amount;
        emit Frozen(account, amount);
        return true;
    }

    function _unfrozenBalance(address account) private view returns (uint256) {
        uint256 balance = _balances[account];
        uint256 frozen = _frozenTokens[account];
        return frozen >= balance ? 0 : balance - frozen;
    }

    function _effectiveFrozenBalance(address account, uint256 balance) private view returns (uint256) {
        uint256 frozen = _frozenTokens[account];
        return frozen > balance ? balance : frozen;
    }

    function _move(address from, address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = _balances[from];
        if (balance < amount) revert InsufficientBalance(from, balance, amount);
        unchecked {
            _balances[from] = balance - amount;
            _balances[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}
