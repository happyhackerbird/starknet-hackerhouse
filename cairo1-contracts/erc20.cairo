
#[contract]
mod erc_20 {
    use zeroable::Zeroable;
    use starknet::get_caller_address;
    use starknet::contract_address_const;
    use starknet::ContractAddress;
    use starknet::ContractAddressZeroable;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        decimals: u8,
        total_supply: u256,
        balances: LegacyMap::<ContractAddress, u256>,
        allowances: LegacyMap::<(ContractAddress, ContractAddress), u256>,
    }

#[event]
fn Transfer(from: ContractAddress, to: ContractAddress, value: u256) {}

#[event]
fn Approval(owner: ContractAddress, spender: ContractAddress, value: u256) {}

    #[constructor]
fn constructor(
    name_: felt252,
    symbol_: felt252,
    decimals_: u8,
    initial_supply: u256,
    recipient: ContractAddress
) {
    name::write(name_);
    symbol::write(symbol_);
    decimals::write(decimals_);
    assert(!recipient.is_zero(), 'ERC20: mint to the 0 address');
    total_supply::write(initial_supply);
    balances::write(recipient, initial_supply);
    Transfer(contract_address_const::<0>(), recipient, initial_supply);
}
#[external]
fn transfer(recipient: ContractAddress, amount: u256) {
    let sender = get_caller_address();
    transfer_helper(sender, recipient, amount);
}

fn transfer_helper(sender: ContractAddress, recipient: ContractAddress, amount: u256) {
    assert(!sender.is_zero(), 'ERC20: transfer from 0');
    assert(!recipient.is_zero(), 'ERC20: transfer to 0');
    balances::write(sender, balances::read(sender) - amount);
    balances::write(recipient, balances::read(recipient) + amount);
    Transfer(sender, recipient, amount);
}



}