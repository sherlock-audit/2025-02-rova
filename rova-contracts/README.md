# Rova Launch Contracts

Rova is a platform for allowing users to participate in token launches. These contracts are used to facilitate participation and payment processing for Rova token sale launches.

## Definitions

### Launch

The [`Launch`](src/Launch.sol) contract is the main contract that manages the state and launch groups and represents a single project token sale launch. It will be deployed for each launch and will be upgradable.

The goal of this contract is to facilitate launch participation and payment processing for users, and is meant to be used in conjunction with our backend system to orchestrate different launch structures and additional validation requirements (e.g. KYC).

### Launch Groups

Launch groups allow for users to participate into different groups under a single launch. This allows for a more flexible participation system where there can be different rules for different groups, like different start and end times, maximum allocations, launch structures (FCFS, raffles), payment currencies (ERC20), etc. Participation eligibility for groups is primarily done in our backend since it requires offchain verification of user information like KYC status, social accounts, etc.

Since requests must be first "approved" by our backend, backend signer(s) with the signer role will sign all state-changing user requests. These signatures will be submitted in request calldata and validated in the `Launch` contract.

The `LaunchGroupSettings` struct contains the settings for the launch group to allow for different launch structures. It also contains the status of the launch group to track launch group lifecycle. Since launch groups will need to be tracked in our backend, a launch group identifier from our backend is associated with each launch group registered within the `Launch` contract.

### Payment Currency

Each launch group can have a multiple accepted payment currencies. These are registered in a mapping of launch group id to currency address to currency config. Users will specify the currency they want to use when participating in a launch group and we will validate the requested token amount and payment amount against the configured token price per currency.

### Launch Participation

When a user participates in a launch group, Rova backend will generate a launch participation identifier that is unique to the user, launch group, and launch. This id will be used to identify the participation in all state-changing functions and across a launch groups' lifecycle.

Rova users can link and use different wallets to fund their participation, so a backend-generated user identifier is linked to all participations for a user. Validations are done against that user identifier instead of the calling wallet address.

### Roles

The `Launch` contract uses the OpenZeppelin Access Control Enumerable library to manage roles.

- `DEFAULT_ADMIN_ROLE`: The default admin role, role admin for all other roles except `WITHDRAWAL_ROLE`.
- `MANAGER_ROLE`: The manager role for the launch, can update launch group settings and status.
- `OPERATOR_ROLE`: The operator role for the launch. This will be the role for automated actions like selecting winners for a raffle or auction or performing batch refunds.
- `SIGNER_ROLE`: The signer role for the launch. This will be the role for signing all user requests.
- `WITHDRAWAL_ROLE`: The withdrawal role for the launch. This will be the role for withdrawing funds to the withdrawal address. It is it's own role admin.

### Launch Group Status

This section describes the statuses of and the lifecycle of a launch group.

#### PENDING

Launch group is pending:

- This should be the initial status of a launch group when we set it up to allow us to review and confirm all settings before making it active.
- This is the only status where update to `finalizesAtParticipation` in launch group settings is allowed. This is to prevent unexpected behavior when the launch group is active since once a user's participation is finalized, it can't be updated and the deposited funds are added to the withdrawable balance.

#### ACTIVE

Launch group is active:

- Users can participate in the launch group between `startsAt` and `endsAt` timestamps.
- Users can make updates to or cancel their participation until `endsAt` if the launch group `finalizesAtParticipation` setting is false.
- Participation can be finalized during this status as well by operators, such as selecting winners for a raffle or auction. Once finalized, users can't make updates to or cancel their participation.

#### PAUSED

Launch group is paused:

- This allows us to pause actions on a launch group without having to update the status to one that may result in side effects since the other statuses control permissioning for other write actions.
- Any action that requires ACTIVE or COMPLETED status will revert, like participation registration, updates, selecting winners, refunds, or withdrawals.
- This is separate from the launch contract's `paused` state since it applies to individual launch groups.

#### COMPLETED

Launch group is completed:

- Users can claim refunds if their participation is not finalized, e.g. they didn't win a raffle or auction. Operators can help batch refund user participations that are not finalized too.
- Withdrawable balances per payment currency can be withdrawn to the withdrawal address once all launch groups under the launch are completed.

## Development

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

For coverage:

```shell
$ forge coverage --ir-minimum
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

Set `PRIVATE_KEY` in `.env` and run:

```shell
$ forge script script/Deploy.s.sol:DeployScript --rpc-url <your_rpc_url> --broadcast
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
