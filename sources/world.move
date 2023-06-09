
// A set, which is acutally unordered
module wom_addr::set {
    use std::vector;

    const EVALUE_EXISTS: u64 = 1;

    struct Set<Element> has copy, drop, store {
        data: vector<Element>,
    }

    public fun empty<Element>() : Set<Element> {
        Set<Element> {
            data: vector::empty(),
        }
    }

    public fun from_vector<Element: drop + copy>(v: vector<Element>): Set<Element> {
        let set = empty<Element>();
        vector::for_each_ref(&v, |value| {
            let (found, _) = vector::index_of(&set.data, value);
            if (!found) {
                add(&mut set, value);
            }
        });
        set
    }

    public fun value_exists<Element>(set: &Set<Element>, value: &Element): bool {
        let (found, _) = vector::index_of(&set.data, value);
        found
    }

    public fun add<Element: copy>(set: &mut Set<Element>, value: &Element) {
        assert!(!value_exists(set, value), EVALUE_EXISTS);
        vector::push_back(&mut set.data, *value);
    }

    public fun remove<Element: drop>(set: &mut Set<Element>, value: &Element) {
        let (found, index) = vector::index_of(&set.data, value);
        assert!(found, EVALUE_EXISTS);
        vector::remove(&mut set.data, index);
    }

    public fun borrow_data<Element>(set: &Set<Element>): &vector<Element> {
        &set.data
    }

    public inline fun for_each_ref<Element>(set: &Set<Element>, f: |&Element|) {
        vector::for_each_ref(&set.data, |v| f(v));
    }

    public fun intersect<Element: copy>(set_one: &Set<Element>, set_two: &Set<Element>): Set<Element> {
        let intersection = empty<Element>();
        for_each_ref(set_one, |value| {
            if (value_exists(set_two, value)) add(&mut intersection, value);
        });
        intersection
    }
}

module wom_addr::world {
    use aptos_framework::account;
    use std::vector;
    use wom_addr::set::{Self, Set};
    use std::signer;
    use std::option;
    use std::option::Option;

    const EWORLD_UNKNOWN: u64 = 1;
    const ECOMPONENT_TYPE_INVALID: u64 = 2;

    struct Component<ComponentId: store> has store, copy, drop {
        component_id: ComponentId,
        data: vector<u8>
    }

    struct Entity<ComponentId: store> has store, copy, drop {
        types: Option<Set<ComponentId>>,
        components: Option<vector<Component<ComponentId>>>,
    }

    struct GenesisEvent has key {
        genesis_addr: address,
    }

    struct CreateEvent has key {
        entity_id: u64,
    }

    struct AddEvent<ComponentId> has key {
        entity_id: u64,
        component_id: ComponentId,
    }

    struct World<ComponentId: store> has key {
        entities: vector<Entity<ComponentId>>,
        pool: vector<u64>,
        signer_capability: account::SignerCapability,
    }

    // Create a world to live in
    public entry fun genesis<ComponentId: store>(creator: &signer, seed: vector<u8>) {
        let (genesis_signer, signer_capability) = account::create_resource_account(creator, seed);

        let world = World<ComponentId> {
            entities: vector::empty(),
            pool: vector::empty(),
            signer_capability,
        };

        move_to(
            &genesis_signer,
            world
        );

        move_to(creator, GenesisEvent {
            genesis_addr: signer::address_of(&genesis_signer),
        });
    }

    #[view]
    public fun is_world<ComponentId: store>(world: address): bool {
        exists<World<ComponentId>>(world)
    }

    #[view]
    public fun is_entity<ComponentId: store>(world: address, entity_id: u64): bool acquires World {
        if (is_world<ComponentId>(world)) {
            let world = borrow_global<World<ComponentId>>(world);
            if (entity_id > vector::length(&world.entities)) return false;
            option::is_some(&vector::borrow(&world.entities, entity_id).types)
        } else {
            false
        }
    }

    fun entity_to_index(entity_id: u64): u64 {
        entity_id - 1
    }

    fun index_to_entity(index: u64): u64 {
        index + 1
    }

    // Create entity in the world
    public entry fun create<ComponentId: store>(signer: &signer, world: address) acquires World, CreateEvent {
        assert!(exists<World<ComponentId>>(world), EWORLD_UNKNOWN);
        let world = borrow_global_mut<World<ComponentId>>(world);
        // Grab an entity that has been deleted and use the same slot
        let index = if (!vector::is_empty(&world.pool)) {
            let index = vector::pop_back(&mut world.pool);
            vector::insert(&mut world.entities, index, Entity {
                types: option::none(),
                components: option::none(),
            });
            index
        } else {
            vector::push_back(&mut world.entities, Entity {
                types: option::none(),
                components: option::none(),
            });
            vector::length(&world.entities) - 1
        };

        if (exists<CreateEvent>(signer::address_of(signer))) {
            borrow_global_mut<CreateEvent>(signer::address_of(signer)).entity_id = index_to_entity(index);
        } else {
            move_to(signer, CreateEvent {
                entity_id: index_to_entity(index),
            });
        }
    }

    // Add component to entity
    public entry fun add<ComponentId: store + copy + drop>(signer: &signer, world: address, entity_id: u64, component_id: ComponentId, data: vector<u8>) acquires World, AddEvent {
        assert!(exists<World<ComponentId>>(world), EWORLD_UNKNOWN);
        let index = entity_to_index(entity_id);
        let world = borrow_global_mut<World<ComponentId>>(world);
        let entity = vector::borrow_mut(&mut world.entities, index);
        if (option::is_none(&entity.types)) {
            entity.types = option::some(set::empty<ComponentId>());
        };
        if (option::is_none(&entity.components)) {
            entity.components = option::some(vector::empty<Component<ComponentId>>());
        };
        // Register the new type in the entity, will abort if already registered
        set::add(option::borrow_mut(&mut entity.types), &component_id);
        vector::push_back(option::borrow_mut(&mut entity.components), Component<ComponentId> {
            component_id,
            data,
        });

        if (exists<AddEvent<ComponentId>>(signer::address_of(signer))) {
            let event = borrow_global_mut<AddEvent<ComponentId>>(signer::address_of(signer));
            event.component_id = component_id;
            event.entity_id = index_to_entity(index);
        } else {
            move_to(signer, AddEvent<ComponentId> {
                entity_id: index_to_entity(index),
                component_id,
            });
        }
    }

    // Providing a query of components we are interested in return a set of entity identities
    #[view]
    public fun query<ComponentId: store + copy + drop>(world: address, mask: vector<ComponentId>) : vector<u64> acquires World {
        assert!(exists<World<ComponentId>>(world), EWORLD_UNKNOWN);
        let mask = set::from_vector<ComponentId>(mask);
        let world = borrow_global_mut<World<ComponentId>>(world);
        let found = vector::empty<u64>();
        let index = 0;
        vector::for_each_ref<Entity<ComponentId>>(
            &world.entities,
            |entity| {
                let entity: &Entity<ComponentId> = entity;
                let types = option::borrow<Set<ComponentId>>(&entity.types);
                if (!vector::is_empty(set::borrow_data(&set::intersect<ComponentId>(types, &mask)))) {
                    vector::push_back(&mut found, index_to_entity(index));
                };
                index = index + 1;
            }
        );
        found
    }

    // Destroy entity. The entity is cleared maintaining the slot in the vector and the index cached for reuse
    public entry fun destroy<ComponentId: store>(world: address, entity_id: u64) acquires World {
        assert!(exists<World<ComponentId>>(world), EWORLD_UNKNOWN);
        let index = entity_to_index(entity_id);
        let world = borrow_global_mut<World<ComponentId>>(world);
        // Clear slot
        vector::insert(&mut world.entities, index, Entity {
            types: option::none(),
            components: option::none(),
        });

        // Save slot in pool for reuse
        vector::push_back(&mut world.pool, index);
    }

    #[test(signer = @0x1)]
    public fun test_create_world(signer: &signer) acquires GenesisEvent {
        genesis<u8>(signer, vector::empty<u8>());
        assert!(exists<GenesisEvent>(signer::address_of(signer)), 0);
        let genesis_event = borrow_global<GenesisEvent>(signer::address_of(signer));
        assert!(is_world<u8>(genesis_event.genesis_addr), 0);
    }

    #[test(signer = @0x1)]
    public fun test_create_entity(signer: &signer) acquires GenesisEvent, World, CreateEvent {
        genesis<u8>(signer, vector::empty<u8>());
        let genesis_event = borrow_global<GenesisEvent>(signer::address_of(signer));
        create<u8>(signer, genesis_event.genesis_addr);
        let create_event = borrow_global<CreateEvent>(signer::address_of(signer));
        assert!(create_event.entity_id == 1, 0);
        create<u8>(signer, genesis_event.genesis_addr);
        let create_event = borrow_global<CreateEvent>(signer::address_of(signer));
        assert!(create_event.entity_id == 2, 0);
    }

    #[test(signer = @0x1)]
    public fun test_create_add_component(signer: &signer) acquires GenesisEvent, World, CreateEvent, AddEvent {
        genesis<u8>(signer, vector::empty<u8>());
        let genesis_event = borrow_global<GenesisEvent>(signer::address_of(signer));
        create<u8>(signer, genesis_event.genesis_addr);
        let component_id = 1u8;
        let entity_id = 1;
        add(signer, genesis_event.genesis_addr, entity_id, component_id, b"speed component");
        let add_event = borrow_global<AddEvent<u8>>(signer::address_of(signer));
        assert!(add_event.entity_id == entity_id, 0);
        assert!(add_event.component_id == component_id, 0);
        component_id = 2;
        add(signer, genesis_event.genesis_addr, entity_id, component_id, b"velocity component");
        let add_event = borrow_global<AddEvent<u8>>(signer::address_of(signer));
        assert!(add_event.entity_id == entity_id, 0);
        assert!(add_event.component_id == component_id, 0);
    }

    #[test(signer = @0x1)]
    public fun test_query_components(signer: &signer) acquires GenesisEvent, World, CreateEvent, AddEvent {
        genesis<u8>(signer, vector::empty<u8>());
        let genesis_event = borrow_global<GenesisEvent>(signer::address_of(signer));
        let component_one_id = 1u8;
        let component_two_id = 2u8;
        let first_entity = 1;
        let second_entity = 2;
        // Create first entity
        create<u8>(signer, genesis_event.genesis_addr);
        // Add two components to first entity
        add(signer, genesis_event.genesis_addr, first_entity, component_one_id, b"speed component");
        add(signer, genesis_event.genesis_addr, first_entity, component_two_id, b"velocity component");
        // Create second entity
        create<u8>(signer, genesis_event.genesis_addr);
        // Add component two to entity two
        add(signer, genesis_event.genesis_addr, second_entity, component_two_id, b"velocity component");

        // We have two entities, one with component 1 and 2 and the second entity with component 2

        // Query entities that have component 1
        {
            let mask = vector<u8>[component_one_id];
            let result = query(genesis_event.genesis_addr, mask);

            assert!(vector::length(&result) == 1, 0);
            assert!(vector::borrow(&result, 0) == &first_entity, 0);
        };

        // Query entities that have component 2
        {
            let mask = vector<u8>[component_two_id];
            let result = query(genesis_event.genesis_addr, mask);

            assert!(vector::length(&result) == 2, 0);
            assert!(vector::borrow(&result, 0) == &first_entity, 0);
            assert!(vector::borrow(&result, 1) == &second_entity, 0);
        };
    }
}