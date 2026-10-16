## ADDED Requirements

### Requirement: SSH plan reads files and does not mutate the host
The system SHALL start a Forge Host worker for `POST /api/forge/hosts` when `transport` is `ssh`.
The system SHALL build that host's plan from file observes read through one OpenSSH ControlMaster connection for that host.
The system SHALL NOT write, adopt, or delete remote resources as part of plan.
The system SHALL keep apply over SSH unimplemented.

#### Scenario: Plan prints a diff from a remote file
- GIVEN a host registered with transport `ssh` and one declared file resource
- WHEN the operator runs plan for that host
- THEN the diff reflects the remote file contents
- AND the remote host has no new writes from that plan

#### Scenario: Apply is still refused
- GIVEN a host registered with transport `ssh`
- WHEN apply is requested for one of its resources
- THEN the result is the not-implemented SSH error
- AND the remote file is unchanged

### Requirement: The SSH transport runs only the observe read
The system SHALL execute only the file-read command required by an observe path.
The system SHALL refuse any other remote command before it runs.

#### Scenario: A non-read command is refused
- GIVEN a connected SSH host
- WHEN a command other than the observe file read is requested
- THEN the command is refused
- AND ssh is not invoked for it

### Requirement: A dropped SSH connection backs off inside the host worker
The system SHALL keep the Forge supervisor running when a host's multiplexed connection closes.
The system SHALL back off that Host worker instead of crashing it.

#### Scenario: Disconnect does not take down Forge
- GIVEN a running SSH host worker
- WHEN its ControlMaster connection closes
- THEN that worker enters backoff
- AND the Forge supervisor is still running
- AND another host can still plan
