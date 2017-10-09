pragma solidity ^0.4.16;

contract ChannelBook {

    struct Registration {
        uint slot;              // Slot in the bitmap for this registration
        uint start_tick;        // Publication tick from which this registration is valid
        uint end_tick;          // Publication tick from which this registration is not valid anymore
    }

    mapping (address => Registration[]) members;

    mapping (uint => address[]) registration_expiry;

    /* Number of members registered (including the ones that have been deleted since) */
    uint memberSlotMax;

    uint[] memberSlotFreeList;

    uint constant REGISTRATION_DEPOSIT = 1 ether;   // Each registration holds deposit
    uint constant REGISTRATION_DURATION = 100;      // How many publications a registration is valid for
    uint constant MAX_REGISTRATIONS_PER_TICK = 100; // To prevent edge cases in loops

    
    function take_payment(uint amount) private {
        // Can the payment be satisfied by the returned deposits?
        uint from_returned = deposits_returned[msg.sender];
        if (from_returned > amount) {
            from_returned = amount;
        }
        require(msg.value + from_returned >= amount);
        uint to_return = msg.value + from_returned - amount;
        if (to_return > 0) {
            deposits_returned[msg.sender] += to_return; // Excess can be withdrawn at any time
        }
    }

    /* msg.sender registers itself as member. Returns the slot in the bitmap that the member will occupy */
    function register_as_member() public payable {
        take_payment(REGISTRATION_DEPOSIT);
        uint len = members[msg.sender].length;
        uint currentTick = publications.length;
        require(len == 0 || members[msg.sender][len-1].end_tick <= currentTick); // Cannot register until the current registration expires
        // Check the free list first
        uint slot;
        if (memberSlotFreeList.length == 0) {
            memberSlotMax += 1;
            slot = memberSlotMax;
        } else {
            slot = memberSlotFreeList[memberSlotFreeList.length-1];
            memberSlotFreeList.length -= 1;
        }
        uint endTick = currentTick + REGISTRATION_DURATION;
        require(registration_expiry[endTick].length < MAX_REGISTRATIONS_PER_TICK);
        registration_expiry[endTick].push(msg.sender);
        members[msg.sender].push(Registration(slot, currentTick, endTick));
    }

    /* Maintenance function that is called to ensure that expired registrations are returned to the free list */
    function expire_registrations() private {
        uint currentTick = publications.length;
        uint len = registration_expiry[currentTick].length;
        if (len > 0) {
            for(uint i = 0; i < len; i++) {
                address member = registration_expiry[currentTick][i];
                deposits_returned[member] += REGISTRATION_DEPOSIT;
                uint member_len = members[member].length;
                memberSlotFreeList.push(members[member][member_len - 1].slot);
            }
            delete registration_expiry[currentTick];
        }
    }

    /* =================================================================================================================== */

    uint constant PUBLISH_DEPOSIT = 1 ether;   // Size of each publication deposit
    /* Deposit required to block withdrawal of the publishing deposit */
    uint constant BLOCKING_DEPOSIT = 10 finney;
    uint constant PUBLISH_DEPOSIT_DURATION = 3 days;     // The contract will hold publishing deposits for 3 days
    uint constant BLOCKING_DEPOSIT_DURATION = 1 days;     // How long a blocking deposit is held
    uint constant BLOCK_DEPOSIT = 10 finney;

    struct Block {
        bool deposit_returned;        // Deposit withdrawn by the blocker or by the publisher
        bool active;                  // True if the block is active (created by not sucessfully contested)
    }

    struct Publication {
        bytes32 root_hash;                 // Hash of the trie for this publication
        uint256[] contributions;           // Bitmap of contributions
        address publisher;                 // Address who published it and paid deposit
        uint deposit_return_time;          // Time after which the publishing deposit can be returned
        bool deposit_returned;
        uint blockCount;
        mapping (address => Block) blocks; // Blocks created against this publications by contributors
    }

    Publication[] public publications;

    mapping(address => uint) public deposits_returned;  // Deposits returned (but not withdrawn)

    function publish(bytes32 root_hash, uint256[] contributions) public payable {
        // Deposit amount needs to be exact
        require(msg.value == PUBLISH_DEPOSIT);
        publications.push(Publication(root_hash, contributions, msg.sender, now + PUBLISH_DEPOSIT_DURATION, false, 0));
        expire_registrations();
    }

    function return_publish_deposits(uint startTick, uint endTick) public {
        for(uint i=startTick; i < endTick && now < publications[i].deposit_return_time; i++) {
            if (publications[i].blockCount == 0) {
                publications[i].deposit_returned = true;
                deposits_returned[publications[i].publisher] += PUBLISH_DEPOSIT;
            }
        }
    }

    function withdraw_deposit(uint amount) public {
        uint to_withdraw = deposits_returned[msg.sender];
        if (to_withdraw > amount) {
            to_withdraw = amount;
        }
        if (to_withdraw > 0) {
            deposits_returned[msg.sender] -= to_withdraw;
            msg.sender.transfer(to_withdraw);
        }
    }

    /* Any contributor to a publication can use this function to attempt to block the
       return of the publisher's deposit, if this contributor claims it never received
       a Merkle proof leading to its data. The publisher can unblock this by presenting
       a signature of the root has with the contributor's private key. That signature
       would have been given to the publisher in exchange for the Merkle proof.
       To prevent frivolous blocking, blocking requires a deposit */
    function block_withdraw(uint tick, uint registration_index) public payable {
        take_payment(PUBLISH_DEPOSIT);
        uint currentTick = publications.length;
        require(tick < currentTick);
        require(!publications[tick].deposit_returned);
        require(now < publications[tick].deposit_return_time);  // Too late to block
        require(!publications[tick].blocks[msg.sender].active);
        require(registration_index < members[msg.sender].length);
        require(members[msg.sender][registration_index].start_tick <= tick);
        require(members[msg.sender][registration_index].end_tick > tick);
        uint member_slot = members[msg.sender][registration_index].slot;
        // Divide by 256, because every bit in the contributions words
        // correspond to one member
        uint contributions_word_index = member_slot >> 8;
        uint contributions_mask = uint256(1) << (member_slot & 0xFF);
        require(publications[tick].contributions[contributions_word_index] & contributions_mask != 0);
        publications[tick].contributions[contributions_word_index] &= ~contributions_mask;
        publications[tick].blockCount++;
        publications[tick].blocks[msg.sender] = Block(
            false /* deposit_returned */,
            true /* active */
            );
     }

     /* Publisher (or anyone else on behalf of publisher) uses this function to remove the block
        placed by a contributor */
     function unblock_withdraw(uint tick, address blocker, uint8 v, bytes32 r, bytes32 s) public {
        require(tick < publications.length);
        require(publications[tick].blocks[blocker].active);
        require(blocker == ecrecover(publications[tick].root_hash, v, r, s));
        // Remove the block and claim the blocker's deposit
        publications[tick].blockCount--;
        publications[tick].blocks[blocker].active = false;
        if (!publications[tick].blocks[blocker].deposit_returned) {
            publications[tick].blocks[blocker].deposit_returned = true;
            deposits_returned[publications[tick].publisher] += BLOCKING_DEPOSIT;
        }
     }

     function return_blocking_deposit(uint tick) public {
        uint currentTick = publications.length;
        require(tick < currentTick);
        require(publications[tick].blocks[msg.sender].active);
        require(!publications[tick].blocks[msg.sender].deposit_returned);
        require(now >= publications[tick].deposit_return_time + BLOCKING_DEPOSIT_DURATION);
        publications[tick].blocks[msg.sender].deposit_returned = true;
        deposits_returned[msg.sender] += BLOCKING_DEPOSIT;
     }


}