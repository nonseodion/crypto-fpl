pragma solidity ^0.5.0;

    /// @author Nichanan Kesonpat
    /// @title A PvP card game based on Fantasy Premier League.

    /*
        THE GAME:
        - Players select four footballers from their card collection to compete in a round of FPL
        - Players accummulate scores depending on their team's performance in that gameweek of the Premier League, according to official FPL rules
        - The player with the top score collects prize winnings for the stated wager for that gameweek
        
        RULES:
        - Each player deposits fees to enter the game
        - Each player selects footballer cards from their CryptoFPL collection
        - A team selection must consist of: 1 GK, 1 DF, 1 MF, 1 FWD
    */

contract CryptoFPL {

    //Storage variables
    address payable public leagueManager;
    uint entryFee;
    uint idGenerator; // Keep track of game ids
    uint latestGameId; // Keep track of recently created game mappings

    //Structs
    struct Commit {
        bytes32 commit;
        uint64 block;
        bool revealed;
    }

    struct Game {
        uint wager;
        address payable player1;
        address payable player2;
        bool player1Wins;
        bool player2Wins;
        bool isOpen;
        bool isFinished;
    }

    mapping(uint => Game) games;
    mapping(uint => uint) balances;
    mapping(address => uint) activeGameIndex;
    mapping(address => mapping(uint => uint)) activeGames; // Keeps track of each player's active games by mapping activeGameIndex to gameId
    mapping(uint => uint) public recentlyCreatedGames; // Keeps track of up to 10 latest gamesIds created
    
    // Map player address to gameId and footballer selection
    mapping(address => mapping(uint => Commit)) gkCommits;
    mapping(address => mapping(uint => Commit)) defCommits;
    mapping(address => mapping(uint => Commit)) midCommits;
    mapping(address => mapping(uint => Commit)) fwdCommits;

    //Events
    event LogGameCreation(address player1, uint wager, uint gameId);
    event LogGameBegin(address player2, uint gameId, uint totalPayout);
    event LogPlayer1TeamCommit(address player1, uint gameId, bytes32 gkHash, bytes32 defHash, bytes32 midHash, bytes32 fwdHash);
    event LogPlayer2TeamCommit(address player2, uint gameId, bytes32 gkHash, bytes32 defHash, bytes32 midHash, bytes32 fwdHash);
    event LogTeamReveal(address sender, bytes gkReveal, bytes defReveal, bytes midReveal, bytes fwdReveal, bytes salt);
    event LogGameEnd(address winner, uint winningScore, uint losingScore);
    event LogPayoutSent(address winner, uint balance);

    //Modifiers
    modifier isPlayer(uint gameId) { require(msg.sender == games[gameId].player1 || msg.sender == games[gameId].player2, "Invalid player address"); _;}
    modifier validPlayer2(uint gameId) { require(msg.sender != games[gameId].player1, "Player can't join their own game"); _;}
    modifier gameIsOpen(uint gameId) { require(games[gameId].isOpen, "Game is closed"); _;}
    modifier enoughFunds(uint gameId) { require(msg.value >= games[gameId].wager, "Insufficient funds sent as wager"); _;}
    
    modifier validActiveGameCount() { 
        require(msg.sender == leagueManager || activeGameIndex[msg.sender] < 3, "Player already has 3 active games");
         _;
    }

    //Refund player 2 if they send in an amount exceeding the stated wager
    modifier checkValue(uint gameId) {
        _;
        uint _wager = games[gameId].wager;
        uint amountToRefund = msg.value - _wager;
        games[gameId].player2.transfer(amountToRefund);
    }

    //Verify winner for payout withdrawal
    modifier isWinner(uint gameId) {
        require((msg.sender == games[gameId].player1 && games[gameId].player1Wins) ||
             (msg.sender == games[gameId].player2 && games[gameId].player2Wins));
        _;
    }

    constructor(uint _entryFee) public {
        leagueManager = msg.sender;
        entryFee = _entryFee;
        idGenerator = 0;
        latestGameId = 0;
    }

    //View game details
    function getGameDetails(uint gameId) public view returns(address player1, address player2, uint wager, bool isOpen) {
        return (games[gameId].player1, games[gameId].player2, games[gameId].wager, games[gameId].isOpen);
    }
    
    //Player1 creates game and sets wager
    function createGame(uint wager) public payable validActiveGameCount() returns(uint)  {
        require(msg.value >= wager);
        uint gameId = idGenerator;
        games[idGenerator] = Game({
            wager: wager,
            player1: msg.sender,
            player2: leagueManager,
            player1Wins: false,
            player2Wins: false,
            isOpen: true,
            isFinished: false 
        });
        idGenerator += 1;
        recentlyCreatedGames[latestGameId] = gameId;
        if (latestGameId == 9) {
            latestGameId = 0;
        } else {
            latestGameId += 1;
        }
        activeGames[msg.sender][activeGameIndex[msg.sender]] = gameId;
        activeGameIndex[msg.sender] += 1;
        uint change = msg.value - wager;
        msg.sender.transfer(change);
        emit LogGameCreation(msg.sender, wager, gameId);
        return gameId;
    }

    //Player2 joins game and deposits wager
    function joinGame(uint gameId) public payable gameIsOpen(gameId) enoughFunds(gameId) checkValue(gameId) validPlayer2(gameId) validActiveGameCount() {
        games[gameId].player2 = msg.sender;
        games[gameId].isOpen = false;
        balances[gameId] = games[gameId].wager * 2;
        activeGames[msg.sender][activeGameIndex[msg.sender]] = gameId;
        activeGameIndex[msg.sender] += 1;
        emit LogGameBegin(msg.sender, gameId, balances[gameId]);
    }

    //Lets users view 10 most recently created games
    function viewRecentlyCreatedGames() public view returns (uint[10] memory latestGames) {
        uint[10] memory recentGames;
        for (uint8 i = 0; i < 10; i++) {
            recentGames[i] = recentlyCreatedGames[i];
        }
        return recentGames;
    }

    //Return the total number of games that have ever been created
    function totalGames() public view returns (uint) {
        return idGenerator;
    }

    //Returns an array of gamesIds that a player is currently active in.
    function viewActiveGames(address player) public view returns (uint[3] memory gameIds) {
        uint[3] memory result;
        for(uint i = 0; i < activeGameIndex[player]; i++) {
            result[i] = activeGames[player][i];
        }
        return result;
    }

    //Commits a player to their team selection
    function commitTeam(bytes32 gkHash, bytes32 defHash, bytes32 midHash, bytes32 fwdHash, uint gameId) public isPlayer(gameId) {

        gkCommits[msg.sender][gameId] = Commit({
            commit: gkHash,
            block: uint64(block.number),
            revealed: false
        });

        defCommits[msg.sender][gameId] = Commit({
            commit: defHash,
            block: uint64(block.number),
            revealed: false
        });

        midCommits[msg.sender][gameId] = Commit({
            commit: midHash,
            block: uint64(block.number),
            revealed: false
        });

        fwdCommits[msg.sender][gameId] = Commit({
            commit: fwdHash,
            block: uint64(block.number),
            revealed: false
        });   

        if (msg.sender == games[gameId].player1) {
            emit LogPlayer1TeamCommit(msg.sender, gameId, gkHash, defHash, midHash, fwdHash);
        } else {
            emit LogPlayer2TeamCommit(msg.sender, gameId, gkHash, defHash, midHash, fwdHash);
        }
    }

    function getSaltedHash(bytes memory data, bytes memory salt) public view returns(bytes32){
        return keccak256(abi.encodePacked(address(this), data, salt));
    }
    
    function revealTeam(bytes memory gkReveal, bytes memory defReveal, bytes memory midReveal, bytes memory fwdReveal, uint gameId, bytes memory salt) public isPlayer(gameId) {        
        
        //make sure it hasn't been revealed yet and set it to revealed
        require(
            gkCommits[msg.sender][gameId].revealed == false &&
            defCommits[msg.sender][gameId].revealed == false &&
            midCommits[msg.sender][gameId].revealed == false &&
            fwdCommits[msg.sender][gameId].revealed == false, "CommitReveal::revealAnswer: Already revealed"
            );
        
        //require that they can produce the committed hash
        require(
            getSaltedHash(gkReveal, salt) == gkCommits[msg.sender][gameId].commit &&
            getSaltedHash(defReveal, salt) == defCommits[msg.sender][gameId].commit &&
            getSaltedHash(midReveal, salt) == midCommits[msg.sender][gameId].commit &&
            getSaltedHash(fwdReveal, salt) == fwdCommits[msg.sender][gameId].commit, "CommitReveal::revealAnswer: Revealed hash does not match commit"
            );

        
        gkCommits[msg.sender][gameId].revealed = true;
        defCommits[msg.sender][gameId].revealed = true;
        midCommits[msg.sender][gameId].revealed = true;
        fwdCommits[msg.sender][gameId].revealed = true;
        
        emit LogTeamReveal(msg.sender, gkReveal, defReveal, midReveal, fwdReveal, salt);
    }

    function getTeamCommitForGame(uint gameId) public view returns(bytes32[4] memory commits) {
        bytes32 gkCommit = gkCommits[msg.sender][gameId].commit;
        bytes32 defCommit = defCommits[msg.sender][gameId].commit;
        bytes32 midCommit = midCommits[msg.sender][gameId].commit;
        bytes32 fwdCommit = fwdCommits[msg.sender][gameId].commit;
        return [gkCommit, defCommit, midCommit, fwdCommit];
    }

    // Checks if the player's team has been revealed for a given game
    function teamRevealed(uint gameId) public view returns(bool) {
        return (gkCommits[msg.sender][gameId].revealed && 
                defCommits[msg.sender][gameId].revealed && 
                midCommits[msg.sender][gameId].revealed && 
                fwdCommits[msg.sender][gameId].revealed);
    }
  
    // Winner can withdraw prize money at the end of the game
    function withdrawPayout(uint gameId) public isWinner(gameId) {
        uint winnings = balances[gameId];
        balances[gameId] = 0;
        games[gameId].isFinished = true;
        activeGames[msg.sender][activeGameIndex[msg.sender]] = 0;
        activeGames[games[gameId].player2][activeGameIndex[games[gameId].player2]] = 0;
        activeGameIndex[msg.sender] -= 1;
        activeGameIndex[games[gameId].player2] -= 1;
        msg.sender.transfer(winnings);
        emit LogPayoutSent(msg.sender, winnings);
    }

}

interface CryptoFPLCards {
    
    enum Position {
    Forward,
    Midfielder,
    Defender,
    Goalkeeper
  }
    function positionOf(uint tokenId) external returns(Position);
    function balanceOf(address addr, uint tokenId) external returns(uint);

}