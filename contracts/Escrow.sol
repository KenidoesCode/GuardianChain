// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// OpenZeppelin imports
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract Escrow is Ownable, ReentrancyGuard, Pausable {

    enum AssetType { ETH, ERC20, ERC721, ERC1155 }

    struct EscrowDeal {
        uint256 dealId;
        address depositor;
        address recipient;
        address tokenAddress;  // ERC20 / ERC721 / ERC1155 contract address
        uint256 tokenId;       // For ERC721/1155
        uint256 amount;        // For ERC20/1155/ETH
        AssetType assetType;   // Which asset type
        uint256 releaseTime;   // Time-based release
        uint256 expiryTime;    // Expiry time after which depositor can cancel
        bool completed;
        bool cancelled;
    }

    uint256 public dealCounter;
    mapping(uint256 => EscrowDeal) public deals;

    // Approvals: dealId => (approver => approved?)
    mapping(uint256 => mapping(address => bool)) public approvals;

    // Approval counts
    mapping(uint256 => uint256) public approvalCount;

    uint256 public requiredApprovals;

    // Events
    event EscrowCreated(uint256 indexed dealId, address indexed depositor, address indexed recipient);
    event EscrowApproved(uint256 indexed dealId, address indexed approver);
    event EscrowExecuted(uint256 indexed dealId, address indexed recipient);
    event EscrowCancelled(uint256 indexed dealId);
    event EscrowExpired(uint256 dealId);

    constructor(uint256 _requiredApprovals) {
        require(_requiredApprovals > 0, "Approvals must be positive");
        requiredApprovals = _requiredApprovals;
        dealCounter = 0;
    }

    // --------------------------
    // CREATE ESCROW
    // --------------------------
    function createEscrow(
        address recipient,
        address tokenAddress,
        uint256 tokenId,
        uint256 amount,
        AssetType assetType,
        uint256 releaseTime,
        uint256 expiryTime
    ) external payable whenNotPaused nonReentrant returns (uint256) {
        require(recipient != address(0), "Invalid recipient");
        require(expiryTime > releaseTime, "Expiry must be after release");

        if (assetType == AssetType.ETH) {
            require(msg.value > 0, "Must send ETH");
            amount = msg.value;
        } else if (assetType == AssetType.ERC20) {
            require(amount > 0, "Amount must be > 0");
            IERC20(tokenAddress).transferFrom(msg.sender, address(this), amount);
        } else if (assetType == AssetType.ERC721) {
            IERC721(tokenAddress).transferFrom(msg.sender, address(this), tokenId);
        } else if (assetType == AssetType.ERC1155) {
            require(amount > 0, "Amount must be > 0");
            IERC1155(tokenAddress).safeTransferFrom(msg.sender, address(this), tokenId, amount, "");
        }

        uint256 currentDealId = dealCounter;
        dealCounter++;

        deals[currentDealId] = EscrowDeal({
            dealId: currentDealId,
            depositor: msg.sender,
            recipient: recipient,
            tokenAddress: tokenAddress,
            tokenId: tokenId,
            amount: amount,
            assetType: assetType,
            releaseTime: releaseTime,
            expiryTime: expiryTime,
            completed: false,
            cancelled: false
        });

        emit EscrowCreated(currentDealId, msg.sender, recipient);

        return currentDealId;
    }

    // --------------------------
    // APPROVE ESCROW
    // --------------------------
    function approveEscrow(uint256 dealId) external whenNotPaused {
        EscrowDeal storage deal = deals[dealId];
        require(deal.depositor != address(0), "Deal does not exist");
        require(!deal.completed, "Deal already completed");
        require(!deal.cancelled, "Deal cancelled");
        require(!approvals[dealId][msg.sender], "Already approved");

        approvals[dealId][msg.sender] = true;
        approvalCount[dealId]++;

        emit EscrowApproved(dealId, msg.sender);
    }

    // --------------------------
    // EXECUTE ESCROW
    // --------------------------
    function executeEscrow(uint256 dealId) external nonReentrant whenNotPaused {
        EscrowDeal storage deal = deals[dealId];
        require(deal.depositor != address(0), "Deal does not exist");
        require(!deal.completed, "Already completed");
        require(!deal.cancelled, "Deal cancelled");
        require(block.timestamp >= deal.releaseTime, "Release time not reached");
        require(approvalCount[dealId] >= requiredApprovals, "Not enough approvals");

        if (deal.assetType == AssetType.ETH) {
            (bool success, ) = payable(deal.recipient).call{value: deal.amount}("");
            require(success, "ETH transfer failed");
        } else if (deal.assetType == AssetType.ERC20) {
            IERC20(deal.tokenAddress).transfer(deal.recipient, deal.amount);
        } else if (deal.assetType == AssetType.ERC721) {
            IERC721(deal.tokenAddress).transferFrom(address(this), deal.recipient, deal.tokenId);
        } else if (deal.assetType == AssetType.ERC1155) {
            IERC1155(deal.tokenAddress).safeTransferFrom(address(this), deal.recipient, deal.tokenId, deal.amount, "");
        }

        deal.completed = true;
        emit EscrowExecuted(dealId, deal.recipient);
    }

    // --------------------------
    // CANCEL ESCROW
    // --------------------------
    function cancelEscrow(uint256 dealId) external nonReentrant whenNotPaused {
        EscrowDeal storage deal = deals[dealId];
        require(deal.depositor != address(0), "Deal does not exist");
        require(!deal.completed, "Deal already executed");
        require(!deal.cancelled, "Deal already cancelled");
        require(msg.sender == deal.depositor, "Only depositor can cancel");
        require(block.timestamp >= deal.expiryTime, "Not yet expired");

        deal.cancelled = true;

        if (deal.assetType == AssetType.ETH) {
            (bool success, ) = payable(deal.depositor).call{value: deal.amount}("");
            require(success, "ETH refund failed");
        } else if (deal.assetType == AssetType.ERC20) {
            IERC20(deal.tokenAddress).transfer(deal.depositor, deal.amount);
        } else if (deal.assetType == AssetType.ERC721) {
            IERC721(deal.tokenAddress).transferFrom(address(this), deal.depositor, deal.tokenId);
        } else if (deal.assetType == AssetType.ERC1155) {
            IERC1155(deal.tokenAddress).safeTransferFrom(address(this), deal.depositor, deal.tokenId, deal.amount, "");
        }

        emit EscrowCancelled(dealId);
    }

    // --------------------------
    // EMERGENCY FUNCTIONS
    // --------------------------
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function withdrawStuckETH(address payable to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH balance");
        (bool success, ) = to.call{value: balance}("");
        require(success, "ETH transfer failed");
    }

    function withdrawStuckERC20(address token, address to) external onlyOwner {
        require(to != address(0), "Invalid address");
        uint256 balance = IERC20(token).balanceOf(address(this));
        require(balance > 0, "No ERC20 balance");
        IERC20(token).transfer(to, balance);
    }

    function withdrawStuckERC721(address token, address to, uint256 tokenId) external onlyOwner {
        require(to != address(0), "Invalid address");
        IERC721(token).transferFrom(address(this), to, tokenId);
    }

    function withdrawStuckERC1155(address token, address to, uint256 tokenId, uint256 amount) external onlyOwner {
        require(to != address(0), "Invalid address");
        IERC1155(token).safeTransferFrom(address(this), to, tokenId, amount, "");
    }

    // --------------------------
    // ERC1155 Receiver
    // --------------------------
    function onERC1155Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    // --------------------------
    // VIEW FUNCTIONS
    // --------------------------
    function getEscrowDetails(uint256 dealId) external view returns (
        uint256 id,
        address depositor,
        address recipient,
        address tokenAddress,
        uint256 tokenId,
        uint256 amount,
        AssetType assetType,
        uint256 releaseTime,
        bool completed,
        bool cancelled
    ) {
        EscrowDeal memory deal = deals[dealId];
        return (
            deal.dealId,
            deal.depositor,
            deal.recipient,
            deal.tokenAddress,
            deal.tokenId,
            deal.amount,
            deal.assetType,
            deal.releaseTime,
            deal.completed,
            deal.cancelled
        );
    }

    function getAllDealsByUser(address user) external view returns (EscrowDeal[] memory) {
        uint256 total = dealCounter;
        uint256 count = 0;

        for (uint256 i = 0; i < total; i++) {
            if (deals[i].depositor == user || deals[i].recipient == user) {
                count++;
            }
        }

        EscrowDeal[] memory userDeals = new EscrowDeal[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < total; i++) {
            if (deals[i].depositor == user || deals[i].recipient == user) {
                userDeals[index] = deals[i];
                index++;
            }
        }

        return userDeals;
    }

    function getPendingDeals() external view returns (EscrowDeal[] memory) {
        uint256 total = dealCounter;
        uint256 count = 0;

        for (uint256 i = 0; i < total; i++) {
            if (!deals[i].completed && !deals[i].cancelled) {
                count++;
            }
        }

        EscrowDeal[] memory pendingDeals = new EscrowDeal[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < total; i++) {
            if (!deals[i].completed && !deals[i].cancelled) {
                pendingDeals[index] = deals[i];
                index++;
            }
        }

        return pendingDeals;
    }
}
