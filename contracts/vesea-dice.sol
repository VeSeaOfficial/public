// SPDX-License-Identifier: MIT
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "../extensions/vesea-access-control.sol";
import "../extensions/vesea-random.sol";

pragma solidity ^0.8.4;

contract VeSeaDice is VeSeaAccessControl, VeSeaRandom, Pausable {
    event FundsClaimed(address indexed ownerAddress, uint256 amount);

    event Roll(
        uint256 indexed gameNumber,
        address indexed ownerAddress,
        bool win,
        uint256 playAmount,
        uint256 winAmount,
        uint256 odds,
        uint256 roll
    );

    struct Player {
        address ownerAddress;
        uint256 totalAmountPlayed;
        uint256 availableFunds;
        uint256 winAmount;
        uint256 lastBlock;
        uint256 gamesPlayed;
        uint256 gamesWon;
        uint256 winStreak;
        uint256[] games;
    }

    struct Game {
        uint256 gameNumber;
        uint256 blockNumber;
        address ownerAddress;
        uint256 playAmount;
        uint256 odds;
        uint256 roll;
        uint256 winAmount;
    }

    struct GameStats {
        uint256 gameCount;
        uint256 minPlayAmount;
        uint256 maxPlayAmount;
        uint256 playerCount;
        uint256 totalRisked;
        uint256 totalWon;
        uint256 totalBurned;
    }

    address public vseaAddress;
    uint256 public maxPlayAmount;
    uint256 public minPlayAmount;

    address[] public playerAddresses;
    uint256 public playerCount;
    mapping(address => Player) public players;

    uint256 public totalClaimableFunds;
    uint256 public totalRisked;
    uint256 public totalWon;
    uint256 public totalBurned;

    uint256 public gameCount = 1; // start at 1 due to pending game remove logic
    Game[] public games;
    Game[] private pendingGames;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    // ----------------------------------------------------------------------------
    // claimFunds
    // ----------------------------------------------------------------------------
    function claimFunds() external whenNotPaused {
        require(
            players[msg.sender].lastBlock < block.number,
            "Must wait 1 block to claim funds"
        );
        uint256 _amount = players[msg.sender].availableFunds;
        if (_amount > 0) {
            players[msg.sender].availableFunds = 0;
            totalClaimableFunds -= _amount;
            IERC20(vseaAddress).approve(address(this), _amount);
            require(
                IERC20(vseaAddress).transferFrom(
                    address(this),
                    msg.sender,
                    _amount
                ),
                "Error claiming funds"
            );

            emit FundsClaimed(msg.sender, _amount);
        }
    }

    // ----------------------------------------------------------------------------
    // roll
    // ----------------------------------------------------------------------------
    function roll(uint256 vseaAmount, uint256 odds) external whenNotPaused {
        // odds must be 10 to 90
        require(odds >= 10, "odds must be >= 10");
        require(odds <= 90, "odds must be <= 90");
        // address(this) must have enough vsea for win
        require(
            IERC20(vseaAddress).balanceOf(address(this)) >=
                payout(vseaAmount, odds) + totalClaimableFunds,
            "contract funds low"
        );
        // must have vsea and be approved
        require(
            IERC20(vseaAddress).balanceOf(msg.sender) >= vseaAmount,
            "not enough $VSEA"
        );
        require(
            IERC20(vseaAddress).allowance(msg.sender, address(this)) >=
                vseaAmount,
            "$VSEA not approved"
        );
        // cannot be more than max amount
        require(vseaAmount <= maxPlayAmount, "more than max amount");
        require(vseaAmount >= minPlayAmount, "less than min amount");

        // transfer vsea to contract
        IERC20(vseaAddress).transferFrom(msg.sender, address(this), vseaAmount);

        // create and update player record
        if (players[msg.sender].ownerAddress == address(0)) {
            players[msg.sender].ownerAddress = msg.sender;
            playerCount += 1;
            playerAddresses.push(msg.sender);
        }
        players[msg.sender].lastBlock = block.number;
        players[msg.sender].totalAmountPlayed += vseaAmount;
        players[msg.sender].gamesPlayed += 1;
        players[msg.sender].games.push(gameCount);

        // create and update game record
        Game memory _game = Game({
            gameNumber: gameCount,
            blockNumber: block.number,
            ownerAddress: msg.sender,
            playAmount: vseaAmount,
            odds: odds,
            roll: _random(100),
            winAmount: 0
        });

        bool winner = odds > _game.roll;

        if (winner) {
            uint256 winAmount = payout(vseaAmount, odds);
            _game.winAmount = winAmount;
            totalClaimableFunds += winAmount + vseaAmount;
        }

        emit Roll(
            gameCount,
            msg.sender,
            winner,
            vseaAmount,
            _game.winAmount,
            odds,
            _game.roll
        );

        // update global stats
        totalRisked += vseaAmount;
        gameCount += 1;

        pendingGames.push(_game);
    }

    // ----------------------------------------------------------------------------
    // Pending Games
    // ----------------------------------------------------------------------------
    function pendingGameNumbers() external view returns (uint256[] memory) {
        uint256[] memory _gameNumbers = new uint256[](pendingGames.length);
        for (uint256 i = 0; i < pendingGames.length; i++) {
            _gameNumbers[i] = pendingGames[i].gameNumber;
        }
        return _gameNumbers;
    }

    function processPendingGame(uint256 gameNumber) external {
        for (uint256 i = 0; i < pendingGames.length; i++) {
            if (
                pendingGames[i].gameNumber == gameNumber &&
                pendingGames[i].blockNumber < block.number
            ) {
                Game memory _game = pendingGames[i];
                games.push(_game);

                if (_game.odds > _game.roll) {
                    // win
                    // update user stats
                    players[_game.ownerAddress].winAmount += _game.winAmount;
                    players[_game.ownerAddress].winStreak += 1;
                    players[_game.ownerAddress].gamesWon += 1;
                    players[_game.ownerAddress].availableFunds +=
                        _game.winAmount +
                        _game.playAmount;

                    // update game stats
                    totalWon += _game.winAmount;
                } else {
                    // lose
                    players[_game.ownerAddress].winStreak = 0;
                    totalBurned += _game.playAmount;

                    IERC20(vseaAddress).approve(
                        address(this),
                        _game.playAmount
                    );
                    ERC20Burnable(vseaAddress).burn(_game.playAmount);
                }

                _removePendingGame(_game.gameNumber);
            }
        }
    }

    function _removePendingGame(uint256 gameNumber) private {
        for (uint256 i = 0; i < pendingGames.length; i++) {
            if (pendingGames[i].gameNumber == gameNumber) {
                if (i < pendingGames.length - 1) {
                    pendingGames[i] = pendingGames[pendingGames.length - 1];
                }
                pendingGames.pop();
                return;
            }
        }
    }

    // ----------------------------------------------------------------------------
    // Public Views
    // ----------------------------------------------------------------------------
    function gameStats() external view returns (GameStats memory) {
        return
            GameStats(
                gameCount,
                minPlayAmount,
                maxPlayAmount,
                playerCount,
                totalRisked,
                totalWon,
                totalBurned
            );
    }

    function payout(uint256 vseaAmount, uint256 odds)
        public
        pure
        returns (uint256)
    {
        uint256 unfavorable = 10000 - (odds * 100);
        uint256 payoutOdds = unfavorable / odds;
        uint256 grossPayout = (vseaAmount * payoutOdds) / 100;
        // 1% fee
        return (grossPayout * 99) / 100;
    }

    function recentGames(uint256 count) public view returns (Game[] memory) {
        if (count > gameCount) {
            count = gameCount;
        }

        uint256 startingNumber = gameCount - count - 1;
        Game[] memory results = new Game[](count);
        for (uint256 i = 0; i < count; i++) {
            results[i] = games[startingNumber + i];
        }

        return results;
    }

    function getGamesByPlayer(address playerAddress)
        public
        view
        returns (Game[] memory)
    {
        Game[] memory results = new Game[](players[playerAddress].games.length);
        for (uint256 i = 0; i < players[playerAddress].games.length; i++) {
            results[i] = games[players[playerAddress].games[i]];
        }
        return results;
    }

    function getPlayerAddresses() public view returns (address[] memory) {
        return playerAddresses;
    }

    function getTopPlayers(uint256 count)
        public
        view
        returns (Player[] memory)
    {
        Player[] memory results = new Player[](count);
        for (uint256 i = 0; i < playerCount; i++) {
            for (uint256 j = 0; j < count; j++) {
                if (
                    players[playerAddresses[i]].totalAmountPlayed >
                    results[j].totalAmountPlayed
                ) {
                    // drop players down one slot
                    for (uint256 k = count; k > j; k--) {
                        results[k] = results[k - 1];
                    }

                    // update to new player
                    results[j] = players[playerAddresses[i]];
                    break;
                }
            }
        }
        return results;
    }

    function getTopWinners(uint256 count)
        public
        view
        returns (Player[] memory)
    {
        Player[] memory results = new Player[](count);
        for (uint256 i = 0; i < playerCount; i++) {
            for (uint256 j = 0; j < count; j++) {
                if (
                    players[playerAddresses[i]].winAmount > results[j].winAmount
                ) {
                    // drop players down one slot
                    for (uint256 k = count; k > j; k--) {
                        results[k] = results[k - 1];
                    }

                    // update to new player
                    results[j] = players[playerAddresses[i]];
                    break;
                }
            }
        }
        return results;
    }

    // ----------------------------------------------------------------------------
    // Admin
    // ----------------------------------------------------------------------------
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setVSeaAddress(address _vseaAddress) public onlyRole(ADMIN_ROLE) {
        vseaAddress = _vseaAddress;
    }

    function setMaxPlayAmount(uint256 amount) public onlyRole(ADMIN_ROLE) {
        maxPlayAmount = amount;
    }

    function setMinPlayAmount(uint256 amount) public onlyRole(ADMIN_ROLE) {
        minPlayAmount = amount;
    }

    function withdrawVSea(uint256 amount)
        external
        onlyRole(ADMIN_ROLE)
        whenNotPaused
    {
        IERC20(vseaAddress).transfer(msg.sender, amount);
    }
}
