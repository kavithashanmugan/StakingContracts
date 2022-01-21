// SPDX-License-Identifier: GPL-3.0

pragma solidity ^0.8.1;
pragma abicoder v2;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/utils/SafeERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/Math.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";


interface IMintableToken is IERC20 {
    function mint(address _receiver, uint256 _amount) external;
}

contract XTenfiStaker is ReentrancyGuard, Ownable {
 using SafeMath for uint256;
    using SafeERC20 for IERC20;
    using SafeERC20 for IMintableToken;

    /* ========== STATE VARIABLES ========== */

    struct Reward {
        uint256 periodFinish;
        uint256 rewardRate;
        uint256 lastUpdateTime;
        uint256 rewardPerTokenStored;
    }
    struct Balances {
        uint256 total;
        uint256 unlocked;
    }
    
    struct RewardData {
        address token;
        uint256 amount;
    }

    IMintableToken public immutable stakingToken;

        // Duration that rewards are streamed over
    uint256 public constant rewardsDuration = 60;

    // Duration of lock/earned penalty period
    uint256 public constant lockDuration = rewardsDuration * 2;

    address[] public rewardTokens;
    mapping(address => Reward) public rewardData;

    // Addresses approved to call mint
    mapping(address => bool) public minters;
    // reward token -> distributor -> is approved to add rewards
    mapping(address=> mapping(address => bool)) public rewardDistributors;

    // user -> reward token -> amount
    mapping(address => mapping(address => uint256)) public userRewardPerTokenPaid;
    mapping(address => mapping(address => uint256)) public rewards;

    uint256 public totalSupply;

    // Private mappings for balance data
    mapping(address => Balances) private balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingToken,
        address[] memory _minters
    ) Ownable() {
        stakingToken = IMintableToken(_stakingToken);
        for (uint i; i < _minters.length; i++) {
            minters[_minters[i]] = true;
        }
        // First reward MUST be the staking token or things will break
        // related to the 50% penalty and distribution to locked balances
        rewardTokens.push(_stakingToken);
        rewardData[_stakingToken].lastUpdateTime = block.timestamp;
        rewardData[_stakingToken].periodFinish = block.timestamp;
    }

     /* ========== ADMIN CONFIGURATION ========== */


    // Modify approval for an address to call notifyRewardAmount
    function approveRewardDistributor(
        address _rewardsToken,
        address _distributor,
        bool _approved
    ) external onlyOwner {
        require(rewardData[_rewardsToken].lastUpdateTime > 0);
        rewardDistributors[_rewardsToken][_distributor] = _approved;
    }

    /* ========== VIEWS ========== */

    function _rewardPerToken(address _rewardsToken, uint256 _supply) internal view returns (uint256) {
        if (_supply == 0) {
            return rewardData[_rewardsToken].rewardPerTokenStored;
        }
        return
            rewardData[_rewardsToken].rewardPerTokenStored.add(
                lastTimeRewardApplicable(_rewardsToken).sub(
                    rewardData[_rewardsToken].lastUpdateTime).mul(
                        rewardData[_rewardsToken].rewardRate).mul(1e18).div(_supply)
            );
    }

     function _earned(
        address _user,
        address _rewardsToken,
        uint256 _balance,
        uint256 supply
    ) internal view returns (uint256) {
        return _balance.mul(
            _rewardPerToken(_rewardsToken, supply).sub(userRewardPerTokenPaid[_user][_rewardsToken])
        ).div(1e18).add(rewards[_user][_rewardsToken]);
    }

    function lastTimeRewardApplicable(address _rewardsToken) public view returns (uint256) {
        return Math.min(block.timestamp, rewardData[_rewardsToken].periodFinish);
    }

    function rewardPerToken(address _rewardsToken) external view returns (uint256) {
        uint256 supply = totalSupply;
        return _rewardPerToken(_rewardsToken, supply);

    }

    function getRewardForDuration(address _rewardsToken) external view returns (uint256) {
        return rewardData[_rewardsToken].rewardRate.mul(rewardsDuration);
    }

     // Address and claimable amount of all reward tokens for the given account
    function claimableRewards(address account) external view returns (RewardData[] memory rewards) {
        rewards = new RewardData[](rewardTokens.length);
        for (uint256 i = 0; i < rewards.length; i++) {
            // If i == 0 this is the stakingReward, distribution is based on locked balances
            uint256 balance =  balances[account].total;
            uint256 supply =  totalSupply;
            rewards[i].token = rewardTokens[i];
            rewards[i].amount = _earned(account, rewards[i].token, balance, supply);
        }
        return rewards;
    }
// Total balance of an account, including unlocked, locked and earned tokens
    function totalBalance(address user) view external returns (uint256 amount) {
        return balances[user].total;
    }

    
     // Final balance received and penalty balance paid by user upon calling exit
    function withdrawableBalance(
        address user
    ) view public returns (
        uint256 amount
    ) {
        Balances storage bal = balances[user];
        amount = bal.unlocked;
        return (amount);
    }
    /* ========== MUTATIVE FUNCTIONS ========== */

    // Stake tokens to receive rewards
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        totalSupply = totalSupply.add(amount);
        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.add(amount);
        bal.unlocked = bal.unlocked.add(amount);
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

      // Claim all pending staking rewards
    function getReward() public nonReentrant updateReward(msg.sender) {
        for (uint i; i < rewardTokens.length; i++) {
            address _rewardsToken = rewardTokens[i];
            uint256 reward = rewards[msg.sender][_rewardsToken];
            if (reward > 0) {
                rewards[msg.sender][_rewardsToken] = 0;
                IERC20(_rewardsToken).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, _rewardsToken, reward);
            }
        }
    }

    // Withdraw full unlocked balance and claim pending rewards
    function exit() external updateReward(msg.sender) {
        (uint256 amount) = withdrawableBalance(msg.sender);
        Balances storage bal = balances[msg.sender];
        bal.total = bal.total.sub(bal.unlocked);
        bal.unlocked = 0;
        totalSupply = totalSupply.sub(amount);
        stakingToken.safeTransfer(msg.sender, amount);
        getReward();
    }





 /* ========== RESTRICTED FUNCTIONS ========== */

    function _notifyReward(address _rewardsToken, uint256 reward) internal {
        if (block.timestamp >= rewardData[_rewardsToken].periodFinish) {
            rewardData[_rewardsToken].rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = rewardData[_rewardsToken].periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardData[_rewardsToken].rewardRate);
            rewardData[_rewardsToken].rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        rewardData[_rewardsToken].lastUpdateTime = block.timestamp;
        rewardData[_rewardsToken].periodFinish = block.timestamp.add(rewardsDuration);

    }

    function notifyRewardAmount(address _rewardsToken, uint256 reward) external updateReward(address(0)) {
        require(rewardDistributors[_rewardsToken][msg.sender]);
        require(reward > 0, "No reward");
        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        IERC20(_rewardsToken).safeTransferFrom(msg.sender, address(this), reward);
        _notifyReward(_rewardsToken, reward);
        emit RewardAdded(reward);
    }

    // Added to support recovering LP Rewards from other systems such as BAL to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        require(tokenAddress != address(stakingToken), "Cannot withdraw staking token");
        require(rewardData[tokenAddress].lastUpdateTime == 0, "Cannot withdraw reward token");
        IERC20(tokenAddress).safeTransfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }


     /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        address token = address(stakingToken);
        uint256 balance;
        uint256 supply = totalSupply;
        for (uint i = 1; i < rewardTokens.length; i++) {
            token = rewardTokens[i];
            rewardData[token].rewardPerTokenStored = _rewardPerToken(token, supply);
            rewardData[token].lastUpdateTime = lastTimeRewardApplicable(token);
            if (account != address(0)) {
                rewards[account][token] = _earned(account, token, balance, supply);
                userRewardPerTokenPaid[account][token] = rewardData[token].rewardPerTokenStored;
            }
        }
        _;
    }

     /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, address indexed rewardsToken, uint256 reward);
    event RewardsDurationUpdated(address token, uint256 newDuration);
    event Recovered(address token, uint256 amount);

}
