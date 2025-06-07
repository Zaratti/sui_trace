module sui_trace::sui_trace {
    use std::string::String;

    use sui::table::{Self, Table};
    use sui::balance::Balance;
    use sui::balance::value;
    use sui::coin;
    use sui::sui::SUI;
    use sui::url::{Self, Url};
    use sui::kiosk::{Self, Kiosk, KioskOwnerCap}; // Import Kiosk types and functions

    // --- Events ---
    /// Emitted when an Order is successfully placed. Crucial for off-chain pickup code relay.
    public struct OrderPlacedEvent has copy, drop {
        order_id: ID,
        product_batch_id: ID,
        buyer: address,
        seller: address,
        amount: u64,
        pickup_code: String, // This is the sensitive part Walrus handles
    }

    // --- Value Objects (Enum-like for Stages and Event Types) ---
    // Product Stages
    const STAGE_HARVESTED: u8 = 0;
    const STAGE_IN_TRANSIT: u8 = 1;
    const STAGE_PROCESSED: u8 = 2;
    const STAGE_INSPECTED: u8 = 3; // Could be a stage or an event, here treated as a stage for simplicity
    const STAGE_DELIVERED: u8 = 4;
    const STAGE_SOLD: u8 = 5;
    const STAGE_TAMPERED: u8 = 6; // Special state, not a normal progression

    // Event Types for History Log
    const EVENT_CREATED: u8 = 0;
    const EVENT_TRANSFERRED: u8 = 1;
    const EVENT_PROCESSED: u8 = 2;
    const EVENT_INSPECTED: u8 = 3;
    const EVENT_DAMAGED: u8 = 4;
    const EVENT_FLAGGED: u8 = 5;
    const EVENT_FLAG_RESOLVED: u8 = 6;
    const EVENT_LISTED: u8 = 7;
    const EVENT_ORDERED: u8 = 8;
    const EVENT_DELIVERY_CONFIRMED: u8 = 9;
    const EVENT_ORDER_CANCELLED: u8 = 10;
    const EVENT_PROBLEM_REPORTED: u8 = 11;
    const EVENT_PROBLEM_RESOLVED: u8 = 12;
    const EVENT_SOLD: u8 = 13;

    // Order States
    const ORDER_STATE_PENDING: u8 = 0;
    const ORDER_STATE_PAID_ESCROW: u8 = 1;
    const ORDER_STATE_IN_TRANSIT: u8 = 2;
    const ORDER_STATE_DELIVERED: u8 = 3;
    const ORDER_STATE_CONFIRMED: u8 = 4;
    const ORDER_STATE_CANCELLED: u8 = 5;
    const ORDER_STATE_PROBLEM: u8 = 6;

    // Represents a single event in the product batch's history.
    public struct ProductEvent has store, drop, copy {
        event_type: u8,
        actor: address,
        timestamp: u64,
        details: String, // e.g., "Inspection passed", "Damaged during transport"
    }

    // --- Aggregates & Entities ---

    // The ProductBatch Aggregate Root. This is a Shared Object.
    // It encapsulates all data and logic for a unique agricultural product batch.
    public struct ProductBatch has key, store {
        id: UID,
        batch_id: String, // Unique identifier for the batch (e.g., QR code value)
        origin_farmer: address, // Immutable: The original creator of the batch
        current_owner: address, // The current owner/custodian of the batch
        current_location: String, // Current physical location or last known location
        current_stage: u8, // Current stage in the supply chain (e.g., Harvested, In Transit)
        
        // Flags for potential tampering or issues.
        // Maps the address of the entity who flagged it to a reason.
        flags: Table<address, String>, 
        is_tampered: bool, // Derived state: true if 'flags' table is not empty

        // Immutable chronological log of all significant events.
        history: vector<ProductEvent>,
        created_at: u64, // Timestamp of batch creation
    }

    /// Represents a Product Listing in the marketplace.
    /// This object is owned by the seller's Kiosk.
    public struct ProductListing has key, store {
        id: UID,
        product_batch_id: ID, // Reference to the ProductBatch object
        seller: address, // The address that listed this product
        price: u64,
        title: String,
        description: String,
        image_url: Url,
        listed_at: u64,
    }

    /// Represents a Buyer's Order for a ProductListing.
    /// This object is shared and holds the payment in escrow.
    public struct Order has key, store {
        id: UID,
        product_listing_id: ID, // Reference to the ProductListing
        product_batch_id: ID,   // Reference to the ProductBatch
        buyer: address,
        seller: address,
        amount: u64,
        payment_escrow: Balance<SUI>, // Payment held in escrow
        pickup_code: String,    // Unique ID for pickup/delivery verification
        order_state: u8,
        problem_reported: bool,
        problem_details: String,
        created_at: u64,
    }

    // --- Error Codes ---
    const E_NOT_OWNER: u64 = 0;
    const E_NOT_ORIGIN_FARMER: u64 = 1;
    const E_BATCH_ALREADY_SOLD: u64 = 2;
    const E_BATCH_ALREADY_FLAGGED_BY_SENDER: u64 = 3;
    const E_BATCH_NOT_FLAGGED_BY_SENDER: u64 = 4;
    const E_BATCH_ALREADY_TAMPERED: u64 = 5;
    const E_BATCH_NOT_TAMPERED: u64 = 6;
    const E_INVALID_DETAILS: u64 = 7;
    const E_INVALID_PICKUP_CODE: u64 = 8;
    const E_ORDER_STATE_INVALID: u64 = 9;
    const E_ORDER_ALREADY_CONFIRMED: u64 = 10;
    const E_ORDER_ALREADY_CANCELLED: u64 = 11;
    const E_NOT_BUYER: u64 = 12;
    const E_NO_PROBLEM_REPORTED: u64 = 13;
    const E_PROBLEM_ALREADY_REPORTED: u64 = 14;
    const E_NOT_SELLER: u64 = 15;
    const E_BATCH_IS_TAMPERED: u64 = 16;
    const E_BATCH_NOT_LISTED_FOR_SALE: u64 = 17;


    // --- Public Functions (Entry Points) ---

    /// Creates a new ProductBatch object (by the Farmer).
    /// The ProductBatch object is a shared object, accessible by anyone for verification.
    public entry fun create_product_batch(
        _batch_id_bytes: vector<u8>,
        _initial_location_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx); // Use epoch_timestamp_ms

        let batch_id = b"batch_id_bytes".to_string();
        let initial_location = b"initial_location_bytes".to_string();

        // Create the initial event log
        let mut history = vector::empty<ProductEvent>();
        vector::push_back(
            &mut history,
            ProductEvent {
                event_type: EVENT_CREATED,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Batch created and harvested".to_string(),
            }
        );

        let product_batch = ProductBatch {
            id: object::new(ctx),
            batch_id,
            origin_farmer: sender,
            current_owner: sender, // Farmer is the initial owner
            current_location: initial_location,
            current_stage: STAGE_HARVESTED,
            flags: table::new(ctx),
            is_tampered: false,
            history,
            created_at: current_timestamp,
        };

        // Transfer the newly created ProductBatch object as a shared object.
        transfer::share_object(product_batch);
    }

    /// Allows the current owner to transfer ownership of a ProductBatch.
    /// This also logs a 'Transferred' event and updates the stage to 'In Transit'.
    public entry fun transfer_ownership(
        product_batch: &mut ProductBatch,
        new_owner: address,
        _new_location_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER); // Only current owner can transfer
        assert!(!product_batch.is_tampered, E_BATCH_ALREADY_TAMPERED); // Cannot transfer if tampered
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD); // Cannot transfer if sold

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let new_location = b"new_location_bytes".to_string();

        // Update ownership and location
        product_batch.current_owner = new_owner;
        product_batch.current_location = new_location;
        product_batch.current_stage = STAGE_IN_TRANSIT; // Product is now in transit

        // Log the transfer event
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_TRANSFERRED,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Ownership transferred".to_string(),
            }
        );
    }

    /// Logs a processing event for the ProductBatch.
    /// Only the current owner can log processing. Updates stage to 'Processed'.
            public entry fun log_processing(
                product_batch: &mut ProductBatch,
                _details_bytes: vector<u8>,
                ctx: &mut TxContext,
            ) {
                let sender = tx_context::sender(ctx);
                assert!(sender == product_batch.current_owner, E_NOT_OWNER);
                assert!(!product_batch.is_tampered, E_BATCH_ALREADY_TAMPERED);
                assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);

                let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
                let details = b"details_bytes".to_string();
                assert!(!std::string::is_empty(&details), E_INVALID_DETAILS);

                product_batch.current_stage = STAGE_PROCESSED; // Update stage
                vector::push_back(
                    &mut product_batch.history,
                    ProductEvent {
                        event_type: EVENT_PROCESSED,
                        actor: sender,
                        timestamp: current_timestamp,
                        details,
                    }
                );
            }

    /// Logs an inspection event for the ProductBatch.
    /// Only the current owner can log inspection. Updates stage to 'Inspected'.
    public entry fun log_inspection(
        product_batch: &mut ProductBatch,
        _details_bytes: vector<u8>, // e.g., "Passed quality check", "Failed pesticide test"
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER);
        assert!(!product_batch.is_tampered, E_BATCH_ALREADY_TAMPERED);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let details = b"details_bytes".to_string();
        assert!(!std::string::is_empty(&details), E_INVALID_DETAILS);

        product_batch.current_stage = STAGE_INSPECTED; // Update stage
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_INSPECTED,
                actor: sender,
                timestamp: current_timestamp,
                details,
            }
        );
    }

    /// Logs a damage event for the ProductBatch.
    /// Only the current owner can log damage. This also flags the product.
    public entry fun log_damage(
        product_batch: &mut ProductBatch,
        _reason_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let reason = b"reason_bytes".to_string();
        assert!(!std::string::is_empty(&reason), E_INVALID_DETAILS);

        // Add a flag and mark as tampered
        table::add(&mut product_batch.flags, sender, reason);
        product_batch.is_tampered = true;
        product_batch.current_stage = STAGE_TAMPERED; // Set stage to tampered

        // Log the damage event
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_DAMAGED,
                actor: sender,
                timestamp: current_timestamp,
                details: reason,
            }
        );
    }

    // Flags a ProductBatch for potential tampering or issues.
    // Any address can flag a product, but only if it's not already sold.
    public entry fun flag_product(
        product_batch: &mut ProductBatch,
        _reason_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);
        assert!(!table::contains(&product_batch.flags, sender), E_BATCH_ALREADY_FLAGGED_BY_SENDER);

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let reason = b"reason_bytes".to_string();
        assert!(!std::string::is_empty(&reason), E_INVALID_DETAILS);

        table::add(&mut product_batch.flags, sender, reason);
        product_batch.is_tampered = true; // Mark as tampered
        product_batch.current_stage = STAGE_TAMPERED; // Set stage to tampered

        // Log the flagging event
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_FLAGGED,
                actor: sender,
                timestamp: current_timestamp,
                details: reason,
            }
        );
    }

    /// Resolves a flag on a ProductBatch.
    /// Only the original farmer (creator) can resolve flags.
    public entry fun resolve_flag(
        product_batch: &mut ProductBatch,
        flagger_address: address, // The address that placed the flag to be resolved
        resolution_details_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.origin_farmer, E_NOT_ORIGIN_FARMER); // Only origin farmer can resolve
        assert!(product_batch.is_tampered, E_BATCH_NOT_TAMPERED); // Only resolve if currently tampered
        assert!(table::contains(&product_batch.flags, flagger_address), E_BATCH_NOT_FLAGGED_BY_SENDER); // Flag must exist

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let resolution_details = (resolution_details_bytes).to_string();
        assert!(!std::string::is_empty(&resolution_details), E_INVALID_DETAILS);

        // Remove the specific flag
        table::remove(&mut product_batch.flags, flagger_address);

        // If no more flags, set is_tampered to false.
        if (table::is_empty(&product_batch.flags)) {
            product_batch.is_tampered = false;
            // Optionally, revert stage from STAGE_TAMPERED to previous or a neutral state
            // For simplicity, we leave it as STAGE_TAMPERED until a new stage is set by owner.
        };

        // Log the flag resolution event
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_FLAG_RESOLVED,
                actor: sender,
                timestamp: current_timestamp,
                details: resolution_details,
            }
        );
    }

    /// Creates a new ProductListing for a ProductBatch and places it in a Kiosk.
    /// The ProductBatch must be owned by the seller (sender).
    /// The seller must provide their Kiosk and KioskOwnerCap.
    public entry fun create_and_list_product(
        kiosk: &mut Kiosk, // Kiosk object to place the listing in
        kiosk_cap: &KioskOwnerCap, // Capability to prove ownership of the Kiosk
        product_batch: ProductBatch, // Takes ownership of the ProductBatch
        price: u64,
        _title_bytes: vector<u8>,
        _description_bytes: vector<u8>,
        image_url_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER); // Only owner can list their batch
        assert!(!product_batch.is_tampered, E_BATCH_IS_TAMPERED); // Cannot list tampered product
        assert!(product_batch.current_stage == STAGE_HARVESTED || product_batch.current_stage == STAGE_PROCESSED || product_batch.current_stage == STAGE_INSPECTED, E_BATCH_NOT_LISTED_FOR_SALE); // Must be in a ready-for-sale stage

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        // Update product batch stage to "Listed" (conceptually represented by STAGE_SOLD or a new LISTED stage)
        // For simplicity, we use STAGE_DELIVERED to indicate it's ready for marketplace.
        product_batch.current_stage = STAGE_DELIVERED;
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_LISTED,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Product batch listed for sale".to_string(),
            }
        );
        transfer::share_object(product_batch); // Share the batch so it can be viewed by anyone

        let listing = ProductListing {
            id: object::new(ctx),
            product_batch_id: object::id(&product_batch),
            seller: sender,
            price,
            title: _title_bytes.to_string(), // Convert bytes to String
            description: _description_bytes.to_string(), // Convert bytes to String
            image_url: url::new_unsafe_from_bytes(image_url_bytes),
            listed_at: current_timestamp,
        };

        // Place the ProductListing into the Kiosk
        kiosk::place(kiosk, kiosk_cap, listing);
    }

    /// Buyer places an order for a ProductListing from a Kiosk.
    /// This function moves the payment to escrow, creates an Order object,
    /// and takes the ProductListing out of the Kiosk.
    public fun place_order(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap, // Buyer provides the KioskOwnerCap of the seller's Kiosk to take the item
        listing_id: ID, // ID of the ProductListing in the Kiosk
        payment: Balance<sui::sui::SUI>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        // Take the ProductListing from the Kiosk
        // kiosk::take returns the owned object.
        let listing: ProductListing = kiosk::take(kiosk, kiosk_cap, listing_id);

        let _amount = value(&payment) >= listing.price;
        assert!(sender == tx_context::sender(ctx), E_NOT_BUYER); // Ensure sender is the buyer

        // Generate a simple, unique pickup code.
        // This code's confidentiality is handled off-chain.
        let pickup_code = b"pickup".to_string(); // Use current timestamp as a unique code

        let order = Order {
            id: object::new(ctx),
            product_listing_id: object::id(&listing),
            product_batch_id: listing.product_batch_id,
            buyer: sender,
            seller: listing.seller,
            amount: value(&payment),
            payment_escrow: payment,
            pickup_code: pickup_code,
            order_state: ORDER_STATE_PAID_ESCROW,
            problem_reported: false,
            problem_details: b"".to_string(), // Initially no problem reported
            created_at: current_timestamp,
        };

        // Transfer the consumed ProductListing to the seller, as they no longer own it,
        // it's now encapsulated by the Order lifecycle.
        transfer::transfer(listing, order.seller); // Seller gets the listing NFT for their records

        // Share the Order object for both buyer and seller to interact with
        transfer::share_object(order);

        // Emit an event containing the pickup code for off-chain listeners (Walrus)
        sui::event::emit(OrderPlacedEvent {
            order_id: object::id(&order),
            product_batch_id: order.product_batch_id,
            buyer: order.buyer,
            seller: order.seller,
            amount: order.amount,
            pickup_code, // Emit the pickup code here
        });
    }

    /// Seller updates the product batch status to InTransit.
    /// Requires mutable access to ProductBatch and Order.
    public entry fun product_in_transit(
        product_batch: &mut ProductBatch,
        order: &mut Order,
        new_location_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER); // Sender must be current batch owner (seller)
        assert!(sender == order.seller, E_NOT_SELLER); // Sender must be the seller of the order
        assert!(object::id(product_batch) == order.product_batch_id, E_INVALID_DETAILS); // Ensure batch matches order

        assert!(!product_batch.is_tampered, E_BATCH_IS_TAMPERED);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);
        assert!(order.order_state == ORDER_STATE_PAID_ESCROW, E_ORDER_STATE_INVALID); // Order must be in escrow

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let new_location = new_location_bytes.to_string();
        assert!(!std::string::is_empty(&new_location), E_INVALID_DETAILS);

        product_batch.current_location = new_location;
        product_batch.current_stage = STAGE_IN_TRANSIT; // Update product batch stage

        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_TRANSFERRED,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Product batch sent for delivery".to_string(),
            }
        );

        // Update order state
        order.order_state = ORDER_STATE_IN_TRANSIT;
    }

    /// Buyer confirms delivery and provides the pickup code.
    /// This releases the payment to the seller and transfers batch ownership to buyer.
    public entry fun confirm_delivery(
        order: &mut Order,
        product_batch: &mut ProductBatch,
        _provided_pickup_code_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == order.buyer, E_NOT_BUYER);
        assert!(object::id(product_batch) == order.product_batch_id, E_INVALID_DETAILS); // Ensure batch matches order

        assert!(order.order_state == ORDER_STATE_IN_TRANSIT || order.order_state == ORDER_STATE_PAID_ESCROW, E_ORDER_STATE_INVALID);
        assert!(!order.problem_reported, E_PROBLEM_ALREADY_REPORTED);
        assert!(product_batch.current_owner == order.seller, E_NOT_OWNER); // Ensure seller still owns the batch (before transfer)

        let _provided_pickup_code = _provided_pickup_code_bytes.to_string();
        assert!(&_provided_pickup_code == &order.pickup_code, E_INVALID_PICKUP_CODE);

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        // Release payment to seller
        transfer::public_transfer(order.payment_escrow, order.seller);

        // Transfer product batch ownership to buyer
        product_batch.current_owner = sender;
        product_batch.current_stage = STAGE_DELIVERED; // Mark as delivered

        // Update order state
        order.order_state = ORDER_STATE_CONFIRMED;
        order.problem_reported = false; // Clear any lingering problem states

        // Log events
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_DELIVERY_CONFIRMED,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Delivery confirmed by buyer, payment released.".to_string(),
            }
        );
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_SOLD,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Product batch sold and ownership transferred to buyer.".to_string(),
            }
        );
    }

    /// Buyer cancels an order before delivery confirmation (or problem resolution).
    /// Refunds the payment to the buyer.
    public entry fun cancel_order(
        order: &mut Order,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == order.buyer, E_NOT_BUYER);
        assert!(order.order_state != ORDER_STATE_CONFIRMED, E_ORDER_ALREADY_CONFIRMED);
        assert!(order.order_state != ORDER_STATE_CANCELLED, E_ORDER_ALREADY_CANCELLED);

        let _current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        // Refund payment to buyer
        transfer::public_transfer(order.payment_escrow, order.buyer);

        // Update order state
        order.order_state = ORDER_STATE_CANCELLED;

        // Log event (could be on Order or ProductBatch depending on how detailed history is required)
        // For simplicity, we assume off-chain indexing can handle this.
    }

    /// Buyer reports a problem with the product.
    public entry fun report_problem(
        order: &mut Order,
        _problem_details_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == order.buyer, E_NOT_BUYER);
        assert!(order.order_state != ORDER_STATE_CONFIRMED && order.order_state != ORDER_STATE_CANCELLED, E_ORDER_STATE_INVALID);
        assert!(!order.problem_reported, E_PROBLEM_ALREADY_REPORTED);

        let _current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let problem_details = _problem_details_bytes.to_string();
        assert!(problem_details, E_INVALID_DETAILS);

        order.problem_reported = true;
        order.problem_details = problem_details;
        order.order_state = ORDER_STATE_PROBLEM;

        // Log event
    }

    /// Seller or Farmer resolves a reported problem.
    public entry fun resolve_problem(
        order: &mut Order,
        product_batch: &mut ProductBatch, // Need batch to potentially clear its flags
        _resolution_details_bytes: vector<u8>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == order.seller || sender == product_batch.origin_farmer, E_NOT_SELLER);
        assert!(order.order_state == ORDER_STATE_PROBLEM, E_ORDER_STATE_INVALID);
        assert!(order.problem_reported, E_NO_PROBLEM_REPORTED);
        assert!(object::id(product_batch) == order.product_batch_id, E_INVALID_DETAILS); // Ensure batch matches order

        let _current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let _resolution_details = _resolution_details_bytes.to_string();
        assert!(_resolution_details, E_INVALID_DETAILS);

        order.problem_reported = false;
        order.problem_details = b"".to_string(); // Clear problem details
        order.order_state = ORDER_STATE_PAID_ESCROW; // Revert to escrow, awaiting buyer's decision

        // If the problem was related to flags on the batch, seller might resolve them here
        // Example: if sender is origin_farmer and they are resolving their own flags
        if (sender == product_batch.origin_farmer && table::contains(&product_batch.flags, sender)) {
             table::remove(&mut product_batch.flags, sender);
             if (table::is_empty(&product_batch.flags)) {
                 product_batch.is_tampered = false;
             };
        };

        // Log event
    }

    // --- Public View Functions (Immutable, no `entry` keyword) ---

    /// Gets the full history of a ProductBatch.
    public fun get_batch_history(_product_batch: &ProductBatch): vector<ProductEvent> {
        _product_batch.history
    }

    /// Gets the current status and ownership details of a ProductBatch.
    public fun get_batch_status(product_batch: &ProductBatch): (std::string::String, address, address, std::string::String, u8, bool) {
        (
            product_batch.batch_id,
            product_batch.origin_farmer,
            product_batch.current_owner,
            product_batch.current_location,
            product_batch.current_stage,
            product_batch.is_tampered
        )
    }

    // Struct to represent a flag entry (address, reason)
    public struct FlagEntry has copy, drop, store {
        flagger: address,
        reason: String,
    }

    // Gets all active flags for a ProductBatch.
    public fun get_batch_flags(product_batch: &ProductBatch): vector<FlagEntry> {
        let flag_entries = vector::empty<FlagEntry>();
        let flagger_addresses = table::keys(&product_batch.flags);

        let len = vector::length(&flagger_addresses);
        let mut i = 0;
        while (i < len) {
            let flagger = *vector::borrow(&flagger_addresses, i);
            let reason = table::borrow(&product_batch.flags, flagger);
            vector::push_back(&mut flag_entries, FlagEntry { flagger, reason: *reason });
            i = i + 1;
        }
        flag_entries
    }

    /// Gets details of a ProductListing.
    public fun get_listing_details(listing: &ProductListing): (ID, address, u64, String, String, Url) {
        (
            listing.product_batch_id,
            listing.seller,
            listing.price,
            listing.title,
            listing.description,
            listing.image_url
        )
    }

    /// Gets details of an Order.
    public fun get_order_details(order: &Order): (ID, ID, address, address, u64, std::string::String, u8, bool, std::string::String) {
        (
            order.product_listing_id,
            order.product_batch_id,
            order.buyer,
            order.seller,
            order.amount,
            order.pickup_code,
            order.order_state,
            order.problem_reported,
            order.problem_details
        )
    }

    //===================
    /// Marks a ProductBatch as sold.
    /// Only the current owner (assumed to be the retailer at this stage) can mark as sold.
    public entry fun mark_as_sold(
        product_batch: &mut ProductBatch,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        assert!(sender == product_batch.current_owner, E_NOT_OWNER);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);
        assert!(!product_batch.is_tampered, E_BATCH_ALREADY_TAMPERED); // Cannot sell a tampered product

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        product_batch.current_stage = STAGE_SOLD;

        // Log the sold event
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_SOLD,
                actor: sender,
                timestamp: current_timestamp,
                details: b"Product batch sold to end consumer".to_string(),
            }
        );
    }

    // --- Public View Functions (Immutable, no `entry` keyword) ---

    // Gets the full history of a ProductBatch.
    public fun get_history(product_batch: &ProductBatch): vector<sui_trace::sui_trace::ProductEvent> {
        product_batch.history
    }

    // Gets the current status and ownership details of a ProductBatch.
    public fun get_status(product_batch: &ProductBatch): (address, address, address, String, u8, bool) {
        (
            product_batch.id.to_address(),
            product_batch.origin_farmer,
            product_batch.current_owner,
            product_batch.current_location,
            product_batch.current_stage,
            product_batch.is_tampered
        )
    }

    // Gets all active flags for a ProductBatch.
    public fun get_flags(product_batch: &ProductBatch, flagger: address): &String {
        table::borrow(&product_batch.flags, flagger)
    }

    // Translates a stage `u8` to a human-readable String.
    public fun get_stage_name(stage: u8): String {
        if (stage == STAGE_HARVESTED) { return b"Harvested".to_string() };
        if (stage == STAGE_IN_TRANSIT) { return b"In Transit".to_string() };
        if (stage == STAGE_PROCESSED) { return b"Processed".to_string() };
        if (stage == STAGE_INSPECTED) { return b"Inspected".to_string() };
        if (stage == STAGE_DELIVERED) { return b"Delivered".to_string() };
        if (stage == STAGE_SOLD) { return b"Sold".to_string() };
        if (stage == STAGE_TAMPERED) { return b"Tampered".to_string() };
        b"Unknown Stage".to_string() // Fallback for unexpected values
    }

    /// Translates an event type `u8` to a human-readable String.
    public fun get_event_type_name(event_type: u8): String {
        if (event_type == EVENT_CREATED) { return b"Created".to_string()};
        if (event_type == EVENT_TRANSFERRED) { return b"Transferred".to_string()};
        if (event_type == EVENT_PROCESSED) { return b"Processed".to_string()};
        if (event_type == EVENT_INSPECTED) { return b"Inspected".to_string()};
        if (event_type == EVENT_DAMAGED) { return b"Damaged".to_string()};
        if (event_type == EVENT_FLAGGED) { return b"Flagged".to_string()};
        if (event_type == EVENT_FLAG_RESOLVED) { return b"Flag Resolved".to_string()};
        if (event_type == EVENT_LISTED) { return b"Listed".to_string()};
        if (event_type == EVENT_ORDERED) { return b"Ordered".to_string()};
        if (event_type == EVENT_DELIVERY_CONFIRMED) { return b"Delivery Confirmed".to_string()};
        if (event_type == EVENT_ORDER_CANCELLED) { return b"Order Cancelled".to_string()};
        if (event_type == EVENT_PROBLEM_REPORTED) { return b"Problem Reported".to_string()};
        if (event_type == EVENT_PROBLEM_RESOLVED) { return b"Problem Resolved".to_string()};
        if (event_type == EVENT_SOLD) { return b"Sold".to_string() };
        b"Unknown Event Type".to_string() // Fallback
    }

    /// Translates an order state `u8` to a human-readable String.
    public fun get_order_state_name(state: u8): String {
        if (state == ORDER_STATE_PENDING) { return b"Pending".to_string()};
        if (state == ORDER_STATE_PAID_ESCROW) { return b"Paid - Escrow".to_string()};
        if (state == ORDER_STATE_IN_TRANSIT) { return b"In Transit".to_string()};
        if (state == ORDER_STATE_DELIVERED) { return b"Delivered (Awaiting Confirmation)".to_string()};
        if (state == ORDER_STATE_CONFIRMED) { return b"Confirmed (Payment Released)".to_string()};
        if (state == ORDER_STATE_CANCELLED) { return b"Cancelled".to_string()};
        if (state == ORDER_STATE_PROBLEM) { return b"Problem Reported".to_string()};
        b"Unknown Order State".to_string() // Fallback for unexpected values
    }
}