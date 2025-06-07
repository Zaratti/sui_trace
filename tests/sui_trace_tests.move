/*
#[test_only]
module sui_trace::sui_trace_tests;
// uncomment this line to import the module
// use sui_trace::sui_trace;

const ENotImplemented: u64 = 0;

#[test]
fun test_sui_trace() {
    // pass
}

#[test, expected_failure(abort_code = ::sui_trace::sui_trace_tests::ENotImplemented)]
fun test_sui_trace_fail() {
    abort ENotImplemented
}
*/
// scorebox-agri-traceability/tests/supply_chain_tests.move
#[test_only]
module sui_trace::sui_trace_tests {
    use std::vector;
    use std::string::{String};

    use sui::test_scenario::{Self as test, Scenario};
    use sui::object::{Self, ID};
    use sui_trace::sui_trace::{Self as sc, ProductBatch, ProductEvent};

    // Helper function to create a String from a vector<u8>
    fun new_string(bytes: vector<u8>): String {
        string::utf8(bytes)
    }

    #[test]
    fun test_create_product_batch() {
        let farmer_address = @0xA;
        let scenario = test::begin(farmer_address);

        test::next_tx(&mut scenario, farmer_address);
        {
            sc::create_product_batch(
                b"BATCH-001",
                b"Farm A, Region X",
                test::ctx(&mut scenario)
            );
        };

        // Assert that a ProductBatch object was created and shared
        assert!(test::has_shared_object_with_id_and_type<ProductBatch>(&scenario, object::id_from_address(@0x0)), 0); // First shared object in test gets 0x0

        test::end(scenario);
    }

    #[test]
    fun test_transfer_ownership_and_log_event() {
        let farmer = @0xA;
        let transporter = @0xB;
        let scenario = test::begin(farmer);
        let batch_id: ID = object::id_from_address(@0x0);

        // Create batch
        test::next_tx(&mut scenario, farmer);
        {
            sc::create_product_batch(b"BATCH-002", b"Farm B", test::ctx(&mut scenario));
            batch_id = test::shared_object_id(&test::pop_shared_object<ProductBatch>(&mut scenario));
        };

        // Transfer ownership from farmer to transporter
        test::next_tx(&mut scenario, farmer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::transfer_ownership(product_batch, transporter, b"Warehouse 1", test::ctx(&mut scenario));
        };

        // Assert new owner and stage
        test::next_tx(&mut scenario, transporter); // Any address can view
        {
            let product_batch = test::borrow_shared_object<ProductBatch>(&mut scenario, batch_id);
            let (_, _, current_owner, current_location, current_stage, _) = sc::get_status(product_batch);
            assert!(current_owner == transporter, 0);
            assert!(string::bytes(&current_location) == b"Warehouse 1", 1);
            assert!(current_stage == sc::STAGE_IN_TRANSIT, 2);

            // Assert history log
            let history = sc::get_history(product_batch);
            assert!(vec::length(&history) == 2, 3); // Created + Transferred
            let transfer_event = *vec::borrow(&history, 1);
            assert!(transfer_event.event_type == sc::EVENT_TRANSFERRED, 4);
            assert!(transfer_event.actor == farmer, 5);
        };

        test::end(scenario);
    }

    #[test]
    fun test_flag_and_resolve_product() {
        let farmer = @0xA;
        let consumer = @0xC; // A consumer flagging a product
        let scenario = test::begin(farmer);
        let batch_id: ID = object::id_from_address(@0x0);

        // Create batch
        test::next_tx(&mut scenario, farmer);
        {
            sc::create_product_batch(b"BATCH-003", b"Farm C", test::ctx(&mut scenario));
            batch_id = test::shared_object_id(&test::pop_shared_object<ProductBatch>(&mut scenario));
        };

        // Consumer flags the product
        test::next_tx(&mut scenario, consumer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::flag_product(product_batch, b"Found strange discoloration", test::ctx(&mut scenario));
        };

        // Assert product is tampered and has a flag
        test::next_tx(&mut scenario, consumer);
        {
            let product_batch = test::borrow_shared_object<ProductBatch>(&mut scenario, batch_id);
            let (_, _, _, _, current_stage, is_tampered) = sc::get_status(product_batch);
            assert!(is_tampered, 0);
            assert!(current_stage == sc::STAGE_TAMPERED, 1);
            let flags = sc::get_flags(product_batch);
            assert!(vec::length(&flags) == 1, 2);
            assert!((*vec::borrow(&flags, 0)).0 == consumer, 3); // Flagger address
            assert!(string::bytes(&(*vec::borrow(&flags, 0)).1) == b"Found strange discoloration", 4); // Reason
        };

        // Farmer resolves the flag
        test::next_tx(&mut scenario, farmer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::resolve_flag(product_batch, consumer, b"Investigation showed natural bruising", test::ctx(&mut scenario));
        };

        // Assert flag is resolved and product is no longer tampered
        test::next_tx(&mut scenario, consumer);
        {
            let product_batch = test::borrow_shared_object<ProductBatch>(&mut scenario, batch_id);
            let (_, _, _, _, _, is_tampered) = sc::get_status(product_batch);
            assert!(!is_tampered, 0);
            let flags = sc::get_flags(product_batch);
            assert!(vec::is_empty(&flags), 1); // No more flags

            // Assert history log includes flag and resolution
            let history = sc::get_history(product_batch);
            assert!(vec::length(&history) == 3, 2); // Created + Flagged + Resolved
            let flag_event = *vec::borrow(&history, 1);
            assert!(flag_event.event_type == sc::EVENT_FLAGGED, 3);
            let resolved_event = *vec::borrow(&history, 2);
            assert!(resolved_event.event_type == sc::EVENT_FLAG_RESOLVED, 4);
            assert!(string::bytes(&resolved_event.details) == b"Investigation showed natural bruising", 5);
        };

        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sc::E_NOT_OWNER)]
    fun test_non_owner_cannot_log_processing() {
        let farmer = @0xA;
        let malicious_actor = @0xD;
        let scenario = test::begin(farmer);
        let batch_id: ID = object::id_from_address(@0x0);

        // Create batch
        test::next_tx(&mut scenario, farmer);
        {
            sc::create_product_batch(b"BATCH-004", b"Farm D", test::ctx(&mut scenario));
            batch_id = test::shared_object_id(&test::pop_shared_object<ProductBatch>(&mut scenario));
        };

        // Malicious actor tries to log processing (expected to fail)
        test::next_tx(&mut scenario, malicious_actor);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::log_processing(product_batch, b"Fake processing", test::ctx(&mut scenario));
        };

        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = sc::E_BATCH_ALREADY_SOLD)]
    fun test_cannot_transfer_sold_product() {
        let farmer = @0xA;
        let retailer = @0xE;
        let scenario = test::begin(farmer);
        let batch_id: ID = object::id_from_address(@0x0);

        // Create batch and transfer to retailer
        test::next_tx(&mut scenario, farmer);
        {
            sc::create_product_batch(b"BATCH-005", b"Farm E", test::ctx(&mut scenario));
            batch_id = test::shared_object_id(&test::pop_shared_object<ProductBatch>(&mut scenario));
        };
        test::next_tx(&mut scenario, farmer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::transfer_ownership(product_batch, retailer, b"Retail Store", test::ctx(&mut scenario));
        };

        // Retailer marks as sold
        test::next_tx(&mut scenario, retailer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::mark_as_sold(product_batch, test::ctx(&mut scenario));
        };

        // Farmer tries to transfer again (expected to fail)
        test::next_tx(&mut scenario, farmer);
        {
            let product_batch = test::borrow_shared_object_mut<ProductBatch>(&mut scenario, batch_id);
            sc::transfer_ownership(product_batch, @0xF, b"Another place", test::ctx(&mut scenario));
        };

        test::end(scenario);
    }
}