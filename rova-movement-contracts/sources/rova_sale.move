/// @title Rova sale contract
module rova_sale_addr::rova_sale {
    use std::bcs;
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_std::ed25519::{Self, UnvalidatedPublicKey};
    use aptos_std::from_bcs;
    use aptos_std::table::{Self, Table};
    use aptos_framework::coin;
    use aptos_framework::aptos_account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use aptos_framework::event::{Self};

    // ================================= Errors ================================= //
    /// Not admin
    const ENOT_ADMIN: u64 = 1;
    /// Not a role member
    const ENOT_ROLE_MEMBER: u64 = 2;
    /// Invalid signature
    const EINVALID_SIGNATURE: u64 = 3;
    /// Invalid launch participation id
    const EINVALID_LAUNCH_PARTICIPATION_ID: u64 = 4;
    /// Sale is paused
    const ESALE_PAUSED: u64 = 5;
    /// Sale not active
    const ESALE_NOT_ACTIVE: u64 = 6;
    /// Invalid sale period
    const EINVALID_SALE_PERIOD: u64 = 7;
    /// Unsupported role type
    const EUNSUPPORTED_ROLE_TYPE: u64 = 8;

    // ================================= Constants ================================= //

    /// Signer role identifier
    const ROLE_SIGNER: u8 = 1;
    /// Withdrawal role identifier
    const ROLE_WITHDRAWAL: u8 = 2;
    /// Manager role identifier
    const ROLE_MANAGER: u8 = 3;

    // ================================= Structs ================================= //

    /// Role management
    struct Roles has key {
        signer_role: vector<address>,
        withdrawal_role: vector<address>,
        manager_role: vector<address>,
    }

    /// Sale configuration
    struct SaleConfig has key {
        paused: bool,
        launch_participation_registry: Table<vector<u8>, bool>,
        withdrawal_address: address,
        starts_at: u64,
        ends_at: u64
    }

    // ================================= Events ================================= //

    #[event]
    struct FundingEvent has drop, store {
        user: address,
        amount: u64,
        tokens: u64,
    }

    #[event]
    struct WithdrawalEvent has drop, store {
        amount: u64,
        to: address,
    }

    #[event]
    struct RoleChangeEvent has drop, store {
        role_type: u8, // 1 = signer, 2 = withdrawal, 3 = manager
        address: address,
        is_added: bool,
    }

    #[event]
    struct PauseEvent has drop, store {
        is_paused: bool,
    }

    #[event]
    struct SalePeriodUpdateEvent has drop, store {
        starts_at: u64,
        ends_at: u64,
    }

    #[event]
    struct WithdrawalAddressUpdateEvent has drop, store {
        withdrawal_address: address,
        updated_by: address,
    }

    /// Initialize the sale contract
    fun init_module(admin: &signer) {
        let admin_addr = signer::address_of(admin);
        
        // Initialize roles
        move_to(admin, Roles {
            signer_role: vector::empty<address>(),
            withdrawal_role: vector::singleton(@withdrawal_addr),
            manager_role: vector::singleton(admin_addr),
        });

        // Initialize sale config
        move_to(admin, SaleConfig {
            // Pause by default so that manager can set config
            paused: true,
            launch_participation_registry: table::new<vector<u8>, bool>(),
            withdrawal_address: @withdrawal_addr,
            starts_at: 0,
            ends_at: 0
        });
    }

    // ================================= Entry Functions ================================= //

    /// Fund tokens with signature verification
    public entry fun fund(
        user: &signer,
        signature_bytes: vector<u8>,
        public_key_bytes: vector<u8>,
        launch_participation_id: vector<u8>,
        token_amount: u64,
        payment_amount: u64
    ) acquires SaleConfig, Roles {
        let user_addr = signer::address_of(user);
        let sale_config = borrow_global<SaleConfig>(@rova_sale_addr);

        // Verify sale is active
        let time_now = timestamp::now_seconds();
        assert!(time_now >= sale_config.starts_at && time_now <= sale_config.ends_at, error::invalid_state(ESALE_NOT_ACTIVE));

        // Check sale is not paused
        assert!(!sale_config.paused, error::invalid_state(ESALE_PAUSED));

        // Verify launch participation id hasn't been used (prevent replay)
        assert!(
            !has_launch_participation_id(launch_participation_id),
            error::invalid_argument(EINVALID_LAUNCH_PARTICIPATION_ID)
        );
        
        // Verify signature
        let signature = ed25519::new_signature_from_bytes(signature_bytes);
        let unvalidated_public_key = ed25519::new_unvalidated_public_key_from_bytes(public_key_bytes);
        let message = vector::empty<u8>();
        vector::append(&mut message, bcs::to_bytes(&user_addr));
        vector::append(&mut message, bcs::to_bytes(&payment_amount));
        vector::append(&mut message, bcs::to_bytes(&token_amount));
        vector::append(&mut message, bcs::to_bytes(&launch_participation_id));

        assert!(
            ed25519::signature_verify_strict(
                &signature,
                &unvalidated_public_key,
                message
            ),
            error::invalid_argument(EINVALID_SIGNATURE)
        );

        // Verify signer is authorized
        let derived_address = derive_address(&unvalidated_public_key); 
        let roles = borrow_global<Roles>(@rova_sale_addr);
        only_role_address(derived_address, roles.signer_role);

        // Transfer payment
        let coin = coin::withdraw<AptosCoin>(user, payment_amount);
        aptos_account::deposit_coins(@rova_sale_addr, coin);

        // Register launch_participation_id as used
        let sale_config = borrow_global_mut<SaleConfig>(@rova_sale_addr);
        table::add(&mut sale_config.launch_participation_registry, launch_participation_id, true);

        // Emit funding event
        event::emit(
            FundingEvent {
                user: user_addr,
                amount: payment_amount,
                tokens: token_amount
            }
        );
    }

    /// Withdraw funds
    public entry fun withdraw(
        caller: &signer,
        amount: u64
    ) acquires SaleConfig {        
        // Verify caller is admin
        only_admin(caller);

        // Transfer funds to withdrawal address
        let sale_config = borrow_global<SaleConfig>(@rova_sale_addr);
        let coin = coin::withdraw<AptosCoin>(caller, amount);
        aptos_account::deposit_coins(sale_config.withdrawal_address, coin);

        // Emit withdrawal event
        event::emit(
            WithdrawalEvent {
                amount,
                to: sale_config.withdrawal_address
            }
        );
    }

    /// Update withdrawal address (withdrawal role only)
    public entry fun set_withdrawal_address(
        caller: &signer,
        new_address: address
    ) acquires Roles, SaleConfig {        
        // Verify caller has withdrawal role
        let roles = borrow_global_mut<Roles>(@rova_sale_addr);
        only_role(caller, roles.withdrawal_role);

        // Update withdrawal address
        let sale_config = borrow_global_mut<SaleConfig>(@rova_sale_addr);
        sale_config.withdrawal_address = new_address;

        // Emit role change event
        let caller_addr = signer::address_of(caller);
        event::emit(
            WithdrawalAddressUpdateEvent {
                withdrawal_address: new_address,
                updated_by: caller_addr
            }
        );
    }

    /// Set sale starts at (manager role only)
    public entry fun set_sale_period(
        caller: &signer,
        new_starts_at: u64,
        new_ends_at: u64
    ) acquires Roles, SaleConfig {
        // Verify caller has manager role
        let roles = borrow_global_mut<Roles>(@rova_sale_addr);
        only_role(caller, roles.manager_role);

        assert!(new_starts_at < new_ends_at, error::invalid_argument(EINVALID_SALE_PERIOD));

        // Update sale period
        let sale_config = borrow_global_mut<SaleConfig>(@rova_sale_addr);
        sale_config.starts_at = new_starts_at;
        sale_config.ends_at = new_ends_at;

        // Emit sale period updated event
        event::emit(
            SalePeriodUpdateEvent {
                starts_at: new_starts_at,
                ends_at: new_ends_at
            }
        );
    }

    /// Pause/unpause funding (manager role only)
    public entry fun set_pause(
        caller: &signer,
        paused: bool
    ) acquires Roles, SaleConfig {
        // Verify caller has manager role
        let roles = borrow_global_mut<Roles>(@rova_sale_addr);
        only_role(caller, roles.manager_role);

        // Update pause state
        let sale_config = borrow_global_mut<SaleConfig>(@rova_sale_addr);
        sale_config.paused = paused;

        // Emit pause event
        event::emit(
            PauseEvent {
                is_paused: paused,
            }
        );
    }

    /// Add/remove addresses for roles (withdrawal role only)
    public entry fun manage_role(
        caller: &signer,
        role_type: u8,
        addr_to_manage: address,
        is_add: bool
    ) acquires Roles {
        let roles = borrow_global_mut<Roles>(@rova_sale_addr);

        // Get the appropriate role vector based on role type
        let role_vec = if (role_type == ROLE_SIGNER) {
            only_admin(caller);
            &mut roles.signer_role
        } else if (role_type == ROLE_WITHDRAWAL) {
            only_role(caller, roles.withdrawal_role);
            &mut roles.withdrawal_role
        } else if (role_type == ROLE_MANAGER) {
            only_admin(caller);
            &mut roles.manager_role
        } else {
            abort error::invalid_argument(EUNSUPPORTED_ROLE_TYPE)
        };

        manage_role_vector(role_vec, addr_to_manage, is_add);

        // Emit role change event
        event::emit(
            RoleChangeEvent {
                role_type,
                address: addr_to_manage,
                is_added: is_add
            }
        );
    }

    // ================================= View Functions ================================= //

    #[view]
    public fun is_paused(): bool acquires SaleConfig {
        borrow_global<SaleConfig>(@rova_sale_addr).paused
    }

    #[view]
    public fun get_withdrawal_address(): address acquires SaleConfig {
        borrow_global<SaleConfig>(@rova_sale_addr).withdrawal_address
    }

    #[view]
    public fun get_sale_period(): (u64, u64) acquires SaleConfig {
        (
            borrow_global<SaleConfig>(@rova_sale_addr).starts_at,
            borrow_global<SaleConfig>(@rova_sale_addr).ends_at
        )
    }

    #[view]
    public fun has_launch_participation_id(id: vector<u8>): bool acquires SaleConfig {
        table::contains(&borrow_global<SaleConfig>(@rova_sale_addr).launch_participation_registry, id)
    }

    #[view]
    public fun get_signer_role_members(): vector<address> acquires Roles {
        borrow_global<Roles>(@rova_sale_addr).signer_role
    }

    #[view]
    public fun get_withdrawal_role_members(): vector<address> acquires Roles {
        borrow_global<Roles>(@rova_sale_addr).withdrawal_role
    }

    #[view]
    public fun get_manager_role_members(): vector<address> acquires Roles {
        borrow_global<Roles>(@rova_sale_addr).manager_role
    }

    #[view]
    public fun has_role(addr: address, role_type: u8): bool acquires Roles {
        let roles = borrow_global<Roles>(@rova_sale_addr);
        if (role_type == ROLE_SIGNER) {
            vector::contains(&roles.signer_role, &addr)
        } else if (role_type == ROLE_WITHDRAWAL) {
            vector::contains(&roles.withdrawal_role, &addr)
        } else if (role_type == ROLE_MANAGER) {
            vector::contains(&roles.manager_role, &addr)
        } else {
            false
        }
    }

    // ================================= Helper Functions ================================= //

    fun only_admin(caller: &signer) {
        assert!(signer::address_of(caller) == @rova_sale_addr, error::permission_denied(ENOT_ADMIN));
    }

    fun only_role(caller: &signer, role_type: vector<address>) {
        only_role_address(signer::address_of(caller), role_type);
    }

    fun only_role_address(caller: address, role_type: vector<address>) {
        assert!(vector::contains(&role_type, &caller), error::permission_denied(ENOT_ROLE_MEMBER));
    }

    fun derive_address(public_key: &UnvalidatedPublicKey): address {
        // Create auth key using ed25519 scheme
        let auth_key = ed25519::unvalidated_public_key_to_authentication_key(public_key);
        // Convert auth key to address
        from_bcs::to_address(auth_key)
    }

    fun manage_role_vector(
        role_vec: &mut vector<address>,
        addr_to_manage: address,
        is_add: bool
    ) {
        let (found, index) = vector::index_of(role_vec, &addr_to_manage);
        if (is_add) {
            if (!found) {
                vector::push_back(role_vec, addr_to_manage);
            };
        } else if (found) {
            vector::remove(role_vec, index);
        };
    }

    // ================================= Tests ================================== //

    #[test_only]
    public fun init_module_for_test(sender: &signer) {
        init_module(sender);
    }
}
