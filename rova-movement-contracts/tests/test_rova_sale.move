#[test_only]
module rova_sale_addr::rova_sale_tests {
    use std::bcs;
    use std::signer;
    use std::vector;
    use aptos_std::ed25519::{Self};
    use aptos_std::from_bcs;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::aptos_account::{Self};
    use aptos_framework::timestamp;
    use rova_sale_addr::rova_sale::{Self};

    // Error constants
    const ENOT_ADMIN: u64 = 1;
    const EINVALID_SIGNATURE: u64 = 5;
    const EINVALID_SALE_PERIOD: u64 = 7;
    const ESALE_NOT_ACTIVE: u64 = 8;

    // Test accounts
    const ADMIN: address = @rova_sale_addr;
    const USER: address = @0x456;
    const SIGNER: address = @0x123;
    const WITHDRAWAL_ADDR: address = @withdrawal_addr;

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    public entry fun test_init_module(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Verify initial state
        assert!(rova_sale::is_paused(), 0);
        assert!(rova_sale::get_withdrawal_address() == WITHDRAWAL_ADDR, 1);
        let (starts_at, ends_at) = rova_sale::get_sale_period();
        assert!(starts_at == 0 && ends_at == 0, 2);

        // Verify initial roles
        assert!(rova_sale::has_role(WITHDRAWAL_ADDR, 2), 3);
        assert!(rova_sale::has_role(ADMIN, 3), 4);
        assert!(rova_sale::get_manager_role_members() == vector::singleton(ADMIN), 5);
        assert!(rova_sale::get_signer_role_members() == vector::empty<address>(), 6);
        assert!(rova_sale::get_withdrawal_role_members() == vector::singleton(WITHDRAWAL_ADDR), 7);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    public entry fun test_manage_role(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);
        
        // Test adding signer role
        let new_signer = @0x123;
        rova_sale::manage_role(admin, 1, new_signer, true);
        assert!(rova_sale::has_role(new_signer, 1), 0);

        // Test removing signer role
        rova_sale::manage_role(admin, 1, new_signer, false);
        assert!(!rova_sale::has_role(new_signer, 1), 1);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50001, location = rova_sale)]
    public entry fun test_manage_role_signer_role_unauthorized(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to manage role
        let unauthorized = account::create_account_for_test(@0x789);
        rova_sale::manage_role(&unauthorized, 1, WITHDRAWAL_ADDR, true);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50002, location = rova_sale)]
    public entry fun test_manage_role_withdrawal_role_unauthorized(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to manage role
        let unauthorized = account::create_account_for_test(@0x789);
        rova_sale::manage_role(&unauthorized, 2, WITHDRAWAL_ADDR, true);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50001, location = rova_sale)]
    public entry fun test_manage_role_manager_role_unauthorized(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to manage role
        let unauthorized = account::create_account_for_test(@0x789);
        rova_sale::manage_role(&unauthorized, 3, WITHDRAWAL_ADDR, true);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x10008, location = rova_sale)]
    public entry fun test_manage_role_unsupported_role_type(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to manage role
        rova_sale::manage_role(admin, 4, WITHDRAWAL_ADDR, true);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    public entry fun test_set_sale_period(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);
        
        // Set sale period
        let start_time = 1000;
        let end_time = 2000;
        rova_sale::set_sale_period(admin, start_time, end_time);

        // Verify sale period
        let (starts_at, ends_at) = rova_sale::get_sale_period();
        assert!(starts_at == start_time, 0);
        assert!(ends_at == end_time, 1);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x10007, location = rova_sale)]
    public entry fun test_set_sale_period_invalid_period(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);
        
        // Set sale period
        let start_time = 1000;
        let end_time = 1000;
        rova_sale::set_sale_period(admin, start_time, end_time);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    public entry fun test_pause_unpause(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);
        
        // Test pause
        rova_sale::set_pause(admin, true);
        assert!(rova_sale::is_paused(), 0);

        // Test unpause
        rova_sale::set_pause(admin, false);
        assert!(!rova_sale::is_paused(), 1);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50002, location = rova_sale)]
    public entry fun test_pause_unpause_unauthorized(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to pause
        let unauthorized = account::create_account_for_test(@0x789);
        rova_sale::set_pause(&unauthorized, true);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    public entry fun test_fund(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 1000;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);

        // Fund
        let user_addr = signer::address_of(user);
        let prev_user_balance = coin::balance<AptosCoin>(user_addr);
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    
        // Verify rova_sale has tokens
        let rova_sale_balance = coin::balance<AptosCoin>(@rova_sale_addr);
        assert!(rova_sale_balance == payment_amount, 0);

        // Verify user has less tokens
        let user_balance = coin::balance<AptosCoin>(user_addr);
        assert!(user_balance == prev_user_balance - payment_amount, 1);

        // Verify launch_participation_id is used
        assert!(rova_sale::has_launch_participation_id(launch_participation_id), 2);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    #[expected_failure(abort_code = 0x30006, location = rova_sale)]
    public entry fun test_fund_sale_period_not_active(admin: &signer, framework: &signer, user: &signer) {
        // Setup without sale period
        setup_test(admin, framework);
        rova_sale::set_pause(admin, false);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 1000;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);

        // Set time
        timestamp::update_global_time_for_test_secs(50);

        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    #[expected_failure(abort_code = 0x30005, location = rova_sale)]
    public entry fun test_fund_sale_paused(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 1000;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);

        // Pause sale
        rova_sale::set_pause(admin, true);

        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    #[expected_failure(abort_code = 0x10004, location = rova_sale)]
    public entry fun test_fund_invalid_launch_participation_id(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 1000;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);

        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);

        // Fund again with same launch_participation_id
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    #[expected_failure(abort_code = 0x50002, location = rova_sale)]
    public entry fun test_fund_invalid_signature_not_signer_role(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 100;
        let (signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);

        // Remove signer from signer role
        rova_sale::manage_role(admin, 1, signer_addr, false);
    
        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x123)]
    #[expected_failure(abort_code = 0x10003, location = rova_sale)]
    public entry fun test_fund_invalid_signature_wrong_user_address(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 100;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);
    
        // Fund with different address
        rova_sale::fund(admin, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x123)]
    #[expected_failure(abort_code = 0x10003, location = rova_sale)]
    public entry fun test_fund_invalid_signature_wrong_launch_participation_id(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 100;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, b"abcde", token_amount, payment_amount);
    
        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x123)]
    #[expected_failure(abort_code = 0x10003, location = rova_sale)]
    public entry fun test_fund_invalid_signature_wrong_token_amount(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 100;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, 200, payment_amount);
    
        // Fund 
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x123)]
    #[expected_failure(abort_code = 0x10003, location = rova_sale)]
    public entry fun test_fund_invalid_signature_wrong_payment_amount(admin: &signer, framework: &signer, user: &signer) {
        // Setup sale
        setup_sale_config(admin, framework);

        // Generate signature
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 100;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, 200);
    
        // Fund
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, user = @0x456)]
    public entry fun test_withdraw(admin: &signer, framework: &signer, user: &signer) {
        // Setup fund
        setup_sale_config(admin, framework);
        let launch_participation_id = b"cm6zl5lha00003b712h28v7cv";
        let token_amount = 100;
        let payment_amount = 1000;
        let (_signer_addr, signature_bytes, public_key_bytes) = generate_signature(admin, user, launch_participation_id, token_amount, payment_amount);
        rova_sale::fund(user, signature_bytes, public_key_bytes, launch_participation_id, token_amount, payment_amount);
    
        // Withdraw
        rova_sale::withdraw(admin, payment_amount);

        // Verify withdrawal
        let balance = coin::balance<AptosCoin>(WITHDRAWAL_ADDR);
        assert!(balance == payment_amount, 0);

        // Verify rova_sale has no tokens
        let rova_sale_balance = coin::balance<AptosCoin>(@rova_sale_addr);
        assert!(rova_sale_balance == 0, 1);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x10006, location = aptos_framework::coin)]
    public entry fun test_withdraw_invalid_amount(
        admin: &signer,
        framework: &signer
    ) {
        // Setup
        setup_test(admin, framework);
        
        // Try to withdraw without funds
        rova_sale::withdraw(admin, 100);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50001, location = rova_sale)]
    public entry fun test_withdraw_unauthorized(
        admin: &signer,
        framework: &signer
    ) {
        // Setup
        setup_test(admin, framework);
        
        // Try to withdraw without role
        let unauthorized = account::create_account_for_test(@0x789);
        rova_sale::withdraw(&unauthorized, 100);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework, withdrawal_addr = @withdrawal_addr)]
    public entry fun test_set_withdrawal_address(admin: &signer, framework: &signer, withdrawal_addr: &signer) {
        // Setup
        setup_test(admin, framework);

        // Set withdrawal address
        let new_withdrawal_address = @0x123;
        rova_sale::set_withdrawal_address(withdrawal_addr, new_withdrawal_address);

        // Verify withdrawal address
        assert!(rova_sale::get_withdrawal_address() == new_withdrawal_address, 0);
    }

    #[test(admin = @rova_sale_addr, framework = @aptos_framework)]
    #[expected_failure(abort_code = 0x50002, location = rova_sale)]
    public entry fun test_set_withdrawal_address_unauthorized(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Try to set withdrawal address
        let new_withdrawal_address = @0x123;
        rova_sale::set_withdrawal_address(admin, new_withdrawal_address);
    }

    fun setup_test(admin: &signer, framework: &signer) {
        // Start time
        timestamp::set_time_has_started_for_testing(framework);
        
        // Initialize module
        rova_sale::init_module_for_test(admin);

        // Initialize AptosCoin
        let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(framework);
        let coins = coin::mint<AptosCoin>(1000000000, &mint_cap);
        // aptos_account::deposit_coins(signer::address_of(admin), coins);
        aptos_account::deposit_coins(USER, coins);
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    fun setup_sale_config(admin: &signer, framework: &signer) {
        // Setup
        setup_test(admin, framework);

        // Set sale period
        let start_time = timestamp::now_seconds();
        let end_time = start_time + 1000;
        rova_sale::set_sale_period(admin, start_time, end_time);

        // Unpause
        rova_sale::set_pause(admin, false);
    }

    fun generate_signature(
        admin: &signer,
        user: &signer,
        launch_participation_id: vector<u8>,
        token_amount: u64,
        payment_amount: u64
    ): (address, vector<u8>, vector<u8>) {
        let user_addr = signer::address_of(user);
        // Create message
        let message = vector::empty<u8>();
        vector::append(&mut message, bcs::to_bytes(&user_addr));
        vector::append(&mut message, bcs::to_bytes(&payment_amount));
        vector::append(&mut message, bcs::to_bytes(&token_amount));
        vector::append(&mut message, bcs::to_bytes(&launch_participation_id));

        // Sign message using signer
        let (sk, pk) = ed25519::generate_keys();
        let signature = ed25519::sign_arbitrary_bytes(&sk, message);
        let signature_bytes = ed25519::signature_to_bytes(&signature);
        let public_key_bytes = ed25519::validated_public_key_to_bytes(&pk);
    
        // Add signer
        let signer_addr = from_bcs::to_address(ed25519::validated_public_key_to_authentication_key(&pk));
        rova_sale::manage_role(admin, 1, signer_addr, true);

        (signer_addr, signature_bytes, public_key_bytes)
    }
}
