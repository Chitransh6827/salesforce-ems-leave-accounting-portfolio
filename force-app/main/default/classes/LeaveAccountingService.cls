public with sharing class LeaveAccountingService {
    private enum Operation { SUBMIT, EDIT, APPROVE, CANCEL, REJECT, PROVISION }

    private class Intent {
        Operation operation;
        Map<Id, Leave_Request__c> expectedRequests = new Map<Id, Leave_Request__c>();
        List<Leave_Request__c> expectedInserts = new List<Leave_Request__c>();
        List<Leave_Balance__c> expectedBalanceInserts = new List<Leave_Balance__c>();
        List<Leave_Accounting_Event__c> expectedEvents = new List<Leave_Accounting_Event__c>();
        Map<Id, Decimal> expectedBalanceUsed = new Map<Id, Decimal>();
    }

    private static Intent activeIntent;
    @TestVisible private static Boolean skipPermissionCheckForTests = false;
    @TestVisible private static Boolean failAfterRequestUpdateForTests = false;
    @TestVisible private static Boolean allowRequestDeletionForTests = false;
    @TestVisible private static Boolean allowEventMutationForTests = false;

    private static final Set<String> REQUIRED_LEAVE_TYPES =
        new Set<String>{'Paid', 'Casual', 'Sick', 'Unpaid'};
    private static final Set<String> POSITIVE_ENTITLEMENT_TYPES =
        new Set<String>{'Paid', 'Casual', 'Sick'};

    public class AccountingException extends Exception {}

    public static Id submit(
        Id employeeId,
        Date startDate,
        Date endDate,
        String leaveType,
        String reason
    ) {
        requirePermission();
        if (employeeId == null) {
            throw new AccountingException('Employee is required.');
        }
        assertOneEmployee(new Set<Id>{employeeId});
        lockEmployees(new Set<Id>{employeeId});
        Id approverId = resolveApproverId(employeeId);
        if (approverId == null) {
            throw new AccountingException('An approver must be assigned before submitting leave.');
        }

        Leave_Request__c request = new Leave_Request__c(
            Employee__c = employeeId,
            Start_Date__c = startDate,
            End_Date__c = endDate,
            Applied_Date__c = Date.today(),
            Leave_Type__c = leaveType,
            Reason__c = reason,
            Status__c = 'Pending',
            Accounting_Cohort__c = 'Managed',
            Balance_Deducted__c = false,
            Last_Accounting_Cycle_Sequence__c = 0,
            Ever_Approved__c = false,
            Approver__c = approverId
        );
        validateRequest(request);
        assertNoOverlap(request, null);

        Intent intent = new Intent();
        intent.operation = Operation.SUBMIT;
        intent.expectedInserts.add(request.clone(false, true, false, false));
        activeIntent = intent;
        try {
            insert request;
        } finally {
            activeIntent = null;
        }
        return request.Id;
    }

    public static void provisionBalances(Id employeeId) {
        if (employeeId == null) {
            throw new AccountingException('Employee is required for balance provisioning.');
        }
        provisionBalances(new Set<Id>{employeeId});
    }

    public static void provisionBalances(Set<Id> employeeIds) {
        requirePermission();
        if (employeeIds == null || employeeIds.isEmpty()) {
            throw new AccountingException('At least one employee is required for balance provisioning.');
        }
        assertOneEmployee(employeeIds);
        lockEmployees(employeeIds);

        Map<String, Decimal> allowancesByType =
            validatePolicies(Leave_Policy__mdt.getAll().values());

        Integer currentYear = Date.today().year();
        List<Leave_Balance__c> existingBalances = [
            SELECT Id, Employee__c, Leave_Type__c, Leave_Year__c, Total_Leaves__c,
                   Used_Leaves__c, Leave_Balance_Key__c
            FROM Leave_Balance__c
            WHERE Employee__c IN :employeeIds AND Leave_Year__c = :currentYear
            WITH SYSTEM_MODE
            FOR UPDATE
        ];
        if (!existingBalances.isEmpty()) {
            throw new AccountingException('Balances already exist for at least one employee and year; provisioning will not overwrite or normalize them.');
        }

        List<Leave_Balance__c> balancesToInsert = new List<Leave_Balance__c>();
        for (Id employeeId : employeeIds) {
            for (String leaveType : allowancesByType.keySet()) {
                String balanceKey = expectedBalanceKey(employeeId, leaveType, currentYear);
                if (balanceKey.length() > 100) {
                    throw new AccountingException('A policy leave type produces a balance key longer than the field limit.');
                }
                balancesToInsert.add(new Leave_Balance__c(
                    Employee__c = employeeId,
                    Leave_Type__c = leaveType,
                    Leave_Year__c = currentYear,
                    Total_Leaves__c = allowancesByType.get(leaveType),
                    Used_Leaves__c = 0,
                    Leave_Balance_Key__c = balanceKey
                ));
            }
        }

        Intent intent = new Intent();
        intent.operation = Operation.PROVISION;
        for (Leave_Balance__c balance : balancesToInsert) {
            intent.expectedBalanceInserts.add(balance.clone(false, true, false, false));
        }
        activeIntent = intent;
        try {
            insert balancesToInsert;
        } finally {
            activeIntent = null;
        }
    }

    public static void editPending(
        Id requestId,
        Date startDate,
        Date endDate,
        String leaveType,
        String reason
    ) {
        requirePermission();
        Id employeeId = findEmployeeId(requestId);
        lockEmployees(new Set<Id>{employeeId});
        Leave_Request__c request = lockRequest(requestId);
        if (request.Status__c != 'Pending' || request.Ever_Approved__c) {
            throw new AccountingException('Only never-approved Pending requests can be edited.');
        }
        assertNoActiveSnapshot(request);
        request.Start_Date__c = startDate;
        request.End_Date__c = endDate;
        request.Leave_Type__c = leaveType;
        request.Reason__c = reason;
        validateRequest(request);
        assertNoOverlap(request, request.Id);
        saveRequest(request, Operation.EDIT, new List<Leave_Accounting_Event__c>());
    }

    public static void approve(Id requestId) {
        requirePermission();
        Savepoint transactionStart = Database.setSavepoint();
        try {
        Id employeeId = findEmployeeId(requestId);
        lockEmployees(new Set<Id>{employeeId});
        Leave_Request__c request = lockRequest(requestId);
        if (request.Status__c != 'Pending' && request.Status__c != 'Cancelled') {
            throw new AccountingException('Only Pending or Cancelled requests can be approved.');
        }
        if (request.Status__c == 'Pending' && request.Ever_Approved__c) {
            throw new AccountingException('Pending request approval history is inconsistent.');
        }
        if (request.Status__c == 'Cancelled') {
            if (!request.Ever_Approved__) {
                if (request.Last_Accounting_Cycle_Sequence__c != 0) {
                    throw new AccountingException('Never-approved Cancelled request has a prior cycle sequence.');
                }
                assertNoAccountingEvents(request.Id);
            } else if (request.Leave_Type__c == 'Unpaid') {
                assertNoAccountingEvents(request.Id);
            } else {
                assertLastCycleRestored(request);
            }
        } else {
            if (request.Last_Accounting_Cycle_Sequence__c != 0) {
                throw new AccountingException('Pending request has an unexpected prior accounting cycle.');
            }
            assertNoAccountingEvents(request.Id);
        }
        validateRequest(request);
        assertNoOverlap(request, request.Id);
        assertNoActiveSnapshot(request);

        List<Leave_Accounting_Event__c> events = new List<Leave_Accounting_Event__c>();
        if (request.Leave_Type__c != 'Unpaid') {
            Integer startYear = request.Start_Date__c.year();
            List<Leave_Balance__c> balances = [
                SELECT Id, Employee__c, Leave_Type__c, Leave_Year__c,
                       Total_Leaves__c, Used_Leaves__c, Leave_Balance_Key__c
                FROM Leave_Balance__c
                WHERE Employee__c = :request.Employee__c
                  AND Leave_Type__c = :request.Leave_Type__c
                  AND Leave_Year__c = :startYear
                WITH SYSTEM_MODE
                FOR UPDATE
            ];
            if (balances.size() != 1) {
                throw new AccountingException('Approval requires exactly one matching leave balance.');
            }
            Leave_Balance__c balance = balances[0];
            if (balance.Employee__c == null || String.isBlank(balance.Leave_Type__c) ||
                balance.Leave_Year__c == null || balance.Total_Leaves__c == null ||
                balance.Used_Leaves__c == null || balance.Total_Leaves__c < 0 ||
                balance.Used_Leaves__c < 0 || balance.Used_Leaves__c > balance.Total_Leaves__c ||
                balance.Leave_Balance_Key__c != expectedBalanceKey(
                    request.Employee__c, request.Leave_Type__c, startYear
                )) {
                throw new AccountingException('Matching leave balance is malformed or inconsistent.');
            }
            Decimal days = request.Total_Days__c;
            if (days == null || balance.Total_Leaves__c - balance.Used_Leaves__c < days) {
                throw new AccountingException('Insufficient leave balance.');
            }
            Decimal sequence = request.Last_Accounting_Cycle_Sequence__c;
            if (sequence == null || sequence < 0 || sequence != sequence.setScale(0)) {
                throw new AccountingException('Accounting cycle sequence is malformed.');
            }
            sequence++;
            String cycleId = String.valueOf(request.Id) + ':' + String.valueOf(sequence);
            Leave_Accounting_Event__c debit = new Leave_Accounting_Event__c(
                Request__c = request.Id,
                Balance__c = balance.Id,
                Cycle_Id__c = cycleId,
                Cycle_Sequence__c = sequence,
                Event_Type__c = 'Debit',
                Event_Key__c = cycleId + ':DEBIT',
                Amount__c = days,
                Occurred_At__c = System.now(),
                Actor__c = UserInfo.getUserId()
            );
            balance.Used_Leaves__c += days;
            updateBalance(balance);
            events.add(debit);
            request.Active_Charged_Balance__c = balance.Id;
            request.Active_Deducted_Days__c = days;
            request.Active_Accounting_Cycle_Id__c = cycleId;
            request.Last_Accounting_Cycle_Sequence__c = sequence;
            request.Balance_Deducted__c = true;
        } else {
            assertNoAccountingEvents(request.Id);
        }
        request.Status__c = 'Approved';
        request.Ever_Approved__c = true;
        request.Approval_Date__c = Date.today();
        saveRequest(request, Operation.APPROVE, events);
        } catch (Exception failure) {
            activeIntent = null;
            Database.rollback(transactionStart);
            throw failure;
        }
    }

    public static void cancel(Id requestId) {
        transitionFromApproved(requestId, 'Cancelled', Operation.CANCEL);
    }

    public static void reject(Id requestId) {
        transitionFromApproved(requestId, 'Rejected', Operation.REJECT);
    }

    public static void cancelPending(Id requestId) {
        requirePermission();
        Id employeeId = findEmployeeId(requestId);
        lockEmployees(new Set<Id>{employeeId});
        Leave_Request__c request = lockRequest(requestId);
        if (request.Status__c != 'Pending' || request.Ever_Approved__c) {
            throw new AccountingException('Only never-approved Pending requests can be cancelled without accounting.');
        }
        assertNoActiveSnapshot(request);
        assertNoAccountingEvents(request.Id);
        request.Status__c = 'Cancelled';
        saveRequest(request, Operation.CANCEL, new List<Leave_Accounting_Event__c>());
    }

    public static void guardBeforeInsert(List<Leave_Request__c> rows) {
        List<Leave_Request__c> expectedInserts = activeIntent == null
            ? new List<Leave_Request__c>() : activeIntent.expectedInserts;
        if (activeIntent == null || activeIntent.operation != Operation.SUBMIT ||
            rows.size() != expectedInserts.size()) {
            addErrors(rows, 'Leave requests must be submitted through LeaveAccountingService.');
            return;
        }
        activeIntent.expectedInserts = new List<Leave_Request__c>();
        for (Integer i = 0; i < rows.size(); i++) {
            Leave_Request__c actual = rows[i];
            Leave_Request__c expected = expectedInserts[i];
            if (actual.Employee__c != expected.Employee__c ||
                actual.Start_Date__c != expected.Start_Date__c ||
                actual.End_Date__c != expected.End_Date__c ||
                actual.Applied_Date__c != expected.Applied_Date__c ||
                actual.Leave_Type__c != expected.Leave_Type__c ||
                actual.Reason__c != expected.Reason__c ||
                actual.Status__c != expected.Status__c ||
                actual.Accounting_Cohort__c != expected.Accounting_Cohort__c ||
                actual.Balance_Deducted__c != expected.Balance_Deducted__c ||
                actual.Active_Charged_Balance__c != expected.Active_Charged_Balance__c ||
                actual.Active_Deducted_Days__c != expected.Active_Deducted_Days__c ||
                actual.Active_Accounting_Cycle_Id__c != expected.Active_Accounting_Cycle_Id__c ||
                actual.Last_Accounting_Cycle_Sequence__c != expected.Last_Accounting_Cycle_Sequence__c ||
                actual.Ever_Approved__c != expected.Ever_Approved__c ||
                actual.Approver__c != expected.Approver__c ||
                actual.Approval_Date__c != expected.Approval_Date__c) {
                actual.addError('Submission payload does not match the authorized operation.');
            }
        }
    }

    public static void guardRequestDelete(List<Leave_Request__c> rows) {
        if (allowRequestDeletionForTests) {
            return;
        }
        addErrors(rows, 'Leave requests are retained as accounting and operational history.');
    }

    public static void guardBeforeUpdate(List<Leave_Request__c> rows, Map<Id, Leave_Request__c> oldRows) {
        for (Leave_Request__c row : rows) {
            Leave_Request__c oldRow = oldRows.get(row.Id);
            Boolean protectedChange = row.Status__c != oldRow.Status__c ||
                row.Employee__c != oldRow.Employee__c ||
                row.Start_Date__c != oldRow.Start_Date__c ||
                row.End_Date__c != oldRow.End_Date__c ||
                row.Applied_Date__c != oldRow.Applied_Date__c ||
                row.Leave_Type__c != oldRow.Leave_Type__c ||
                row.Accounting_Cohort__c != oldRow.Accounting_Cohort__c ||
                row.Balance_Deducted__c != oldRow.Balance_Deducted__c ||
                row.Active_Charged_Balance__c != oldRow.Active_Charged_Balance__c ||
                row.Active_Deducted_Days__c != oldRow.Active_Deducted_Days__c ||
                row.Active_Accounting_Cycle_Id__c != oldRow.Active_Accounting_Cycle_Id__c ||
                row.Last_Accounting_Cycle_Sequence__c != oldRow.Last_Accounting_Cycle_Sequence__c ||
                row.Ever_Approved__c != oldRow.Ever_Approved__c ||
                row.Approver__c != oldRow.Approver__c ||
                row.Approval_Date__c != oldRow.Approval_Date__c;
            if (!protectedChange) {
                continue;
            }
            Leave_Request__c expected = activeIntent == null
                ? null : activeIntent.expectedRequests.remove(row.Id);
            if (expected == null || !sameProtectedFields(row, expected)) {
                row.addError('Protected leave request changes must use LeaveAccountingService.');
                continue;
            }
            if (oldRow.Ever_Approved__c &&
                (row.Start_Date__c != oldRow.Start_Date__c ||
                 row.End_Date__c != oldRow.End_Date__c ||
                 row.Leave_Type__c != oldRow.Leave_Type__c ||
                 !row.Ever_Approved__c)) {
                row.addError('Dates, leave type, and Ever Approved state are immutable after approval.');
            }
        }
    }

    public static void guardBalanceUpdate(List<Leave_Balance__c> rows, Map<Id, Leave_Balance__c> oldRows) {
        for (Leave_Balance__c row : rows) {
            Leave_Balance__c oldRow = oldRows.get(row.Id);
            if (row.Employee__c != oldRow.Employee__c ||
                row.Leave_Type__c != oldRow.Leave_Type__c ||
                row.Leave_Year__c != oldRow.Leave_Year__c ||
                row.Total_Leaves__c != oldRow.Total_Leaves__c ||
                row.Leave_Balance_Key__c != oldRow.Leave_Balance_Key__c) {
                row.addError('Leave balance identity and capacity fields cannot be changed through this prototype.');
                continue;
            }
            if (row.Used_Leaves__c != oldRow.Used_Leaves__c) {
                Decimal expectedUsed = activeIntent == null
                    ? null : activeIntent.expectedBalanceUsed.remove(row.Id);
                if (expectedUsed == null || expectedUsed != row.Used_Leaves__c) {
                    row.Used_Leaves__c.addError('Used Leaves can only be changed by LeaveAccountingService.');
                }
            }
        }
    }

    public static void guardBalanceInsert(List<Leave_Balance__c> rows) {
        List<Leave_Balance__c> expectedBalances = activeIntent == null
            ? new List<Leave_Balance__c>() : activeIntent.expectedBalanceInserts;
        if (activeIntent == null || activeIntent.operation != Operation.PROVISION ||
            rows.size() != expectedBalances.size()) {
            addBalanceErrors(rows, 'Leave balances can only be provisioned by LeaveAccountingService.');
            return;
        }
        activeIntent.expectedBalanceInserts = new List<Leave_Balance__c>();
        for (Integer i = 0; i < rows.size(); i++) {
            Leave_Balance__c actual = rows[i];
            Leave_Balance__c expected = expectedBalances[i];
            if (actual.Employee__c != expected.Employee__c ||
                actual.Leave_Type__c != expected.Leave_Type__c ||
                actual.Leave_Year__c != expected.Leave_Year__c ||
                actual.Total_Leaves__c != expected.Total_Leaves__c ||
                actual.Used_Leaves__c != expected.Used_Leaves__c ||
                actual.Leave_Balance_Key__c != expected.Leave_Balance_Key__c) {
                actual.addError('Balance insert does not match policy-derived provisioning authorization.');
            }
        }
    }

    public static void guardBalanceDelete(List<Leave_Balance__c> rows) {
        for (Leave_Balance__c row : rows) {
            row.addError('Leave balances are retained as accounting history.');
        }
    }

    public static void guardEventInsert(List<Leave_Accounting_Event__c> rows) {
        List<Leave_Accounting_Event__c> expectedEvents = activeIntent == null
            ? new List<Leave_Accounting_Event__c>() : activeIntent.expectedEvents;
        if (activeIntent == null || rows.size() != expectedEvents.size()) {
            addEventErrors(rows, 'Accounting events can only be created by LeaveAccountingService.');
            return;
        }
        activeIntent.expectedEvents = new List<Leave_Accounting_Event__c>();
        for (Integer i = 0; i < rows.size(); i++) {
            Leave_Accounting_Event__c actual = rows[i];
            Leave_Accounting_Event__c expected = expectedEvents[i];
            if (actual.Request__c != expected.Request__c || actual.Balance__c != expected.Balance__c ||
                actual.Cycle_Id__c != expected.Cycle_Id__c ||
                actual.Cycle_Sequence__c != expected.Cycle_Sequence__c ||
                actual.Event_Type__c != expected.Event_Type__c ||
                actual.Event_Key__c != expected.Event_Key__c ||
                actual.Amount__c != expected.Amount__c ||
                actual.Related_Debit_Event__c != expected.Related_Debit_Event__c ||
                actual.Occurred_At__c != expected.Occurred_At__c ||
                actual.Actor__c != expected.Actor__c) {
                actual.addError('Accounting event does not match the authorized operation.');
            }
        }
    }

    public static void guardEventMutation(List<Leave_Accounting_Event__c> rows) {
        if (allowEventMutationForTests) {
            return;
        }
        addEventErrors(rows, 'Accounting events are immutable.');
    }

    @TestVisible
    private static void validateRequestForTest(Leave_Request__c request) {
        validateRequest(request);
    }

    @TestVisible
    private static void insertBalanceFixtureForTest(Leave_Balance__c balance) {
        Intent intent = new Intent();
        intent.operation = Operation.PROVISION;
        intent.expectedBalanceInserts.add(balance.clone(false, true, false, false));
        activeIntent = intent;
        try {
            insert balance;
        } finally {
            activeIntent = null;
        }
    }

    private static void transitionFromApproved(Id requestId, String targetStatus, Operation operation) {
        requirePermission();
        Savepoint transactionStart = Database.setSavepoint();
        try {
        Id employeeId = findEmployeeId(requestId);
        lockEmployees(new Set<Id>{employeeId});
        Leave_Request__c request = lockRequest(requestId);
        if (request.Status__c != 'Approved') {
            throw new AccountingException('Only Approved requests can be cancelled or rejected.');
        }
        List<Leave_Accounting_Event__c> events = new List<Leave_Accounting_Event__c>();
        if (request.Leave_Type__c != 'Unpaid') {
            if (!request.Balance_Deducted__c || request.Active_Charged_Balance__c == null ||
                request.Active_Deducted_Days__c == null || request.Active_Deducted_Days__c <= 0 ||
                request.Active_Deducted_Days__c != request.Total_Days__c ||
                request.Last_Accounting_Cycle_Sequence__c == null ||
                request.Last_Accounting_Cycle_Sequence__c <= 0 ||
                String.isBlank(request.Active_Accounting_Cycle_Id__c) ||
                request.Active_Accounting_Cycle_Id__c != String.valueOf(request.Id) + ':' +
                    String.valueOf(request.Last_Accounting_Cycle_Sequence__c)) {
                throw new AccountingException('Active debit snapshot is missing; controlled recovery is required.');
            }
            String debitEventKey = request.Active_Accounting_Cycle_Id__c + ':DEBIT';
            List<Leave_Accounting_Event__c> debits = [
                SELECT Id, Request__c, Balance__c, Cycle_Id__c, Cycle_Sequence__c, Amount__c, Event_Type__c
                FROM Leave_Accounting_Event__c
                WHERE Event_Key__c = :debitEventKey
                WITH SYSTEM_MODE
                LIMIT 2
            ];
            if (debits.size() != 1 || debits[0].Request__c != request.Id ||
                debits[0].Balance__c != request.Active_Charged_Balance__c ||
                debits[0].Amount__c != request.Active_Deducted_Days__c ||
                debits[0].Cycle_Id__c != request.Active_Accounting_Cycle_Id__c ||
                debits[0].Cycle_Sequence__c != request.Last_Accounting_Cycle_Sequence__c ||
                debits[0].Event_Type__c != 'Debit') {
                throw new AccountingException('Active snapshot does not match one Debit event; controlled recovery is required.');
            }
            String restorationEventKey = request.Active_Accounting_Cycle_Id__c + ':RESTORE';
            List<Leave_Accounting_Event__c> existingRestorations = [
                SELECT Id
                FROM Leave_Accounting_Event__c
                WHERE Event_Key__c = :restorationEventKey
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (!existingRestorations.isEmpty()) {
                throw new AccountingException('A restoration event already exists for the active cycle.');
            }
            List<Leave_Balance__c> balances = [
                SELECT Id, Employee__c, Leave_Type__c, Leave_Year__c,
                       Total_Leaves__c, Used_Leaves__c, Leave_Balance_Key__c
                FROM Leave_Balance__c
                WHERE Id = :request.Active_Charged_Balance__c
                WITH SYSTEM_MODE
                FOR UPDATE
            ];
            if (balances.size() != 1 || balances[0].Used_Leaves__c == null ||
                balances[0].Total_Leaves__c == null ||
                balances[0].Used_Leaves__c < request.Active_Deducted_Days__c ||
                balances[0].Used_Leaves__c > balances[0].Total_Leaves__c ||
                balances[0].Employee__c != request.Employee__c ||
                balances[0].Leave_Type__c != request.Leave_Type__c ||
                balances[0].Leave_Year__c != request.Start_Date__c.year() ||
                balances[0].Leave_Balance_Key__c != expectedBalanceKey(
                    request.Employee__c, request.Leave_Type__c, request.Start_Date__c.year()
                )) {
                throw new AccountingException('Original balance is missing or inconsistent; controlled recovery is required.');
            }
            Leave_Balance__c balance = balances[0];
            balance.Used_Leaves__c -= request.Active_Deducted_Days__c;
            updateBalance(balance);
            events.add(new Leave_Accounting_Event__c(
                Request__c = request.Id,
                Balance__c = request.Active_Charged_Balance__c,
                Cycle_Id__c = request.Active_Accounting_Cycle_Id__c,
                Cycle_Sequence__c = debits[0].Cycle_Sequence__c,
                Event_Type__c = 'Restoration',
                Event_Key__c = request.Active_Accounting_Cycle_Id__c + ':RESTORE',
                Amount__c = request.Active_Deducted_Days__c,
                Related_Debit_Event__c = debits[0].Id,
                Occurred_At__c = System.now(),
                Actor__c = UserInfo.getUserId()
            ));
        } else {
            assertNoActiveSnapshot(request);
            assertNoAccountingEvents(request.Id);
        }
        clearActiveSnapshot(request);
        request.Balance_Deducted__c = false;
        request.Status__c = targetStatus;
        request.Approval_Date__c = null;
        saveRequest(request, operation, events);
        } catch (Exception failure) {
            activeIntent = null;
            Database.rollback(transactionStart);
            throw failure;
        }
    }

    private static void saveRequest(
        Leave_Request__c request,
        Operation operation,
        List<Leave_Accounting_Event__c> events
    ) {
        Intent intent = new Intent();
        intent.operation = operation;
        intent.expectedRequests.put(request.Id, request.clone(true, true, false, false));
        intent.expectedEvents.addAll(events);
        activeIntent = intent;
        try {
            if (!events.isEmpty()) {
                insert events;
            }
            update request;
            if (failAfterRequestUpdateForTests) {
                throw new AccountingException('Injected test failure after request and event writes.');
            }
        } finally {
            activeIntent = null;
        }
    }

    private static void updateBalance(Leave_Balance__c balance) {
        if (activeIntent == null) {
            activeIntent = new Intent();
        }
        activeIntent.expectedBalanceUsed.put(balance.Id, balance.Used_Leaves__c);
        update balance;
    }

    private static Map<String, Decimal> validatePolicies(List<Leave_Policy__mdt> policies) {
        if (policies == null || policies.isEmpty()) {
            throw new AccountingException('No leave policies are configured.');
        }
        Map<String, Decimal> allowancesByType = new Map<String, Decimal>();
        for (Leave_Policy__mdt policy : policies) {
            if (policy == null) {
                throw new AccountingException('Leave policy metadata contains an empty record.');
            }
            String leaveType = policy.Leave_Type__c;
            Decimal allowance = policy.Total_Leaves__c;
            if (String.isBlank(leaveType) || !REQUIRED_LEAVE_TYPES.contains(leaveType) ||
                allowance == null || allowance < 0 || allowance > 999 ||
                allowance != allowance.setScale(0) || allowancesByType.containsKey(leaveType)) {
                throw new AccountingException('Leave policy metadata is incomplete, invalid, or duplicated.');
            }
            if ((POSITIVE_ENTITLEMENT_TYPES.contains(leaveType) && allowance <= 0) ||
                (leaveType == 'Unpaid' && allowance != 0)) {
                throw new AccountingException('Leave policy entitlement is semantically inconsistent.');
            }
            allowancesByType.put(leaveType, allowance);
        }
        Set<String> missingTypes = new Set<String>();
        missingTypes.addAll(REQUIRED_LEAVE_TYPES);
        missingTypes.removeAll(allowancesByType.keySet());
        if (!missingTypes.isEmpty()) {
            throw new AccountingException('Leave policy metadata must define Paid, Casual, Sick, and Unpaid exactly once.');
        }
        return allowancesByType;
    }

    @TestVisible
    private static void validatePoliciesForTest(List<Leave_Policy__mdt> policies) {
        validatePolicies(policies);
    }

    private static Id resolveApproverId(Id employeeId) {
        Employee__c employee = [
            SELECT Manager__c, Department__c
            FROM Employee__c
            WHERE Id = :employeeId
            LIMIT 1
        ];
        if (employee.Manager__c != null) {
            return employee.Manager__c;
        }
        if (employee.Department__c == null) {
            return null;
        }
        List<Department__c> departments = [
            SELECT Head_of_Department__c
            FROM Department__c
            WHERE Id = :employee.Department__c
            LIMIT 1
        ];
        return departments.isEmpty() ? null : departments[0].Head_of_Department__c;
    }

    private static Id findEmployeeId(Id requestId) {
        List<Leave_Request__c> rows = [
            SELECT Employee__c
            FROM Leave_Request__c
            WHERE Id = :requestId
        ];
        if (rows.size() != 1 || rows[0].Employee__c == null) {
            throw new AccountingException('Leave request or employee was not found.');
        }
        return rows[0].Employee__c;
    }

    private static Leave_Request__c lockRequest(Id requestId) {
        List<Leave_Request__c> rows = [
            SELECT Id, Employee__c, Leave_Type__c, Start_Date__c, End_Date__c,
                   Applied_Date__c, Reason__c, Total_Days__c,
                   Status__c, Accounting_Cohort__c, Approver__c, Approval_Date__c,
                   Balance_Deducted__c, Active_Charged_Balance__c,
                   Active_Deducted_Days__c, Active_Accounting_Cycle_Id__c,
                   Last_Accounting_Cycle_Sequence__c, Ever_Approved__c
            FROM Leave_Request__c
            WHERE Id = :requestId
            FOR UPDATE
        ];
        if (rows.size() != 1) {
            throw new AccountingException('Leave request was not found.');
        }
        if (rows[0].Accounting_Cohort__c != 'Managed') {
            throw new AccountingException('Legacy or unclassified requests cannot be processed by the managed service.');
        }
        return rows[0];
    }

    private static void lockEmployees(Set<Id> employeeIds) {
        if (employeeIds.isEmpty()) {
            return;
        }
        List<Employee__c> employees = [
            SELECT Id
            FROM Employee__c
            WHERE Id IN :employeeIds
            FOR UPDATE
        ];
        if (employees.size() != employeeIds.size()) {
            throw new AccountingException('Employee record could not be locked.');
        }
    }

    private static void validateRequest(Leave_Request__c request) {
        if (request.Employee__c == null || request.Start_Date__c == null ||
            request.End_Date__c == null || String.isBlank(request.Leave_Type__c)) {
            throw new AccountingException('Employee, start date, end date, and leave type are required.');
        }
        if (request.End_Date__c < request.Start_Date__c) {
            throw new AccountingException('End date cannot be before start date.');
        }
        Integer days = request.Start_Date__c.daysBetween(request.End_Date__c) + 1;
        if (days < 1 || days > 365) {
            throw new AccountingException('Inclusive leave duration must be between 1 and 365 days.');
        }
        if (!REQUIRED_LEAVE_TYPES.contains(request.Leave_Type__c)) {
            throw new AccountingException('Leave type is not supported by the managed policy set.');
        }
        if ((request.Leave_Type__c == 'Sick' || request.Leave_Type__c == 'Unpaid') &&
            String.isBlank(request.Reason__c)) {
            throw new AccountingException('A reason is required for Sick and Unpaid leave.');
        }
    }

    private static String expectedBalanceKey(Id employeeId, String leaveType, Integer leaveYear) {
        return String.valueOf(employeeId) + '-' + leaveType + '-' + String.valueOf(leaveYear);
    }

    private static void assertNoOverlap(Leave_Request__c candidate, Id excludedId) {
        List<Leave_Request__c> existing;
        if (excludedId == null) {
            existing = [
                SELECT Id, Start_Date__c, End_Date__c
                FROM Leave_Request__c
                WHERE Employee__c = :candidate.Employee__c
                  AND Status__c IN ('Pending', 'Approved')
                  AND Start_Date__c <= :candidate.End_Date__c
                  AND End_Date__c >= :candidate.Start_Date__c
                WITH SYSTEM_MODE
            ];
        } else {
            existing = [
                SELECT Id, Start_Date__c, End_Date__c
                FROM Leave_Request__c
                WHERE Employee__c = :candidate.Employee__c
                  AND Status__c IN ('Pending', 'Approved')
                  AND Id != :excludedId
                  AND Start_Date__c <= :candidate.End_Date__c
                  AND End_Date__c >= :candidate.Start_Date__c
                WITH SYSTEM_MODE
            ];
        }
        if (!existing.isEmpty()) {
            throw new AccountingException('Pending or Approved leave requests cannot overlap.');
        }
    }

    private static Boolean sameProtectedFields(Leave_Request__c left, Leave_Request__c right) {
        return left.Employee__c == right.Employee__c &&
            left.Start_Date__c == right.Start_Date__c &&
            left.End_Date__c == right.End_Date__c &&
            left.Applied_Date__c == right.Applied_Date__c &&
            left.Leave_Type__c == right.Leave_Type__c &&
            left.Status__c == right.Status__c &&
            left.Accounting_Cohort__c == right.Accounting_Cohort__c &&
            left.Balance_Deducted__c == right.Balance_Deducted__c &&
            left.Active_Charged_Balance__c == right.Active_Charged_Balance__c &&
            left.Active_Deducted_Days__c == right.Active_Deducted_Days__c &&
            left.Active_Accounting_Cycle_Id__c == right.Active_Accounting_Cycle_Id__c &&
            left.Last_Accounting_Cycle_Sequence__c == right.Last_Accounting_Cycle_Sequence__c &&
            left.Ever_Approved__c == right.Ever_Approved__c &&
            left.Approver__c == right.Approver__c &&
            left.Approval_Date__c == right.Approval_Date__c;
    }

    private static void clearActiveSnapshot(Leave_Request__c request) {
        request.Active_Charged_Balance__c = null;
        request.Active_Deducted_Days__c = null;
        request.Active_Accounting_Cycle_Id__c = null;
    }

    private static void assertNoActiveSnapshot(Leave_Request__c request) {
        if (request.Balance_Deducted__c != false ||
            request.Active_Charged_Balance__c != null ||
            request.Active_Deducted_Days__c != null ||
            !String.isBlank(request.Active_Accounting_Cycle_Id__c)) {
            throw new AccountingException('Unexpected active accounting snapshot; controlled recovery is required.');
        }
    }

    private static void assertNoAccountingEvents(Id requestId) {
        List<Leave_Accounting_Event__c> events = [
            SELECT Id
            FROM Leave_Accounting_Event__c
            WHERE Request__c = :requestId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (!events.isEmpty()) {
            throw new AccountingException('Unexpected prior accounting event; controlled recovery is required.');
        }
    }

    private static void assertLastCycleRestored(Leave_Request__c request) {
        Decimal sequence = request.Last_Accounting_Cycle_Sequence__c;
        if (sequence == null || sequence <= 0 || sequence != sequence.setScale(0)) {
            throw new AccountingException('Cancelled request cycle sequence is malformed.');
        }
        String cycleId = String.valueOf(request.Id) + ':' + String.valueOf(sequence);
        String debitEventKey = cycleId + ':DEBIT';
        String restorationEventKey = cycleId + ':RESTORE';
        List<Leave_Accounting_Event__c> debits = [
            SELECT Id, Request__c, Balance__c, Cycle_Id__c, Cycle_Sequence__c, Event_Type__c, Amount__c
            FROM Leave_Accounting_Event__c
            WHERE Event_Key__c = :debitEventKey
            WITH SYSTEM_MODE
            LIMIT 2
        ];
        List<Leave_Accounting_Event__c> restorations = [
            SELECT Id, Request__c, Balance__c, Cycle_Id__c, Cycle_Sequence__c, Event_Type__c,
                   Amount__c, Related_Debit_Event__c
            FROM Leave_Accounting_Event__c
            WHERE Event_Key__c = :restorationEventKey
            WITH SYSTEM_MODE
            LIMIT 2
        ];
        if (debits.size() != 1 || restorations.size() != 1 ||
            debits[0].Request__c != request.Id || restorations[0].Request__c != request.Id ||
            debits[0].Balance__c != restorations[0].Balance__c ||
            debits[0].Cycle_Id__c != cycleId || restorations[0].Cycle_Id__c != cycleId ||
            debits[0].Cycle_Sequence__c != sequence || restorations[0].Cycle_Sequence__c != sequence ||
            debits[0].Event_Type__c != 'Debit' || restorations[0].Event_Type__c != 'Restoration' ||
            debits[0].Amount__c == null || debits[0].Amount__c <= 0 ||
            restorations[0].Amount__c != debits[0].Amount__c ||
            restorations[0].Related_Debit_Event__c != debits[0].Id) {
            throw new AccountingException('Cancelled request does not have a complete restored prior cycle.');
        }
    }

    private static void requirePermission() {
        if (activeIntent != null) {
            throw new AccountingException('Re-entrant leave accounting operations are not allowed.');
        }
        if (!skipPermissionCheckForTests && !FeatureManagement.checkPermission('Manage_Leave_Accounting')) {
            throw new AccountingException('You are not authorized to process leave accounting.');
        }
    }

    private static void assertOneEmployee(Set<Id> employeeIds) {
        if (employeeIds.size() != 1) {
            throw new AccountingException('A synchronous accounting operation must contain one employee.');
        }
    }

    private static void addErrors(List<Leave_Request__c> rows, String message) {
        for (Leave_Request__c row : rows) {
            row.addError(message);
        }
    }

    private static void addEventErrors(List<Leave_Accounting_Event__c> rows, String message) {
        for (Leave_Accounting_Event__c row : rows) {
            row.addError(message);
        }
    }

    private static void addBalanceErrors(List<Leave_Balance__c> rows, String message) {
        for (Leave_Balance__c row : rows) {
            row.addError(message);
        }
    }
}
