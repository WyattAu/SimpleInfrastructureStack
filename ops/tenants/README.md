Per-tenant stacks for paying customers. Each tenant gets an isolated stack -
its own database, its own data directory, its own credentials; provisioned
    ├── documents/               # Paperless-ngx ; document management
    ├── files/                   # Ferro         ; file storage (our Rust product)
    └── photos/                  # Immich        ; photo library
tenants; customers authenticate against their own accounts.
or export. `TENANT_PRUNE=1` applies the shared retention policy; note that
Honest status per service; do not sell a template before validating it.
| 40 | tight; watch memory, most `documents` tenants want 2G |