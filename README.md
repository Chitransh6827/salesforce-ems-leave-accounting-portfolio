# Salesforce Employee Management System

A Salesforce DX portfolio prototype for employee operations, with a focused Phase 3A leave-accounting implementation. The leave-accounting work demonstrates how a controlled Apex service can coordinate leave requests, balances, and an immutable debit/restoration ledger.

> **Prototype status:** local source only. This project has not been deployed to or verified in a Salesforce org, and its Apex has not been confirmed to compile or pass tests in Salesforce. It is not production-ready. No Salesforce org was accessed or changed during this final local release pass.

## Problem and scope

Leave balances should not be changed independently of the request they represent. This prototype puts managed request transitions behind a permission-gated service, validates policy and balance state before accounting, saves an active debit snapshot, and records immutable accounting events. The broader EMS source also contains employee, department, attendance, payroll, and other HR metadata.

The leave-accounting implementation is **backend-only**: there is no Lightning Web Component or other end-user request UI in this project. `LeaveAccountingEntryPoint` is an Aura-enabled Apex adapter, not a UI by itself. Managed operations require a trusted operator with `Manage_Leave_Accounting`.

## Architecture and data model

| Component                            | Responsibility                                                                                                                                           |
| ------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `Leave_Request__c`                   | Employee request, dates, type, status, approver, cohort, and current-cycle snapshot.                                                                     |
| `Leave_Balance__c`                   | Employee/type/year entitlement and used amount. Remaining leave is formula-derived.                                                                      |
| `Leave_Accounting_Event__c`          | Immutable Debit and Restoration history, with a unique event key and a restoration-to-debit reference.                                                   |
| `Leave_Policy__mdt`                  | Policy-derived entitlement amounts for Paid, Casual, Sick, and Unpaid.                                                                                   |
| `LeaveAccountingService`             | Permission-gated request lifecycle, policy provisioning, row locking, overlap detection, debit/restoration, and trigger authorization.                   |
| `LeaveAccountingEntryPoint`          | Narrow Aura-callable adapter to the service. It is not connected to a local UI component.                                                                |
| `LeaveBalanceProvisioningAction`     | Invocable action used by the employee-created Flow to provision a single employee.                                                                       |
| Request, balance, and event triggers | Reject unsupported direct writes and protect accounting state.                                                                                           |
| Flows                                | Local employee provisioning and manager/department-head approver assignment. Legacy approval-date and deduction Flows are inactive in this local source. |

The request-to-balance relationship is represented by the active snapshot’s `Active_Charged_Balance__c` lookup. Ledger events link to the request and the balance; Restoration events additionally reference the Debit event they reverse.

## Managed leave lifecycle

- Requests use inclusive calendar-day duration from 1 through 365. The balance year is derived from the request start date.
- Submission accepts only employee, dates, leave type, and reason. The service assigns Managed cohort, Pending status, application date, approver, and accounting history fields.
- Pending requests can be edited or cancelled through the service. Pending and Approved requests for one employee cannot overlap; employee locking serializes service operations before conflict checks.
- Paid approval requires exactly one matching employee/type/start-year balance with valid identity and numeric state. It debits the inclusive day count, saves the exact balance and amount in the active snapshot, and creates a unique Debit event.
- Unpaid approval creates no debit/restoration events and does not use a leave balance.
- Approved cancellation and rejection restore the exact saved debit to the original balance, create a linked Restoration event, and clear active snapshots.
- Cancelled reapproval starts a new cycle only after the prior cycle is verified as restored. First approval after Pending → Cancelled is allowed. Rejected → Approved is blocked.
- Missing, duplicate, malformed, inconsistent, or insufficient balances fail closed. Historical or unclassified requests are not processed or reclassified by this prototype.

## Security and trust model

One custom permission, `Manage_Leave_Accounting`, authorizes submission, pending edits/cancellation, approval, approved cancellation/rejection, and provisioning. Assign it only to trusted accounting operators. The service does not require that approver actions come from the employee named in `Approver__c`; that field is routing information, not an authorization check.

The service class uses `with sharing`. After the custom-permission gate, integrity-critical balance, overlap, and ledger-history queries explicitly use SOQL system mode so record sharing cannot hide conflicts or history. Apex DML runs in system mode by default; this prototype does not enforce CRUD/FLS with user-mode DML or `stripInaccessible`. Therefore the custom permission and its tightly restricted assignment are the service authorization boundary, not a replacement for a complete production CRUD/FLS design. Trigger intent checks are defense in depth, not protection against privileged administrators, changed code, disabled triggers, or other trusted system automation.

## Local setup and optional sandbox evaluation

Local source inspection does not require Salesforce authentication. The project targets Salesforce API 67.0.

For an **independently authorized personal sandbox only**:

1. Install a supported Salesforce CLI and Node.js version.
2. Authenticate explicitly against the sandbox login host:

   ```powershell
   sf org login web --instance-url https://test.salesforce.com --alias ems-phase3a-sandbox
   ```

3. Verify the authenticated org is a sandbox before proceeding:

   ```powershell
   sf data query --target-org ems-phase3a-sandbox --query "SELECT IsSandbox FROM Organization"
   ```

   Stop unless the result is `true`. Never substitute a production org or the production login host.

4. Review the metadata and limitations, then deploy only to that verified sandbox:

   ```powershell
   sf project deploy start --target-org ems-phase3a-sandbox --source-dir force-app
   ```

5. Assign the `EMS Leave Accounting Operator` permission set only to a trusted sandbox operator. Verify Flow execution context, CRUD/FLS expectations, and all automation before trying employee provisioning.

These are instructions for a future project user; **no login, query, deployment, or test against Salesforce was performed for this release**. The local configuration points to `https://test.salesforce.com` to reduce accidental production authentication.

## Tests and local checks

- For local JavaScript tooling, install Node.js 22.13 or newer and run `npm ci` from the project root.
- `npm test` invokes the configured LWC Jest runner. There are currently no LWC components or related tests, so this does not test Apex.
- Apex scenarios are defined in `LeaveAccountingServiceTest.cls`. Run them only after reviewing and deploying to a verified sandbox:

  ```powershell
  sf apex run test --target-org ems-phase3a-sandbox --class-names LeaveAccountingServiceTest --wait 20
  ```

- No Salesforce compilation or Apex test execution has been performed. XML parsing and editor diagnostics, if run locally, are not Salesforce compile evidence.

## Known limitations

- **No user interface:** the Aura adapter is not called by a bundled LWC or Aura component. This is a backend prototype, not a ready-to-use employee or manager workflow.
- **Provisioning is synchronous and single-employee only.** The employee-created Flow invokes the action; multi-employee invocations fail explicitly and may fail the originating employee transaction. The effective permission context and failure behavior need sandbox testing.
- **No async grouping or bounded lock retries** are implemented. Actual row-lock serialization and concurrent overspend prevention require parallel sandbox transactions.
- **No historical manifest, cutover finalization, recovery tooling, or migration/backfill.** Legacy and unclassified requests remain unsupported and unchanged.
- The local `Auto_Set_Leave_Approval_Date` and `Auto_Deduct_Leave_Balance_on_Approval` Flow sources are marked Inactive. This is only local metadata, not evidence of any org’s active Flow state.
- A downstream automation fault, real UI/API access, effective permissions, and Salesforce transaction rollback have not been demonstrated in an org.
- No license has been selected. All rights remain with their respective owners; no open-source reuse permissions are granted by this repository until a license is deliberately chosen.

See [the detailed leave-accounting notes](docs/leave-accounting-prototype.md) for test-source coverage and additional verification boundaries.
