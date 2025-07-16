// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniversalRouter} from "@uniswap/universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IAdapterCallbacks} from "./interfaces/IAdapterCallbacks.sol";
import {IUniversalRouterAdapter} from "./interfaces/IUniversalRouterAdapter.sol";
import {IUniversalRouterAdapterStrategy} from "./interfaces/IUniversalRouterAdapterStrategy.sol";

contract UniversalRouterAdapter is 
    IAdapterCallbacks, 
    IUniversalRouterAdapter, 
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable 
{
    using SafeERC20 for IERC20;

    IUniversalRouter public universalRouter;
    IAllowanceTransfer public permit2;
    address public vault;
    address public asset;

    mapping(uint256 => IUniversalRouterAdapterStrategy) public strategies;
    mapping(uint256 => bool) public commandWhitelist;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract replacing the constructor for upgradeable contracts
     * @param _universalRouter Address of the Uniswap Universal Router
     * @param _permit2 Address of the Permit2 contract
     * @param _vault Address of the ERC4626 vault contract
     */
    function initialize(
        address _universalRouter,
        address _permit2,
        address _vault
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        
        universalRouter = IUniversalRouter(_universalRouter);
        permit2 = IAllowanceTransfer(_permit2);
        vault = _vault;
        asset = IERC4626(_vault).asset();
    }

    /**
     * @notice Authorizes contract upgrades
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyStrategy(uint256 command) {
        if (address(strategies[command]) != msg.sender) revert IAdapterCallbacks.NotAuthorized();
        _;
    }

    function setCommandWhitelist(uint256 command, bool whitelist) external onlyOwner {
        commandWhitelist[command] = whitelist;
    }

    function setStrategy(uint256 command, IUniversalRouterAdapterStrategy strategy) external onlyOwner {
        strategies[command] = strategy;
    }

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert IUniversalRouter.TransactionDeadlinePassed();
        execute(commands, inputs);
    }

    function execute(bytes calldata commands, bytes[] calldata inputs) public payable {
        uint256 numCommands = commands.length;

        bytes[] memory modifiedInputs = new bytes[](numCommands);

        if (inputs.length != numCommands) revert IUniversalRouter.LengthMismatch();

        for (uint256 i = 0; i < numCommands; i++) {
            bytes1 commandType = commands[i];
            uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

            if (!commandWhitelist[command]) revert CommandNotWhitelisted();

            bytes calldata input = inputs[i];
            modifiedInputs[i] = input;
            IUniversalRouterAdapterStrategy strategy = strategies[command];

            if (address(strategy) != address(0)) {
                (IUniversalRouterAdapterStrategy.PackedApproval[] memory approvals, bytes memory modifiedInput) =
                    strategy.beforeExecute(command, input, msg.sender);

                if (modifiedInput.length > 0) {
                    modifiedInputs[i] = modifiedInput;
                }

                _batchApprove(approvals);
            }
        }

        universalRouter.execute(commands, modifiedInputs, block.timestamp);

        // @note execute in reverse order
        for (uint256 i = numCommands; i > 0; i--) {
            bytes1 commandType = commands[i - 1];
            uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);
            bytes memory input = modifiedInputs[i - 1];
            IUniversalRouterAdapterStrategy strategy = strategies[command];

            if (address(strategy) != address(0)) {
                strategy.afterExecute(command, input, msg.sender);
            }
        }
    }

    function permit2TransferFrom(uint256 fromCommand, address from, uint256 amount, address token)
        external
        override
        nonReentrant
        onlyStrategy(fromCommand)
        returns (uint256 actualAmount)
    {
        if (token == vault) {
            // amount = desired vault shares
            // Convert shares to required assets using previewMint
            uint256 assets = IERC4626(vault).previewMint(amount);

            // Security check: ensure assets fits in uint160 for Permit2
            if (assets > type(uint160).max) {
                revert ExceedPermit2Limit();
            }

            permit2.transferFrom(from, address(this), uint160(assets), asset);
            IERC20(asset).forceApprove(vault, assets);
            actualAmount = IERC4626(vault).deposit(assets, address(this));
        } else {
            permit2.transferFrom(from, address(this), uint160(amount), token);
            actualAmount = amount;
        }
    }

    function transferTo(uint256 fromCommand, address to, uint256 amount, address token)
        external
        override
        nonReentrant
        onlyStrategy(fromCommand)
    {
        if (token == vault) {
            IERC4626(vault).redeem(amount, to, address(this));
        } else {
            IERC20(token).transfer(to, amount);
        }
    }

    function _increaseAllowance(address token, address spender, uint256 amount) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        IERC20(token).forceApprove(spender, allowance + amount);
    }

    function _increasePermit2Allowance(address token, address spender, uint256 amount) internal {
        (uint160 oldAmount, uint48 expiration,) = permit2.allowance(address(this), token, spender);
        if (block.timestamp > expiration) {
            oldAmount = 0;
        }
        // @note ask allowance for every single transaction, the expiration is always current block timestamp
        permit2.approve(token, spender, uint160(oldAmount + amount), uint48(block.timestamp));
    }

    function _batchApprove(IUniversalRouterAdapterStrategy.PackedApproval[] memory approvals) internal {
        for (uint256 j = 0; j < approvals.length; j++) {
            _increaseAllowance(approvals[j].token, address(permit2), approvals[j].amount);
            _increasePermit2Allowance(approvals[j].token, address(universalRouter), approvals[j].amount);
        }
    }
}
