- Keycloak realm export (automated daily since round 8 iter 68 -
| Full system restore |; | Import pool, clone repo, restore from B2 |
- Monthly (1st, 03:00): `run-restore-test.sh` inside backup-cron-trigger -
  test silently never ran; `env: can't execute 'bash'`).
  `$$` in .env; compose interpolates `$VAR`, unescaped `$` yields
  is unreliable for Go binaries with pure resolvers; services pin
  `key remove` for rotation; no repo migration needed). The B2