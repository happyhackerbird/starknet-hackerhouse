// SPDX-License-Identifier: UNLICENSED
pragma solidity >0.8.0;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title VotingEscrow
 * @dev VotingEscrow is a non standard ERC20token $veGREEN used to represent the voting power of a user. Users lock $GREEN to obtain $veGREEN. Voting power decreases linearly from the moment of locking.
 * Based on https://github.com/curvefi/curve-dao-contracts/blob/master/doc/README.md
 * Voting weight is equal to w = amount *  t / t_max , so it is dependent on both the locked amount as well as the time locked.
 *
 */
contract VotingEscrow is ERC20 {
    using SafeERC20 for ERC20;

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 locktime,
        LockAction indexed action,
        uint256 ts
    );

    // Shared global state
    address public immutable GREEN;
    uint256 public constant WEEK = 7 days;
    uint256 public constant MAXTIME = 4 * 365 days * 86400;
    int128 internal constant iMAXTIME = 4 * 365 * 86400;

    uint256 public constant MULTIPLIER = 10 ** 18;
    // address public blocklist
    address public owner;
    // Smart contract addresses which are allowed to deposit
    // One wants to prevent the veGREEN from being tokenized
    mapping(address => bool) public whitelist;

    // Lock state
    uint256 public globalEpoch;
    Point[1000000000000000000] public pointHistory; // 1e9 * userPointHistory-length, so sufficient for 1e9 users
    mapping(address => Point[1000000000]) public userPointHistory;
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int128) public slopeChanges;
    mapping(address => LockedBalance) public lockedBalances;

    // Structs
    struct Point {
        int128 bias;
        int128 slope;
        uint256 ts;
        uint256 blk;
    }

    struct LockedBalance {
        int128 amount;
        uint end;
    }

    enum LockAction {
        CREATE_LOCK
        // INCREASE_LOCK_AMOUNT,
        // INCREASE_LOCK_TIME
    }

    constructor(address greenToken) ERC20("Vote-Escrow GREEN", "veGREEN") {
        GREEN = greenToken;
        pointHistory[0] = Point({
            bias: int128(0),
            slope: int128(0),
            ts: block.timestamp,
            blk: block.number
        });
        owner = msg.sender;
    }

    // function addToWhitelist(address addr) external onlyOwner {
    //     whitelist[addr] = true;
    // }

    // function removeFromWhitelist(address addr) external onlyOwner {
    //     whitelist[addr] = false;
    // }

    /**************************Modifiers************************************/

    modifier onlyOwner() {
        require(msg.sender == owner, "only owner can call");
        _;
    }

    /**
     * @dev Validates that the user has an expired lock && they still have capacity to earn
     * @param _addr User address to check
     */
    modifier lockupIsOver(address _addr) {
        LockedBalance memory userLock = lockedBalances[_addr];
        require(
            userLock.amount > 0 && block.timestamp >= userLock.end,
            "Users lock didn't expire"
        );
        // require(staticBalanceOf(_addr) > 0, "User must have existing bias");
        _;
    }

    /**************************Getters************************************/

    /**
     * @dev Gets the last available user point
     * @param _addr User address
     * @return bias i.e. y
     * @return slope i.e. linear gradient
     * @return ts i.e. time point was logged
     */
    function getLastUserPoint(
        address _addr
    ) external view returns (int128 bias, int128 slope, uint256 ts) {
        uint256 uepoch = userPointEpoch[_addr];
        if (uepoch == 0) {
            return (0, 0, 0);
        }
        Point memory point = userPointHistory[_addr][uepoch];
        return (point.bias, point.slope, point.ts);
    }

    /**************************Lockup************************************/

    /**
     * @dev Deposits or creates a stake for a given address
     * @param _addr User address to assign the stake
     * @param _value Total units of StakingToken to lockup
     * @param _unlockTime Time at which the stake should unlock
     * @param _Locked Previous amount staked by this user
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance memory _Locked,
        LockAction _action
    ) internal {
        LockedBalance memory newLocked = LockedBalance({
            amount: _Locked.amount,
            end: _Locked.end
        });

        // Later we will add the possibility to modify existing locks
        newLocked.amount = newLocked.amount + SafeCast.toInt128(int256(_value));
        if (_unlockTime != 0) {
            newLocked.end = _unlockTime;
        }
        // store updated lock for user
        lockedBalances[_addr] = newLocked;

        // Possibilities:
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // newLocked.end > block.timestamp
        _checkpoint(_addr, _Locked, newLocked);

        if (_value != 0) {
            ERC20(GREEN).safeTransferFrom(_addr, address(this), _value);
        }
        emit Deposit(_addr, _value, newLocked.end, _action, block.timestamp);
    }

    /**
     * @dev Records a checkpoint of both individual and global slope
     * @param _addr User address, or address(0) for only global
     * @param _oldLocked Old amount that user had locked, or null for global
     * @param _newLocked new amount that user has locked, or null for global
     */
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory userOldPoint;
        Point memory userNewPoint;
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;
        uint256 _epoch = globalEpoch;

        if (_addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                userOldPoint.slope = _oldLocked.amount / iMAXTIME;
                userOldPoint.bias =
                    userOldPoint.slope *
                    int128(int(_oldLocked.end - block.timestamp));
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                userNewPoint.slope = _newLocked.amount / iMAXTIME;
                userNewPoint.bias =
                    userNewPoint.slope *
                    int128(int(_newLocked.end - block.timestamp));
            }

            // Read values of scheduled changes in the slope
            // _oldLocked.end can be in the past and in the future
            // _newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldSlopeDelta = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    newSlopeDelta = oldSlopeDelta;
                } else {
                    newSlopeDelta = slopeChanges[_newLocked.end];
                }
            }
        }

        Point memory last_point = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        if (_epoch > 0) {
            last_point = pointHistory[_epoch];
        }
        uint last_checkpoint = last_point.ts;
        // initial_last_point is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract

        uint initial_last_point_ts = last_point.ts;
        uint initial_last_point_blk = last_point.blk;

        uint block_slope = 0; // dblock/dt
        if (block.timestamp > last_point.ts) {
            block_slope =
                (MULTIPLIER * (block.number - last_point.blk)) /
                (block.timestamp - last_point.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint t_i = (last_checkpoint / WEEK) * WEEK;
        for (uint i = 0; i < 255; ++i) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            t_i += WEEK;
            int128 d_slope = 0;
            if (t_i > block.timestamp) {
                t_i = block.timestamp;
            } else {
                d_slope = slopeChanges[t_i];
            }
            last_point.bias -=
                last_point.slope *
                int128(int(t_i - last_checkpoint));
            last_point.slope += d_slope;
            if (last_point.bias < 0) {
                // This can happen
                last_point.bias = 0;
            }
            if (last_point.slope < 0) {
                // This cannot happen - just in case
                last_point.slope = 0;
            }
            last_checkpoint = t_i;
            last_point.ts = t_i;
            last_point.blk =
                initial_last_point_blk +
                (block_slope * (t_i - initial_last_point_ts)) /
                MULTIPLIER;

            _epoch += 1;
            if (t_i == block.timestamp) {
                last_point.blk = block.number;
                break;
            } else {
                pointHistory[_epoch] = last_point;
            }
        }

        globalEpoch = _epoch;
        // Now pointHistory is filled until t=now

        if (_addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            last_point.slope += (userNewPoint.slope - userOldPoint.slope);
            last_point.bias += (userNewPoint.bias - userOldPoint.bias);
            if (last_point.slope < 0) {
                last_point.slope = 0;
            }
            if (last_point.bias < 0) {
                last_point.bias = 0;
            }
        }

        // Record the changed point into history
        pointHistory[_epoch] = last_point;

        if (_addr != address(0x0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [_newLocked.end]
            // and add old_user_slope to [_oldLocked.end]
            if (_oldLocked.end > block.timestamp) {
                // oldSlopeDelta was <something> - userOldPoint.slope, so we cancel that
                oldSlopeDelta += userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    oldSlopeDelta -= userNewPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = oldSlopeDelta;
            }

            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    newSlopeDelta -= userNewPoint.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = newSlopeDelta;
                }
                // else: we recorded it already in oldSlopeDelta
            }
            // Now handle user history
            address addr = _addr;
            uint user_epoch = userPointEpoch[addr] + 1;

            userPointEpoch[addr] = user_epoch;
            userNewPoint.ts = block.timestamp;
            userNewPoint.blk = block.number;
            userPointHistory[addr][user_epoch] = userNewPoint;
        }
    }

    /**
     * @dev Public function to trigger global checkpoint
     */
    function checkpoint() external {
        LockedBalance memory empty;
        _checkpoint(address(0), empty, empty);
    }

    /**
     * @dev Creates a new lock
     * @param _value Total units of StakingToken to lockup
     * @param _unlockTime Time at which the stake should unlock
     */
    function createLock(uint256 _value, uint256 _unlockTime) external {
        LockedBalance memory locked_ = LockedBalance({
            amount: lockedBalances[msg.sender].amount,
            end: lockedBalances[msg.sender].end
        });

        require(_value > 0, "Must stake non zero amount");
        require(locked_.amount == 0, "Withdraw old tokens first");

        uint unlockTime = (_unlockTime / WEEK) * WEEK;
        require(
            unlockTime >= block.timestamp + WEEK,
            "Voting lock must be at least 1 week"
        );
        require(
            unlockTime <= block.timestamp + MAXTIME,
            "Voting lock can be 4 years max"
        );

        _depositFor(
            msg.sender,
            _value,
            unlockTime,
            locked_,
            LockAction.CREATE_LOCK
        );
    }
}
