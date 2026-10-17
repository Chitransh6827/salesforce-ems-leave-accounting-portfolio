# Leave accounting prototype

## Status

Local Salesforce DX source only. The Apex has not been confirmed to compile or pass tests in Salesforce, and the metadata has not been verified in an org. This is not production-ready. No Salesforce org was accessed or changed during this final local release pass.

## Supported managed workflow

`LeaveAccountingEntryPoint` exposes narrow Aura methods for submission, pending edit/cancel, approval, and approved cancellation/rejection. It is a backend adapter only; there is no bundled LWC or end-user UI.

`LeaveAccountingService` requires `Manage_Leave_Accounting` for every operation. The same permission deliberately covers all operations; there is no distinct submitter/approver permission and the service does not authorize approval by comparing the current user to `Approver__c`. Assign it only to trusted accounting operators.

Submission accepts employee ID, dates, leave type, and reason. The service assigns Managed cohort, Pending status, `Applied_Date__c`, approver, and accounting fields. The request trigger verifies this authorized payload and protects status, employee, dates, application date, type, cohort, snapshots, cycle/history values, approver, and approval date from direct changes. Request deletion and undelete are denied. Balance and ledger triggers restrict balance provisioning/usage writes and event creation/mutation/deletion/undelete to the service boundary.

The class uses `with sharing`, but integrity-critical overlap, balance-uniqueness, and ledger-history queries explicitly use `WITH SYSTEM_MODE` after the permission gate. This prevents a caller’s record sharing from hiding relevant conflicts or event history. Apex DML runs in system mode by default; CRUD/FLS is not separately enforced with user-mode operations or `stripInaccessible`. This is a privileged trusted-operator model, not a general employee security design.

## Rules and accounting behavior

- Inclusive calendar duration is 1–365 days; the accounting year comes from Start Date.
- Pending and Approved requests for the same employee cannot overlap. Service operations lock the employee before checking conflicts.
- Paid approval requires exactly one matching employee/type/start-year balance, validates key and balance values, debits the exact duration, saves the balance and amount snapshot, and writes a unique Debit event.
- Unpaid approval bypasses balance accounting and writes no ledger events.
- Approved cancellation/rejection restores the saved amount to the saved balance, writes a linked Restoration event, clears active snapshots, and clears the approval date.
- Pending cancellation has no accounting events. Pending → Cancelled → Approved is allowed on a request with no prior cycle. Previously approved Cancelled requests may start a new cycle only after the earlier cycle is verified restored. Rejected → Approved is blocked.
- Unique event keys and trigger checks prevent ordinary duplicate service processing. Balance/event consistency is checked structurally; the service does not reconcile `Used_Leaves__c` against the aggregate ledger.
- Savepoints wrap approval and approved cancellation/rejection. Test-only failure injection occurs after the event and request writes and verifies local service rollback in test source; this does not establish downstream Flow rollback behavior on Salesforce.

## Automation and unsupported records

- `Auto_Deduct_Leave_Balance_on_Approval` is marked Inactive in local metadata so it cannot compete with the managed service when this source is deployed as reviewed. This does not establish the status of any Flow in an org.
- `Auto_Set_Leave_Approval_Date` is marked Inactive locally. Managed approval dates are set by the service; keeping the legacy before-save writer active would conflict with the request trigger’s protected-field boundary.
- `Auto_Assign_Manager_as_Approver` is locally Active and uses manager first, then department head. The service applies the same fallback and rejects creation if no approver is resolved. Runtime Flow ordering still needs sandbox verification.
- The employee-created balance provisioning Flow is locally Active and calls `LeaveBalanceProvisioningAction`. The service supports one employee per invocation. A multi-employee Flow invocation throws clearly and may fail the originating employee transaction; verify its execution identity and bulk behavior before using it.
- Legacy and unclassified requests are refused by the managed service and are not transitioned, classified, repaired, or migrated. There is no legacy workflow, manifest, cutover finalization, or recovery tool in this prototype.

## Test-source coverage

`LeaveAccountingServiceTest` contains source cases for:

- `validatesInclusiveDurationBoundaries`
- `provisionsOnlyPolicyBalancesAndRejectsDirectBalanceInsert`
- `auraEntryPointUsesThePermissionGatedService`
- `unauthorizedOperationsAndProvisioningHaveNoEffects`
- `pendingEditValidatesChangesAndRejectsOverlaps`
- `invalidPolicyConfigurationsFailClosed`
- `approvalDebitsExactlyAndCancellationRestoresExactlyOnce`
- `pendingCancellationCanBeApprovedForTheFirstTime`
- `cancelledApprovalStartsFreshCycleAndRejectedApprovalIsBlocked`
- `unpaidApprovalDoesNotCreateAccountingEvents`
- `overlapIsRejectedAndAdjacentDatesAreAllowed`
- `insufficientBalanceFailsWithoutAccountingChanges`
- `missingDuplicateAndMalformedBalancesFailClosed`
- `nullNumericBalanceValuesFailClosed`
- `directRequestAndLedgerWritesAreRejected`
- `requestAndLedgerUndeleteAreRejected`
- `approvalRollbackAfterRequestAndDebitEventWrites`
- `restorationAndRejectionRollbackAfterRequestAndEventWrites`

These are test definitions, not execution evidence. Apex compilation and test results remain unverified. Concurrent transactions, lock-failure behavior, effective permissions, UI/API access, Flow ordering, and rollback caused by active downstream automation require an explicitly authorized sandbox.
