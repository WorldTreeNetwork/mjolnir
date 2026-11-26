## ADDED Requirements

### Requirement: A signed-in mj user can request a room token

`mj relay token <room> <participant> [--api <url>] [--json]` SHALL use normal controller API resolution and saved user session handling. The command SHALL validate the existing segment syntax and POST an empty JSON object to `/api/relay/rooms/:room/participants/:participant/token`. On success it SHALL write the token followed by a newline to stdout, or, with `--json`, the raw successful JSON response body. The command SHALL mint only on explicit invocation and SHALL NOT log or persist the token or response body. For invalid inputs, failed requests and invalid responses, it SHALL exit nonzero with empty stdout and a diagnostic that contains no credentials or response body.

#### Scenario: Mint using a saved session

- GIVEN a saved eligible user session and a configured mint
- WHEN the user requests a token for room `demo` and participant `alice`
- THEN the command POSTs to the existing mint route using that session and prints only the issued token plus a newline
- AND a request with `--json` prints the successful response body as returned

#### Scenario: Mint is refused

- GIVEN the mint API returns an error
- WHEN the user requests a room token with either output mode
- THEN the command returns a nonzero exit code and empty stdout
- AND stderr identifies the HTTP status without printing the response body
