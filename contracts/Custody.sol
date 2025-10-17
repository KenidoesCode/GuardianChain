// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";


contract Custody is Ownable, ERC1155Holder, ReentrancyGuard, Pausable{

    struct Asset{
        address tokenAddress;
        uint256 tokenId;
        uint256 amount;
        address depositor;
        bool inCustody;
        bool isETH;
        bool isERC1155;
    }

    mapping(uint256 => Asset)public assets;
    uint256 public assetCounter;

    //Guardians list

    mapping(address => bool)public isGuardian;
    address[] public guardianList;
    uint256 public guardianCount;
    uint256 public requiredApprovals;

    //Emergency unlock request

    mapping(uint256 => mapping(address => bool ))public emergencyApprovals;
    mapping(uint256 => uint256)public approvalCount;
    mapping(uint256 => bool)public unlockRequested;

    //per-user guardian and thresholds

    mapping(address => address[]) public guardians;
    mapping(address => uint256) public thresholds;

    //timelock settings

    uint256 public timelockDuration = 1 days;
    mapping(uint256 => uint256 ) public unlockRequestedAt;

    //KYC verification

    mapping(address => bool) public isKYCApproved;

    //Collateralised Lending

    mapping(uint256 => uint256) public depositTimestamp;

    // withdrawInterst

    uint256 public interestRate = 5e14;

    event InterestWithdrawn(uint256 assetId,address depositor, uint256 interest);

    receive() external payable{

    }


    constructor(){
        assetCounter=0;
    } 

    event AssetDeposited(uint256 assetId,address depositor);
    event AssetReleased(uint256 assetId,address receiver);
    event EmergencyUnlockRequested(uint256 assetId,address requester);
    event EmergencyUnlockApproved(uint256 assetId,address guardian);
    event EmergencyUnlockExecuted(uint256 assetId,address receiver);

    function addGuardian(address _guardian) external onlyOwner{
        require(!isGuardian[_guardian],"Already a Guardian");
        isGuardian[_guardian]=true;
        guardianList.push(_guardian);
        guardianCount++;
    }

    function removeGuardian(address _guardian)external onlyOwner{
        require(isGuardian[_guardian],"Not a guardian");
        isGuardian[_guardian]=false;
        guardianCount--;
    }

    function setRequiredApprovals(uint256 _required)external onlyOwner{
        require(_required <= guardianCount,"Too many Approvals");
        requiredApprovals = _required;
    }

    function depositERC20(address token,uint256 amount)external{
        require(amount>0,"Amount must be greater than 0");

        IERC20(token).transferFrom(msg.sender,address(this),amount);

        assets[assetCounter] = Asset({
            tokenAddress: token,
            tokenId: 0,
            amount: amount,
            depositor: msg.sender,
            inCustody: true,
            isETH: false,
            isERC1155: false
        });

        emit AssetDeposited(assetCounter, msg.sender);
        assetCounter++;
    }

    function depositERC721(address token,uint256 tokenId)external{
        IERC721(token).transferFrom(msg.sender,address(this),tokenId);

        assets[assetCounter]=Asset({
            tokenAddress: token,
            tokenId: tokenId,
            amount: 0,
            depositor: msg.sender,
            inCustody: true,
            isETH: false,
            isERC1155: false
        });

        emit AssetDeposited(assetCounter, msg.sender);
        assetCounter++;

    }

    function depositETH() external payable{
        require(msg.value > 0,"Must send ETH");

        assets[assetCounter]=Asset({
            tokenAddress: address(0),
            tokenId: 0,
            amount: msg.value,
            depositor: msg.sender,
            inCustody: true,
            isETH: true,
            isERC1155: false
        });

        emit AssetDeposited(assetCounter, msg.sender);
        assetCounter++;
    }

    function depositERC1155(address Token, uint256 tokenId,uint256 amount) external {
        require(amount > 0 ,"Amount must be greater than Zero");

        IERC1155(token).safeTransferFrom(msg.sender,address(this),tokenId,amount,"");

         assets[assetCounter]=Asset({
            tokenAddress: Token,
            tokenId: tokenId,
            amount: amount,
            depositor: msg.sender,
            inCustody: true,
            isETH: false,
            isERC1155: true
        });

        emit AssetDeposited(assetCounter, msg.sender);
        assetCounter++;

    }

    function withdrawAsset(uint256 assetId)external{
        Asset storage asset=assets[assetId];

        require(asset.depositor != address(0), "Asset does not exist");
        require(asset.inCustody,"Asset not in custody");
        require(asset.depositor==msg.sender,"Not the depositor");

        if(asset.isETH){
            payable(asset.depositor).transfer(asset.amount);
        }
        else if(asset.isERC1155){
            IERC1155(asset.tokenAddress).safeTransferFrom(
                address(this),
                asset.depositor,
                asset.tokenId,
                asset.amount,
                ""
            );
        }

        else if(asset.amount>0){
            IERC20(asset.tokenAddress).transfer(asset.depositor,asset.amount);
        }else{
            IERC721(asset.tokenAddress).transferFrom(address(this),asset.depositor,asset.tokenId);
        }

        asset.inCustody=false;
        emit AssetReleased(assetId, msg.sender);
    }

    function requestEmergencyUnlock(uint256 assetId) external {
        Asset storage asset = assets[assetId];
        require(msg.sender==asset.depositor,"Only the depositor can do this task");
        require(asset.inCustody,"Asset not in Custody");

        unlockRequested[assetId]=true;
        unlockRequestedAt[assetId]=block.timestamp;

        emit EmergencyUnlockRequested(assetId, msg.sender);
        }

    function approveEmergencyUnlock(uint256 assetId)external {
        Asset storage asset = assets[assetId];
        address depositor = asset.depositor;

        require(isGuardian[msg.sender],"Only guardians can approve");
        require(unlockRequested[assetId],"Unlock not approved");
        require(!emergencyApprovals[assetId][msg.sender],"Already approved");

        emergencyApprovals[assetId][msg.sender]=true;

        approvalCount[assetId]++;

        emit EmergencyUnlockApproved(assetId, msg.sender);
    }

    function executeEmergencyUnlock(uint256 assetId) external {
    Asset storage asset = assets[assetId];
    address depositor = asset.depositor;

    require(msg.sender == asset.depositor, "Only depositor can execute");
    require(unlockRequested[assetId], "Unlock not requested");
    require(approvalCount[assetId] >= requiredApprovals, "Not enough approvals");
    require(block.timestamp >= unlockRequestedAt[assetId] + timelockDuration,"TImelock not expired");

    if(asset.isETH){
        payable(asset.depositor).transfer(asset.amount);
    }
    else if(asset.isERC1155){
        IERC1155(asset.tokenAddress).safeTransferFrom(
            address(this),
            asset.depositor,
            asset.tokenId,
            asset.amount,
            ""
        );
    }
    else if(asset.amount > 0){
        IERC20(asset.tokenAddress).transfer(asset.depositor, asset.amount);
    } else {
        IERC721(asset.tokenAddress).transferFrom(address(this), asset.depositor, asset.tokenId);
    }

    asset.inCustody=false;

    unlockRequested[assetId]= false;
    approvalCount[assetId]=0;

    emit EmergencyUnlockExecuted(assetId,msg.sender);


}

function isGuardianOf(address user,address guardian)public view returns(bool){
    address[] memory gList = guardians[user];
    for(uint256 i=0;i<gList.length;i++){
        if(gList[i] == guardian){
            return true;
        }
    }
    return false;
}

function setGuardians(address[] calldata _guardians, uint256 _threshold) external{
    require(_guardians.length > 0,"Must have guardians" );
    require(_threshold > 0 && _threshold <= _guardians.length, "Invalid threshold");

    guardians[msg.sender] = _guardians;
    thresholds[msg.sender] = _threshold;
}

function setTimelockDuraton(uint256 _duration)external onlyOwner{
    timelockDuration = _duration;
}

function approvedKYC(address user) external onlyOwner {
    isKYCApproved[user] =true;
}

function depositETH() external payable{
    require(msg.value > 0,"Deposit must be greater 0 ");

    assets[assetCounter] = Asset({
        owner: msg.sender,
        amount: msg.value
    });

    depositTimestamp[assetCounter] = block.timestamp;
    assetCounter++;
 
}

function calculateInterest(uint256 assetId) public view returns(uint256) {
    Asset storage asset = assets[assetId];
    require(asset.amount > 0,"Asset does not exist");

    uint256 duration = block.timestamp - depositTimestamp[assetId];
    uint256 interest = (asset.amount * duration * interestRate) / 1e18;

    return interest; 
}

function withdrawInterest(uint256 assetId)external nonReentrant{
    Asset storage asset = assets[assetId];

    require(asset.depositor == msg.sender,"Not the depositor");
    require(asset.inCustody,"Asset not in custody");
    require(asset.amount > 0,"No deposit to earn interest");

    uint256 interest = calculateInterest(assetId);
    require(interest > 0,"No interest available");

    payable(asset.depositor).transfer(interest);

    depositTimestamp[assetId] = block.timestamp;

    emit InterestWithdrawn(assetId, msg.sender, interest);
}

function setInterestRate(uint256 _rate)external onlyOwner{
    require(_rate > 0,"Rate must be positive");
    interestRate = _rate;
}
}