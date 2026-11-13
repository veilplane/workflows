```sh
cargo add vp-{{API}}-sdk
```

Or in `Cargo.toml` (the TLS backend is a feature: `native-tls`, the default, or `rustls`):

```toml
[dependencies]
vp-{{API}}-sdk = { version = "{{MAJOR}}", default-features = false, features = ["rustls"] }
```

```rust
use vp_{{API_IDENT}}_sdk::apis::configuration::Configuration;

let config = Configuration {
    bearer_access_token: Some(std::env::var("VEILPLANE_TOKEN")?),
    ..Configuration::default()
};
```
