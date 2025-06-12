module sui_trace::sui_trace {
    use std::string::String;

    use sui::table::{Self, Table};
    use sui::coin::value;
    use sui::balance::Balance;
    use sui::url::{Self, Url};
    use sui::sui::SUI;
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
        flaggers: vector<address>, // List of addresses that have flagged this batch 
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
        product_listing_id: UID,
        product_batch_id: UID,
        buyer: address,
        seller: address,
        amount: u64,
        payment_escrow: Balance<SUI>,
        pickup_code: String,
        order_state: u8,
        problem_reported: bool,
        problem_details: String,
        created_at: u64,
    }

    public entry fun create_order(
    listing: ProductListing,
    payment: u64, // Must be at least equal to listing.price
    pickup_code: vector<u8>, // Could be random bytes or user-defined
    ctx: &mut TxContext,
    ){
        let buyer = tx_context::sender(ctx);
        assert!(listing.price <= sui::coin::value(&payment), E_INSUFFICIENT_PAYMENT); // Ensure enough payment

        let current_time = tx_context::epoch_timestamp_ms(ctx);

        // Create Order object
        let order = Order {
            id: object::new(ctx),
            product_listing_id: listing.id,
            product_batch_id: listing.product_batch_id,
            buyer,
            seller: listing.seller,
            amount: listing.price,
            payment_escrow: sui::balance::value<SUI>, // Put entire Coin into escrow for now
            pickup_code: String::utf8(pickup_code),
            order_state: ORDER_STATE_PENDING, // e.g., 0 = Pending
            problem_reported: false,
            problem_details: b"".to_string(),
            created_at: current_time,
        };

        // Store the order in the sender's account
        transfer::transfer(order, buyer);

        // You can burn or delete the ProductListing here if you want to make it unlistable
        // object::delete(listing); // optional
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
    const E_INSUFFICIENT_PAYMENT: u64 = 18;
    const E_ORDER_ALREADY_CLOSED: u64 = 19;


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

        let batch_id = String::utf8(b"batch_id_bytes");
        let initial_location = String::utf8(b"initial_location_bytes");

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
            flaggers: vector::empty<address>(), // Initialize empty vector for flaggers
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
        let new_location = String::utf8(b"new_location_bytes");

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
        let details = String::utf8(b"details_bytes");
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
        let details = String::utf8(b"details_bytes");
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
        let reason = String::utf8(b"reason_bytes");
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
        let reason = String::utf8(b"reason_bytes");
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
    _kiosk: &mut Kiosk,               // Kiosk to list the product
    _kiosk_cap: &KioskOwnerCap,       // Capability for Kiosk
    mut batch_id: ProductBatch,       // Product batch to be listed
    _price: u64,
    _title_bytes: vector<u8>,
    _description_bytes: vector<u8>,
    _image_url_bytes: vector<u8>,
    ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);

        // === VALIDATIONS ===
        assert!(sender == batch_id.current_owner, E_NOT_OWNER);
        assert!(!batch_id.is_tampered, E_BATCH_IS_TAMPERED);
        assert!(
            batch_id.current_stage == STAGE_HARVESTED ||
            batch_id.current_stage == STAGE_PROCESSED ||
            batch_id.current_stage == STAGE_INSPECTED,
            E_BATCH_NOT_LISTED_FOR_SALE
        );

        // === STATE UPDATES ===
        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        batch_id.current_stage = STAGE_DELIVERED;

        vector::push_back(
            &mut batch_id.history,
            ProductEvent {
                event_type: EVENT_LISTED,
                actor: sender,
                timestamp: current_timestamp,
                details: String::utf8(b"Product batch listed for sale") // FIX: `.to_string()`
            }
        );

        // === SHARE BATCH OBJECT ===
        let batch_id_val = object::id(&batch_id); // FIXED: declared `batch_id_val`
        transfer::public_share_object(batch_id);  // Makes the object public so others can access it

        // === CREATE LISTING ===
        let listing = ProductListing {
            id: object::new(ctx),
            product_batch_id: batch_id_val,
            seller: sender,
            price: _price, // FIXED: use `_price`, not `price`
            title: std::string::utf8(_title_bytes), // already vector<u8>
            description: std::string::utf8(_description_bytes),
            image_url: url::new_unsafe_from_bytes(_image_url_bytes),
            listed_at: current_timestamp,
        };

        // === PLACE IN KIOSK ===
        kiosk::place(_kiosk, _kiosk_cap, listing);
    }


    /// Buyer places an order for a ProductListing from a Kiosk.
    /// This function moves the payment to escrow, creates an Order object,
    /// and takes the ProductListing out of the Kiosk.
    public fun place_order(
        kiosk: &mut Kiosk,
        kiosk_cap: &KioskOwnerCap, // Buyer provides the KioskOwnerCap of the seller's Kiosk to take the item
        listing_id: ID, // ID of the ProductListing in the Kiosk
        payment: Balance<SUI>,
        ctx: &mut TxContext,
    ) {
        let sender = tx_context::sender(ctx);
        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);

        // Take the ProductListing from the Kiosk
        // kiosk::take returns the owned object.
        let listing: ProductListing = kiosk::take(kiosk, kiosk_cap, listing_id);

        let payment_value: u64 = value(&payment);
        assert!(payment_value >= listing.price, E_INSUFFICIENT_PAYMENT);
        assert!(sender == tx_context::sender(ctx), E_NOT_BUYER); // Ensure sender is the buyer

        // Generate a simple, unique pickup code.
        // This code's confidentiality is handled off-chain.
        let pickup_code = std::string::utf8(b"current_timestamp"); // Use current timestamp as a unique code

        let order = Order {
            id: object::new(ctx),
            product_listing_id: object::id<ProductListing>(&listing),
            product_batch_id: listing.product_batch_id,
            buyer: sender,
            seller: listing.seller,
            amount: value(&payment),
            payment_escrow: payment,
            pickup_code: pickup_code,
            order_state: ORDER_STATE_PAID_ESCROW,
            problem_reported: false,
            problem_details: String::utf8(b""), // Initially no problem reported
            created_at: current_timestamp,
        };

        // Transfer the consumed ProductListing to the seller, as they no longer own it,
        // it's now encapsulated by the Order lifecycle.
        transfer::transfer(listing, order.seller); // Seller gets the listing NFT for their records

        // Extract fields BEFORE sharing/moving order
        let order_id = object::id(&order);
        let product_batch_id = order.product_batch_id;
        let buyer = order.buyer;
        let seller = order.seller;
        let amount = order.amount;
        let pickup_code = order.pickup_code;

        // Share the Order object for both buyer and seller to interact with
        transfer::public_share_object(order);

        // Emit an event containing the pickup code for off-chain listeners (Walrus)
        sui::event::emit(OrderPlacedEvent {
            order_id,
            product_batch_id,
            buyer,
            seller,
            amount,
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
        assert!(object::id(product_batch) == &order.product_batch_id, E_INVALID_DETAILS); // Ensure batch matches order

        assert!(!product_batch.is_tampered, E_BATCH_IS_TAMPERED);
        assert!(product_batch.current_stage != STAGE_SOLD, E_BATCH_ALREADY_SOLD);
        assert!(order.order_state == ORDER_STATE_PAID_ESCROW, E_ORDER_STATE_INVALID); // Order must be in escrow

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);
        let new_location = string::utf8(new_location_bytes);
        assert!(!std::string::is_empty(&new_location), E_INVALID_DETAILS);

        product_batch.current_location = new_location;
        product_batch.current_stage = STAGE_IN_TRANSIT; // Update product batch stage

        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_TRANSFERRED,
                actor: sender,
                timestamp: current_timestamp,
                details: String::utf8(b"Product batch sent for delivery"),
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
        assert!(object::id(product_batch) == &order.product_batch_id, E_INVALID_DETAILS); // Ensure batch matches order

        assert!(order.order_state == ORDER_STATE_IN_TRANSIT || order.order_state == ORDER_STATE_PAID_ESCROW, E_ORDER_STATE_INVALID);
        assert!(!order.problem_reported, E_PROBLEM_ALREADY_REPORTED);
        assert!(product_batch.current_owner == order.seller, E_NOT_OWNER); // Ensure seller still owns the batch (before transfer)

        let _provided_pickup_code = string::utf8(_provided_pickup_code_bytes);
        assert!(&_provided_pickup_code == &order.pickup_code, E_INVALID_PICKUP_CODE);

        let current_timestamp = sui::tx_context::epoch_timestamp_ms(ctx);


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
                details: string::utf8(b"Delivery confirmed by buyer, payment released."),
            }
        );
        vector::push_back(
            &mut product_batch.history,
            ProductEvent {
                event_type: EVENT_SOLD,
                actor: sender,
                timestamp: current_timestamp,
                details: string::utf8(b"Product batch sold and ownership transferred to buyer."),
            }
        );
    }


    public entry fun release_payment(order: &mut Order) {
        // Reentrancy guard
        assert!(!order.is_closed, E_ORDER_ALREADY_CLOSED); // You'll need to define this error

        order.is_closed = true; // Mark as closed immediately

        // Move the Coin out of the struct
        let payment = order.payment_escrow;
        order.payment_escrow = coin::zero<SUI>(); // Optional safety: remove from order

        // Transfer ownership of the Coin to the seller
        transfer::public_transfer(payment, order.seller);
    }

    public entry fun destroy_order(order: Order) {

        // Directly deconstruct, now that we own it
        let Order {
            id: _,
            product_listing_id: _,
            product_batch_id: _,
            buyer: _,
            seller: _,
            amount: _,
            payment_escrow: _,
            pickup_code: _,
            order_state: _,
            problem_reported: _,
            problem_details: _,
            created_at: _,
            is_closed: _, // <== NEW FIELD
        } = order;

        coin::destroy_zero(payment_escrow); // Clean up coin if zeroed
        // Optionally: delete or persist order object
        object::delete(id); // if you want to clean up
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

        let Order {
            id: _,
            product_listing_id: _,
            product_batch_id: _,
            payment_escrow,
            buyer,
            seller: _,
            created_at: _,
            amount: _,
            order_state: _,
            pickup_code: _,
            problem_reported: _,
            problem_details: _
        } = order;

        // Refund payment to buyer
        transfer::public_transfer(payment_escrow, buyer);

        // Update order state
        order.order_state = ORDER_STATE_CANCELLED;

        // Log event (could be on Order or ProductBatch depending on how detailed history is required)
        // For simplicity, we assume off-chain indexing can handle this.
    }

    // Buyer reports a problem with the product.
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
        let problem_details = String::utf8(_problem_details_bytes);
        assert!(!std::string::is_empty(&problem_details), E_INVALID_DETAILS);

        order.problem_reported = true;
        order.problem_details = problem_details;
        order.order_state = ORDER_STATE_PROBLEM;

        // Log event
        sui::event::emit(OrderProblemReportedEvent {
            order_id: object::id(order),
            buyer: order.buyer,
            problem_details: order.problem_details,
        });

    }

    // Seller or Farmer resolves a reported problem.
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
        assert!(!std::string::is_empty(&_resolution_details), E_INVALID_DETAILS);

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
        let flagger_addresses = &product_batch.flaggers;
        let mut flag_entries = vector::empty<FlagEntry>();

        let len = vector::length(flagger_addresses);
        let mut i = 0;
        while (i < len) {
            let flagger = *vector::borrow(flagger_addresses, i);
            let reason = table::borrow(&product_batch.flags, flagger);
            vector::push_back(&mut flag_entries, FlagEntry { flagger, reason: *reason });
            i = i + 1;
        };
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
                details: String::utf8(b"Product batch sold to end consumer"),
            }
        );
    }

    // --- Public View Functions (Immutable, no `entry` keyword) ---

    // Gets the full history of a ProductBatch.
    public fun get_history(product_batch: &ProductBatch): vector<sui_trace::sui_trace::ProductEvent> {
        product_batch.history
    }

    // Gets all active flags for a ProductBatch.
    public fun get_flags(product_batch: &ProductBatch, flagger: address): &String {
        table::borrow(&product_batch.flags, flagger)
    }

    // Translates a stage `u8` to a human-readable String.
    public fun get_stage_name(stage: u8): String {
        if (stage == STAGE_HARVESTED) { return String::utf8(b"Harvested")};
        if (stage == STAGE_IN_TRANSIT) { return String::utf8(b"In Transit")};
        if (stage == STAGE_PROCESSED) { return String::utf8(b"Processed")};
        if (stage == STAGE_INSPECTED) { return String::utf8(b"Inspected")};
        if (stage == STAGE_DELIVERED) { return String::utf8(b"Delivered")};
        if (stage == STAGE_SOLD) { return String::utf8(b"Sold")};
        if (stage == STAGE_TAMPERED) { return String::utf8(b"Tampered")};
        b"Unknown Stage".to_string() // Fallback for unexpected values
    }

    /// Translates an event type `u8` to a human-readable String.
    public fun get_event_type_name(event_type: u8): String {
        if (event_type == EVENT_CREATED) { return String::utf8(b"Created")};
        if (event_type == EVENT_TRANSFERRED) { return String::utf8(b"Transferred")};
        if (event_type == EVENT_PROCESSED) { return String::utf8(b"Processed")};
        if (event_type == EVENT_INSPECTED) { return String::utf8(b"Inspected")};
        if (event_type == EVENT_DAMAGED) { return String::utf8(b"Damaged")};
        if (event_type == EVENT_FLAGGED) { return String::utf8(b"Flagged")};
        if (event_type == EVENT_FLAG_RESOLVED) { return String::utf8(b"Flag Resolved")};
        if (event_type == EVENT_LISTED) { return String::utf8(b"Listed")};
        if (event_type == EVENT_ORDERED) { return String::utf8(b"Ordered")};
        if (event_type == EVENT_DELIVERY_CONFIRMED) { return String::utf8(b"Delivery Confirmed")};
        if (event_type == EVENT_ORDER_CANCELLED) { return String::utf8(b"Order Cancelled")};
        if (event_type == EVENT_PROBLEM_REPORTED) { return String::utf8(b"Problem Reported")};
        if (event_type == EVENT_PROBLEM_RESOLVED) { return String::utf8(b"Problem Resolved")};
        if (event_type == EVENT_SOLD) { return b"Sold".to_string() };
        b"Unknown Event Type".to_string() // Fallback
    }

    /// Translates an order state `u8` to a human-readable String.
    public fun get_order_state_name(state: u8): String {
        if (state == ORDER_STATE_PENDING) { return String::utf8(b"Pending")};
        if (state == ORDER_STATE_PAID_ESCROW) { return String::utf8(b"Paid - Escrow")};
        if (state == ORDER_STATE_IN_TRANSIT) { return String::utf8(b"In Transit")};
        if (state == ORDER_STATE_DELIVERED) { return String::utf8(b"Delivered (Awaiting Confirmation)")};
        if (state == ORDER_STATE_CONFIRMED) { return String::utf8(b"Confirmed (Payment Released)")};
        if (state == ORDER_STATE_CANCELLED) { return String::utf8(b"Cancelled")};
        if (state == ORDER_STATE_PROBLEM) { return String::utf8(b"Problem Reported")};
        b"Unknown Order State".to_string() // Fallback for unexpected values
    }
}