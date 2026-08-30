# Security Policy

## Reporting a vulnerability

Do not open a public issue for a vulnerability that could cause unintended data deletion, path traversal, archive extraction outside the target, privilege misuse, or persistent Microsoft Defender exclusions.

Report security issues through GitHub private vulnerability reporting for this repository. Include:

- the affected command and ColdShelf version or commit;
- a minimal reproduction using non-sensitive test data;
- the expected and observed behavior;
- whether source data, an archive, a restore target, or Defender configuration was changed.

Do not include real archive contents, credentials, private paths, or personal data in a report.

## Scope

ColdShelf is a local Windows PowerShell tool. Its primary security boundary is preventing destructive source or archive deletion when validation is incomplete or ambiguous. Reports that demonstrate a bypass of path, reparse-point, quarantine ownership, manifest, TAR, restore-target, or Defender cleanup checks are in scope.
