// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";

// Sleep token contract interface
import "./ISleepToken.sol";

// Sleep NFT contract interface
import "./ISleepNFT.sol";

// Timelock contract interface
import "./ITimelock.sol";

// Auth contract
import "./Auth.sol";

contract NFTStaking is
    Initializable,
    Auth,
    ReentrancyGuardUpgradeable,
    IERC721ReceiverUpgradeable
{
    using CountersUpgradeable for CountersUpgradeable.Counter;

    ISleepToken public sleepToken;
    ISleepNFT public sleepNFT;
    ITimelock public timelock;

    uint256 public stakingDepositFee;
    uint256 public totalLockedFee;

    uint256 public maxStakingSlotsPerUser;

    uint256 public lockPeriod;

    uint256 public totalStakes;
    uint256 public totalUniqueStakers;
    mapping(address => bool) private uniqueStakers;

    uint256 public currentTokensStaked;
    uint256 public totalRewardTokensWithdrawn;
    uint256 public historicalTotalTokensStaked;

    struct StakeOption {
        bool isActive;
        uint256 rewardInterval;
        uint256 multiplierGods;
        uint256 multiplierKings;
        uint256 multiplierGoats;
    }
    CountersUpgradeable.Counter private numStakeOptions;
    mapping(uint256 => StakeOption) private stakeOptions;

    struct Stake {
        uint256 tokenID;
        bool isTokenStaked;
        uint256 unstakeTime;
        bool isRewardClaimed;
        uint256 stakeOptionID;
        uint256 runningStakeTime;
    }
    mapping(address => Stake[]) private stakes;

    event TokenStaked(address staker, uint256 tokenID, uint256 stakeOptionID);
    event TokenUnstaked(address staker, uint256 tokenID, uint256 stakeOptionID);
    event RewardsClaimed(address staker, uint256 claimedRewards);

    function initialize(
        ISleepToken _sleepToken,
        ISleepNFT _sleepNFT,
        ITimelock _timelock
    ) public initializer {
        __Auth_init(msg.sender);
        __ReentrancyGuard_init();

        stakingDepositFee = 0;
        maxStakingSlotsPerUser = 50;
        lockPeriod = 60 * 60;

        sleepToken = _sleepToken;
        sleepNFT = _sleepNFT;
        timelock = _timelock;
    }

    function updateStakingDepositFee(uint256 _stakingDepositFee)
        external
        onlyOwner
    {
        stakingDepositFee = _stakingDepositFee;
    }

    function updateMaxStakingSlotsPerUser(uint256 _maxStakingSlotsPerUser)
        external
        onlyOwner
    {
        maxStakingSlotsPerUser = _maxStakingSlotsPerUser;
    }

    function updateLockPeriod(uint256 _lockPeriod) external onlyOwner {
        lockPeriod = _lockPeriod;
    }

    function updateStakingOption(StakeOption memory _stakingOption)
        external
        onlyOwner
    {
        numStakeOptions.increment();
        stakeOptions[numStakeOptions.current()] = _stakingOption;
    }

    function getStakeOption(uint256 _stakeOptionID)
        external
        view
        returns (StakeOption memory)
    {
        return stakeOptions[_stakeOptionID];
    }

    function isStakeOptionActive(uint256 _stakeOptionID)
        public
        view
        returns (bool)
    {
        return stakeOptions[_stakeOptionID].isActive;
    }

    function userRemainingStakingSlots(address _user)
        public
        view
        returns (uint256)
    {
        uint256 usedStakingSlots = stakes[_user].length;

        if (usedStakingSlots >= maxStakingSlotsPerUser) {
            return 0;
        }

        return maxStakingSlotsPerUser - usedStakingSlots;
    }

    function totalClaimableRewards(address _user)
        external
        view
        returns (uint256)
    {
        uint256 numRewardTokens;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            uint256 elapsedTime = block.timestamp -
                userStakes[i].runningStakeTime;
            if (
                !userStakes[i].isRewardClaimed &&
                elapsedTime < lockPeriod &&
                timelock.getNumPendingAndReadyOperations() == 0
            ) {
                continue;
            }

            uint256 stakeEndTime = userStakes[i].isTokenStaked
                ? block.timestamp
                : userStakes[i].unstakeTime;
            uint256 stakeDuration = stakeEndTime >=
                userStakes[i].runningStakeTime
                ? stakeEndTime - userStakes[i].runningStakeTime
                : 0;

            StakeOption memory stakeOption = stakeOptions[
                userStakes[i].stakeOptionID
            ];

            uint256 multiplier = stakeOption.multiplierKings;
            if (sleepNFT.tokenType(userStakes[i].tokenID) == 1) {
                multiplier = stakeOption.multiplierGods;
            } else if (sleepNFT.tokenType(userStakes[i].tokenID) == 0) {
                multiplier = stakeOption.multiplierGoats;
            }

            numRewardTokens +=
                (stakeDuration * multiplier) /
                stakeOption.rewardInterval;
        }

        return numRewardTokens;
    }

    function withdrawFee(uint256 _amountPercentage) external onlyOwner {
        uint256 amountToWithdraw = (totalLockedFee * _amountPercentage) / 100;
        totalLockedFee -= amountToWithdraw;
        require(
            sleepToken.transfer(msg.sender, amountToWithdraw),
            "transfer failed"
        );
    }

    function isTokenActivelyStaked(address _user, uint256 _tokenID)
        internal
        view
        returns (bool isActivelyStaked, uint256 stakeIndex)
    {
        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            if (
                userStakes[i].tokenID == _tokenID && userStakes[i].isTokenStaked
            ) {
                return (true, i);
            }
        }

        return (false, 0);
    }

    function removeUserStakingSlot(address _user, uint256 _index) internal {
        Stake[] storage userStakes = stakes[_user];

        require(
            _index < userStakes.length,
            "Cannot remove user staking slot beyond index length"
        );

        for (uint256 i = _index; i < userStakes.length - 1; i++) {
            userStakes[i] = userStakes[i + 1];
        }
        userStakes.pop();
    }

    function shouldStakeBeDeleted(address _user, uint256 _stakeIndex)
        internal
        view
        returns (bool)
    {
        Stake memory stake = stakes[_user][_stakeIndex];

        if (stake.isTokenStaked) {
            return false;
        }

        uint256 stakeDuration = stake.unstakeTime >= stake.runningStakeTime
            ? stake.unstakeTime - stake.runningStakeTime
            : 0;
        if (stakeDuration < stakeOptions[stake.stakeOptionID].rewardInterval) {
            return true;
        }

        return false;
    }

    function stakeNFT(uint256 _tokenID, uint256 _stakeOptionID)
        external
        nonReentrant
    {
        require(
            userRemainingStakingSlots(msg.sender) > 0,
            "All staking slots have been used up"
        );
        require(
            isStakeOptionActive(_stakeOptionID),
            "Provided stake option is inactive"
        );

        require(
            sleepToken.transferFrom(
                msg.sender,
                address(this),
                stakingDepositFee
            ),
            "transfer from failed"
        );
        totalLockedFee += stakingDepositFee;
        sleepNFT.safeTransferFrom(msg.sender, address(this), _tokenID);

        Stake memory newStake;
        newStake.tokenID = _tokenID;
        newStake.isTokenStaked = true;
        newStake.stakeOptionID = _stakeOptionID;
        newStake.runningStakeTime = block.timestamp;
        stakes[msg.sender].push(newStake);

        totalStakes += 1;
        currentTokensStaked += 1;
        historicalTotalTokensStaked += 1;

        if (!uniqueStakers[msg.sender]) {
            uniqueStakers[msg.sender] = true;
            totalUniqueStakers += 1;
        }

        emit TokenStaked(msg.sender, _tokenID, _stakeOptionID);
    }

    function unstakeNFT(uint256 _tokenID) external nonReentrant {
        (bool isActivelyStaked, uint256 stakeIndex) = isTokenActivelyStaked(
            msg.sender,
            _tokenID
        );
        require(isActivelyStaked, "Token provided must be actively staked");

        Stake storage stake = stakes[msg.sender][stakeIndex];

        bool canUnstake = true;
        uint256 elapsedTime = block.timestamp - stake.runningStakeTime;
        if (
            !stake.isRewardClaimed &&
            elapsedTime < lockPeriod &&
            timelock.getNumPendingAndReadyOperations() == 0
        ) {
            canUnstake = false;
        }
        require(
            canUnstake,
            "Token must be staked for more than the lock period"
        );

        stake.isTokenStaked = false;
        stake.unstakeTime = block.timestamp;
        if (shouldStakeBeDeleted(msg.sender, stakeIndex)) {
            removeUserStakingSlot(msg.sender, stakeIndex);
        }
        sleepNFT.safeTransferFrom(address(this), msg.sender, _tokenID);

        emit TokenUnstaked(msg.sender, _tokenID, stake.stakeOptionID);
    }

    function claimRewards() external nonReentrant {
        uint256 numRewardTokens;

        Stake[] storage userStakes = stakes[msg.sender];

        uint256 obsoleteStakesLen;
        uint256[] memory obsoleteStakes = new uint256[](userStakes.length);

        for (uint256 i; i < userStakes.length; i++) {
            uint256 elapsedTime = block.timestamp -
                userStakes[i].runningStakeTime;
            if (
                !userStakes[i].isRewardClaimed &&
                elapsedTime < lockPeriod &&
                timelock.getNumPendingAndReadyOperations() == 0
            ) {
                continue;
            }

            uint256 stakeEndTime = userStakes[i].isTokenStaked
                ? block.timestamp
                : userStakes[i].unstakeTime;
            uint256 stakeDuration = stakeEndTime >=
                userStakes[i].runningStakeTime
                ? stakeEndTime - userStakes[i].runningStakeTime
                : 0;

            StakeOption memory stakeOption = stakeOptions[
                userStakes[i].stakeOptionID
            ];

            uint256 multiplier = stakeOption.multiplierKings;
            if (sleepNFT.tokenType(userStakes[i].tokenID) == 1) {
                multiplier = stakeOption.multiplierGods;
            } else if (sleepNFT.tokenType(userStakes[i].tokenID) == 0) {
                multiplier = stakeOption.multiplierGoats;
            }

            numRewardTokens +=
                (stakeDuration * multiplier) /
                stakeOption.rewardInterval;

            userStakes[i].runningStakeTime = block.timestamp;
            userStakes[i].isRewardClaimed = true;

            if (shouldStakeBeDeleted(msg.sender, i)) {
                obsoleteStakes[obsoleteStakesLen] = i;
                obsoleteStakesLen += 1;
            }
        }

        uint256 numRemoved;
        for (uint256 x; x < obsoleteStakesLen; x++) {
            removeUserStakingSlot(msg.sender, (obsoleteStakes[x] - numRemoved));
            numRemoved += 1;
        }

        sleepToken.mintRewards(msg.sender, numRewardTokens);

        emit RewardsClaimed(msg.sender, numRewardTokens);
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes memory
    ) public virtual override returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
