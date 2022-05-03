// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

// Sleep token contract interface
import "./ISleepToken.sol";

// Timelock contract interface
import "./ITimelock.sol";

// Auth contract
import "./Auth.sol";

contract TokenStaking is Initializable, Auth, ReentrancyGuardUpgradeable {
    ISleepToken public sleepToken;
    ITimelock public timelock;

    uint256 public stakingDepositFee;
    uint256 public totalLockedFee;

    uint256 public minumumStakingAmount;
    uint256 public maximumStakingAmount;
    uint256 public maxStakingSlotsPerUser;

    uint256 public totalStakes;
    uint256 public totalUniqueStakers;
    mapping(address => bool) private uniqueStakers;

    uint256 public currentTokensStaked;
    uint256 public totalRewardTokensWithdrawn;
    uint256 public historicalTotalTokensStaked;

    struct StakeOption {
        bool isActive;
        uint256 IRMultiplier; // formula: 1/IR
        uint256 maturityPeriod;
        uint256 rewardInterval;
        uint256 postMaturityIRMultiplier; // formula: 1/IR
    }
    mapping(uint256 => StakeOption) public stakeOptions;

    enum StakeType {
        TOKEN,
        REWARD
    }
    struct Stake {
        StakeType stakeType;
        bool isRewardClaimed;
        uint256 maturityPeriod;
        uint256 runningPrincipal;
        uint256 runningStakeTime;
    }
    mapping(address => Stake[]) private stakes;

    event TokensStaked(
        address indexed staker,
        uint256 principal,
        uint256 indexed maturityPeriod
    );
    event TokensUnstaked(
        address indexed staker,
        uint256 principal,
        uint256 indexed maturityPeriod
    );
    event RewardsClaimed(address staker, uint256 claimedRewards);

    function initialize(ISleepToken _sleepToken, ITimelock _timelock)
        public
        initializer
    {
        __Auth_init(msg.sender);
        __ReentrancyGuard_init();

        stakingDepositFee = 0;

        minumumStakingAmount = 500 ether;
        maximumStakingAmount = type(uint256).max;
        maxStakingSlotsPerUser = 50;

        sleepToken = _sleepToken;
        timelock = _timelock;
    }

    function updateStakingDepositFee(uint256 _stakingDepositFee)
        external
        onlyOwner
    {
        stakingDepositFee = _stakingDepositFee;
    }

    function updateMinimumStakingAmount(uint256 _minumumStakingAmount)
        external
        onlyOwner
    {
        minumumStakingAmount = _minumumStakingAmount;
    }

    function updateMaximumStakingAmount(uint256 _maximumStakingAmount)
        external
        onlyOwner
    {
        maximumStakingAmount = _maximumStakingAmount;
    }

    function updateMaxStakingSlotsPerUser(uint256 _maxStakingSlotsPerUser)
        external
        onlyOwner
    {
        maxStakingSlotsPerUser = _maxStakingSlotsPerUser;
    }

    function updateStakingOption(StakeOption memory _stakingOption)
        external
        onlyOwner
    {
        require(
            _stakingOption.IRMultiplier <= 100,
            "Interest rate multiplier provided is invalid"
        );
        require(
            _stakingOption.postMaturityIRMultiplier <= 100,
            "Post maturity interest rate multiplier provided is invalid"
        );

        stakeOptions[_stakingOption.maturityPeriod] = _stakingOption;
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

    function totalUserStakedTokens(address _user)
        external
        view
        returns (uint256)
    {
        uint256 userStakedTokenCount;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            if (userStakes[i].stakeType == StakeType.TOKEN) {
                userStakedTokenCount += userStakes[i].runningPrincipal;
            }
        }

        return userStakedTokenCount;
    }

    function hasStakeBeenMature(Stake memory _stake)
        internal
        view
        returns (bool)
    {
        return
            _stake.stakeType == StakeType.TOKEN &&
            (_stake.runningStakeTime + _stake.maturityPeriod <=
                block.timestamp ||
                _stake.isRewardClaimed);
    }

    function totalUnstakableUserTokens(address _user)
        external
        view
        returns (uint256)
    {
        uint256 unstakableTokenCount;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            if (
                hasStakeBeenMature(userStakes[i]) ||
                timelock.getNumPendingAndReadyOperations() > 0
            ) {
                unstakableTokenCount += userStakes[i].runningPrincipal;
            }
        }

        return unstakableTokenCount;
    }

    function isMaturityPeriodValid(uint256 _maturityPeriod)
        public
        view
        returns (bool)
    {
        return stakeOptions[_maturityPeriod].maturityPeriod == _maturityPeriod;
    }

    function isStakeOptionActive(uint256 _maturityPeriod)
        public
        view
        returns (bool)
    {
        return stakeOptions[_maturityPeriod].isActive;
    }

    function totalUnstakableUserTokensByMaturityPeriod(
        address _user,
        uint256 _maturityPeriod
    ) public view returns (uint256) {
        require(
            isMaturityPeriodValid(_maturityPeriod),
            "Provided maturity period is invalid"
        );

        uint256 unstakableTokenCount;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            if (
                userStakes[i].maturityPeriod == _maturityPeriod &&
                (hasStakeBeenMature(userStakes[i]) ||
                    timelock.getNumPendingAndReadyOperations() > 0)
            ) {
                unstakableTokenCount += userStakes[i].runningPrincipal;
            }
        }

        return unstakableTokenCount;
    }

    function totalClaimableUserRewards(
        address _user,
        bool _considerMaturityPeriod
    ) external view returns (uint256) {
        uint256 claimableUserRewards;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            uint256 stakeReward = getStakeRewards(
                userStakes[i],
                _considerMaturityPeriod
            );

            claimableUserRewards += stakeReward;
            if (userStakes[i].stakeType == StakeType.REWARD) {
                claimableUserRewards += userStakes[i].runningPrincipal;
            }
        }

        return claimableUserRewards;
    }

    function totalClaimableUserRewardsByMaturityPeriod(
        address _user,
        uint256 _maturityPeriod,
        bool _considerMaturityPeriod
    ) external view returns (uint256) {
        uint256 claimableUserRewards;

        Stake[] memory userStakes = stakes[_user];
        for (uint256 i; i < userStakes.length; i++) {
            if (userStakes[i].maturityPeriod != _maturityPeriod) {
                continue;
            }

            uint256 stakeReward = getStakeRewards(
                userStakes[i],
                _considerMaturityPeriod
            );

            claimableUserRewards += stakeReward;
            if (userStakes[i].stakeType == StakeType.REWARD) {
                claimableUserRewards += userStakes[i].runningPrincipal;
            }
        }

        return claimableUserRewards;
    }

    function computeCompoundInterest(
        uint256 _principal,
        uint256 _interest,
        uint256 _periods
    ) internal pure returns (uint256) {
        require(_interest <= 100, "Interest rate provided is invalid");

        // Equivalent to 0% IR.
        if (_interest == 0) {
            return _principal;
        }

        uint256 precision = 8;
        if (_periods < 7) {
            precision = _periods + 1;
        }

        uint256 s = 0;
        uint256 N = 1;
        uint256 B = 1;
        for (uint256 i = 0; i < precision; ++i) {
            s += (_principal * N) / B / (_interest**i);
            N = N * (_periods - i);
            B = B * (i + 1);
        }

        return s;
    }

    function getStakeRewards(Stake memory _stake, bool _considerMaturityPeriod)
        public
        view
        returns (uint256)
    {
        require(
            isMaturityPeriodValid(_stake.maturityPeriod),
            "Provided maturity period is invalid"
        );

        if (
            _considerMaturityPeriod &&
            !hasStakeBeenMature(_stake) &&
            timelock.getNumPendingAndReadyOperations() == 0
        ) {
            return 0;
        }

        StakeOption memory stakeOption = stakeOptions[_stake.maturityPeriod];
        uint256 timeStaked = block.timestamp - _stake.runningStakeTime;
        uint256 maturityIntervals = _stake.maturityPeriod /
            stakeOption.rewardInterval;
        uint256 numIntervalsStaked = timeStaked / stakeOption.rewardInterval;

        uint256 completedMatureIntervals = numIntervalsStaked >=
            maturityIntervals
            ? maturityIntervals
            : numIntervalsStaked;
        uint256 completedPostMaturityIntervals = numIntervalsStaked -
            completedMatureIntervals;

        uint256 postMaturityPrincipal = _stake.runningPrincipal;

        if (_stake.stakeType == StakeType.TOKEN && !_stake.isRewardClaimed) {
            uint256 rewardInMaturity = computeCompoundInterest(
                _stake.runningPrincipal,
                stakeOption.IRMultiplier,
                completedMatureIntervals
            );
            postMaturityPrincipal = rewardInMaturity;
        } else {
            completedPostMaturityIntervals += completedMatureIntervals;
        }

        uint256 rewardPostMaturity = computeCompoundInterest(
            postMaturityPrincipal,
            stakeOption.postMaturityIRMultiplier,
            completedPostMaturityIntervals
        );

        uint256 totalReward = rewardPostMaturity - _stake.runningPrincipal;

        return totalReward;
    }

    function withdrawFee(uint256 _amountPercentage) external onlyOwner {
        uint256 amountToWithdraw = (totalLockedFee * _amountPercentage) / 100;
        totalLockedFee -= amountToWithdraw;
        require(
            sleepToken.transfer(msg.sender, amountToWithdraw),
            "transfer failed"
        );
    }

    function stakeTokens(uint256 _principal, uint256 _maturityPeriod)
        external
        nonReentrant
    {
        require(
            _principal >= minumumStakingAmount &&
                _principal <= maximumStakingAmount,
            "Stake amount should be within threshold"
        );

        require(
            userRemainingStakingSlots(msg.sender) > 0,
            "All staking slots have been used up"
        );

        require(
            isMaturityPeriodValid(_maturityPeriod),
            "Provided maturity period is invalid"
        );
        require(
            isStakeOptionActive(_maturityPeriod),
            "Provided stake option is inactive"
        );

        require(
            sleepToken.transferFrom(msg.sender, address(this), _principal),
            "transfer from failed"
        );
        uint256 feeAmount = (stakingDepositFee * _principal) / 100;
        totalLockedFee += feeAmount;
        uint256 feeAdjustedPrincipal = _principal - feeAmount;

        Stake memory newStake;
        newStake.stakeType = StakeType.TOKEN;
        newStake.maturityPeriod = _maturityPeriod;
        newStake.runningPrincipal = feeAdjustedPrincipal;
        newStake.runningStakeTime = block.timestamp;
        stakes[msg.sender].push(newStake);

        totalStakes += 1;
        currentTokensStaked += feeAdjustedPrincipal;
        historicalTotalTokensStaked += feeAdjustedPrincipal;

        if (!uniqueStakers[msg.sender]) {
            uniqueStakers[msg.sender] = true;
            totalUniqueStakers += 1;
        }

        emit TokensStaked(msg.sender, _principal, _maturityPeriod);
    }

    function unstakeTokens(uint256 _principal, uint256 _maturityPeriod)
        external
        nonReentrant
    {
        require(_principal > 0, "Unstaking principal has to be greater than 0");
        require(
            _principal <=
                totalUnstakableUserTokensByMaturityPeriod(
                    msg.sender,
                    _maturityPeriod
                ),
            "You can not unstake more tokens than have matured in a specific maturity period"
        );

        uint256 remainingUnstakedTokens = _principal;

        Stake[] storage userStakes = stakes[msg.sender];

        uint256 pendingStakesLen;
        Stake[] memory pendingStakes = new Stake[](userStakes.length);
        uint256 obsoleteStakesLen;
        uint256[] memory obsoleteStakes = new uint256[](userStakes.length);

        for (uint256 i; i < userStakes.length; i++) {
            if (remainingUnstakedTokens <= 0) {
                break;
            }

            if (
                userStakes[i].maturityPeriod == _maturityPeriod &&
                (hasStakeBeenMature(userStakes[i]) ||
                    timelock.getNumPendingAndReadyOperations() > 0)
            ) {
                uint256 tokensToWithdraw = (userStakes[i].runningPrincipal >=
                    remainingUnstakedTokens)
                    ? remainingUnstakedTokens
                    : userStakes[i].runningPrincipal;

                Stake memory stakeRewardQuery = userStakes[i];
                stakeRewardQuery.runningPrincipal = tokensToWithdraw;
                uint256 newRewardStakePrincipal = getStakeRewards(
                    stakeRewardQuery,
                    true
                );

                Stake memory newRewardStake;
                newRewardStake.stakeType = StakeType.REWARD;
                newRewardStake.runningStakeTime = block.timestamp;
                newRewardStake.runningPrincipal = newRewardStakePrincipal;
                newRewardStake.maturityPeriod = userStakes[i].maturityPeriod;
                pendingStakes[pendingStakesLen] = newRewardStake;
                pendingStakesLen += 1;

                if (tokensToWithdraw == userStakes[i].runningPrincipal) {
                    obsoleteStakes[obsoleteStakesLen] = i;
                    obsoleteStakesLen += 1;
                }
                if (tokensToWithdraw == remainingUnstakedTokens) {
                    userStakes[i].runningPrincipal -= remainingUnstakedTokens;
                }
                remainingUnstakedTokens -= tokensToWithdraw;
            }
        }

        require(
            remainingUnstakedTokens == 0,
            "Not enough unstakable tokens to fulfil request"
        );

        uint256 numRemoved;
        for (uint256 x; x < obsoleteStakesLen; x++) {
            removeUserStakingSlot(msg.sender, (obsoleteStakes[x] - numRemoved));
            numRemoved += 1;
        }

        for (uint256 y; y < pendingStakesLen; y++) {
            stakes[msg.sender].push(pendingStakes[y]);
        }

        currentTokensStaked -= _principal;

        require(sleepToken.transfer(msg.sender, _principal), "transfer failed");

        emit TokensUnstaked(msg.sender, _principal, _maturityPeriod);
    }

    function claimRewardsByMaturityPeriod(uint256 _maturityPeriod)
        external
        nonReentrant
    {
        uint256 userRewardCount;

        Stake[] storage userStakes = stakes[msg.sender];

        uint256 obsoleteStakesLen;
        uint256[] memory obsoleteStakes = new uint256[](userStakes.length);

        for (uint256 i; i < userStakes.length; i++) {
            if (userStakes[i].maturityPeriod != _maturityPeriod) {
                continue;
            }

            uint256 stakeReward = getStakeRewards(userStakes[i], true);

            if (userStakes[i].stakeType == StakeType.REWARD) {
                userRewardCount += stakeReward + userStakes[i].runningPrincipal;
                obsoleteStakes[obsoleteStakesLen] = i;
                obsoleteStakesLen += 1;
            } else {
                if (
                    hasStakeBeenMature(userStakes[i]) ||
                    timelock.getNumPendingAndReadyOperations() > 0
                ) {
                    userStakes[i].isRewardClaimed = true;
                    userStakes[i].runningStakeTime = block.timestamp;
                    userRewardCount += stakeReward;
                }
            }
        }

        uint256 numRemoved;
        for (uint256 x; x < obsoleteStakesLen; x++) {
            removeUserStakingSlot(msg.sender, (obsoleteStakes[x] - numRemoved));
            numRemoved += 1;
        }

        totalRewardTokensWithdrawn += userRewardCount;

        sleepToken.mintRewards(msg.sender, userRewardCount);

        emit RewardsClaimed(msg.sender, userRewardCount);
    }

    function claimRewards() external nonReentrant {
        uint256 userRewardCount;

        Stake[] storage userStakes = stakes[msg.sender];

        uint256 obsoleteStakesLen;
        uint256[] memory obsoleteStakes = new uint256[](userStakes.length);

        for (uint256 i; i < userStakes.length; i++) {
            uint256 stakeReward = getStakeRewards(userStakes[i], true);

            if (userStakes[i].stakeType == StakeType.REWARD) {
                userRewardCount += stakeReward + userStakes[i].runningPrincipal;
                obsoleteStakes[obsoleteStakesLen] = i;
                obsoleteStakesLen += 1;
            } else {
                if (
                    hasStakeBeenMature(userStakes[i]) ||
                    timelock.getNumPendingAndReadyOperations() > 0
                ) {
                    userStakes[i].isRewardClaimed = true;
                    userStakes[i].runningStakeTime = block.timestamp;
                    userRewardCount += stakeReward;
                }
            }
        }

        uint256 numRemoved;
        for (uint256 x; x < obsoleteStakesLen; x++) {
            removeUserStakingSlot(msg.sender, (obsoleteStakes[x] - numRemoved));
            numRemoved += 1;
        }

        totalRewardTokensWithdrawn += userRewardCount;

        sleepToken.mintRewards(msg.sender, userRewardCount);

        emit RewardsClaimed(msg.sender, userRewardCount);
    }
}
